#!/bin/bash
set -euo pipefail
# =============================================================================
# Outline Docker Restore Script
# =============================================================================
# Restores a snapshot made by outline-docker-backup.sh into an instance
# installed by outline-docker-install.sh:
#   <backup-root>/outline/<domain>/<date-n-time>/postgres/outline.sql.gz
#   <backup-root>/outline/<domain>/<date-n-time>/attachments/attachments.tar.gz
#   <backup-root>/outline/<domain>/<date-n-time>/config/.env
#
# The database and the attachments are always restored together: attachment
# rows in the database point at files in storage, and either half alone
# leaves broken images and downloads. Two modes:
#
#   1) Full recovery - .env + database + attachments. A new server, or rolling
#                      the whole instance back. The target must have the
#                      snapshot's domain.
#   2) Data only     - database + attachments; the target's .env stays. Undoing
#                      a bad upgrade or a deletion on the same install. Refused
#                      when the target's SECRET_KEY is not the snapshot's: the
#                      database is encrypted with it.
#
# To recover onto a NEW server: if Keycloak was lost too, restore it first
# (keycloak-docker-restore.sh), so the OIDC client secret in the snapshot's
# .env matches Keycloak's again. Then run outline-docker-install.sh with the
# SAME domain, and choose Full recovery here.
#
# What happens, in order:
#   1. The snapshot is verified (gzip, the dump's trailer, the archive) and the
#      Outline versions are compared - before anything changes.
#   2. A safety snapshot of the target is taken with outline-docker-backup.sh,
#      so the restore can itself be undone with this script.
#   3. Outline is stopped. Full recovery puts back .env; when its database
#      password differs from the target's (a fresh install), the database-data
#      volume is re-created, because Postgres only reads the password when its
#      volume is first initialised.
#   4. The database is dropped, re-created and loaded in one transaction.
#   5. The storage-data volume is emptied and unpacked from the archive.
#   6. Outline starts, runs pending migrations, and must answer /_health.
#
# docker-compose.yml and docker-compose.override.yml are not restored: the
# first is the repo's file, the second is specific to the host it was made on.
# The target's Outline must be the snapshot's version or newer: migrations only
# run forward.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/outline-docker-backup.sh"

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_OUTLINE_PATH="/var/www/docker/outline"
HELPER_IMAGE="busybox"

CHANGED=false   # true once the target is touched (Outline stopped)
SAFETY_DEST=""
INSTANCE_DIR=""

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "Error: $*" >&2; exit 1; }

_nice_date() {
  local stamp="$1" yr mo dy hr mn sc
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

_manifest_get() {  # _manifest_get <snapshot-dir> <key>
  sed -n "s/^${2}[[:space:]]*:[[:space:]]*//p" "$1/manifest.txt" 2>/dev/null | head -n1 || true
}

_version_ge() {  # _version_ge <a> <b>  ->  true when a >= b
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

_env_get() {  # _env_get <file> <key> - read, not sourced (see the backup script)
  local v
  v="$(sed -n "s/^${2}=//p" "$1" | tail -n1)"
  if [[ "$v" == \'*\' || "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

_on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] && return
  echo "" >&2
  echo "Restore FAILED (exit $rc)." >&2
  if ! $CHANGED; then
    echo "Nothing was changed on the target." >&2
    return
  fi
  echo "Outline may be stopped. Logs: cd $INSTANCE_DIR && docker compose logs" >&2
  if [[ -n "$SAFETY_DEST" ]]; then
    echo "The target's previous state is in: $SAFETY_DEST" >&2
    echo "Restore it with this script to undo." >&2
  fi
  echo "The snapshot itself is untouched: fix the cause and run this script again." >&2
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=====> Outline Restore"
echo "========================================"

for cmd in docker gzip tar sed awk find sort curl flock; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
[ -x "$BACKUP_SCRIPT" ] || _die "outline-docker-backup.sh not found next to this script (needed for the safety snapshot)."

# ── 1. Backup base directory ──────────────────────────────────────────────────
echo "Choose the directory where your backups are located:"
echo "  1) Default: $DEFAULT_BACKUP_ROOT"
echo "  2) Custom path"
read -rp "Select [1/2]: " BACKUP_BASE_CHOICE
if [ "$BACKUP_BASE_CHOICE" = "2" ]; then
  read -rep "Enter custom backup base path: " BACKUP_ROOT
  BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
else
  BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
fi
BACKUP_ROOT="${BACKUP_ROOT%/}"

OUTLINE_BACKUPS_DIR="$BACKUP_ROOT/outline"
[ -d "$OUTLINE_BACKUPS_DIR" ] || _die "'$OUTLINE_BACKUPS_DIR' not found."

# ── 2. Domain the backup came from ────────────────────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$OUTLINE_BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || _die "No domain backup folders found in '$OUTLINE_BACKUPS_DIR'."

if [ ${#DOMAIN_DIRS[@]} -eq 1 ]; then
  DOMAIN_DIR="${DOMAIN_DIRS[0]}"
  echo "Using backup folder: $(basename "$DOMAIN_DIR")"
else
  echo "Found backup folders:"
  for i in "${!DOMAIN_DIRS[@]}"; do
    echo "  $((i+1))) $(basename "${DOMAIN_DIRS[$i]}")"
  done
  echo ""
  read -rp "Select domain number: " DOM_NUM
  if ! [[ "$DOM_NUM" =~ ^[0-9]+$ ]] || [ "$DOM_NUM" -lt 1 ] || [ "$DOM_NUM" -gt "${#DOMAIN_DIRS[@]}" ]; then
    _die "Invalid selection."
  fi
  DOMAIN_DIR="${DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

# ── 3. Snapshot ───────────────────────────────────────────────────────────────
mapfile -t SNAPSHOTS < <(find "$DOMAIN_DIR" -mindepth 1 -maxdepth 1 -type d \
  -regextype posix-extended -regex '.*/[0-9]{4}(-[0-9]{2}){5}' | sort -r)
[ ${#SNAPSHOTS[@]} -gt 0 ] || _die "No backup snapshots found in '$(basename "$DOMAIN_DIR")'."

echo ""
printf "  %-4s %-28s %-9s %-9s %-12s %s\n" "#" "Date" "Version" "Database" "Attachments" "Note"
printf "  %-4s %-28s %-9s %-9s %-12s %s\n" "----" "----------------------------" "---------" "---------" "------------" "----"
for i in "${!SNAPSHOTS[@]}"; do
  S="${SNAPSHOTS[$i]}"
  DB_S="--";    [ -f "$S/postgres/outline.sql.gz" ]          && DB_S="$(du -h "$S/postgres/outline.sql.gz" | cut -f1)"
  FILES_S="--"; [ -f "$S/attachments/attachments.tar.gz" ] && FILES_S="$(du -h "$S/attachments/attachments.tar.gz" | cut -f1)"
  NOTE=""
  [ "$(_manifest_get "$S" "Type")" = "pre-restore safety snapshot" ] && NOTE="pre-restore"
  [ -f "$S/manifest.txt" ] || NOTE="no manifest - incomplete?"
  VER="$(_manifest_get "$S" "Outline version")"
  printf "  %-4s %-28s %-9s %-9s %-12s %s\n" "$((i+1)))" "$(_nice_date "$(basename "$S")")" \
    "${VER:-?}" "$DB_S" "$FILES_S" "$NOTE"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM
if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  _die "Invalid selection."
fi

SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"
SNAP_DUMP="$SNAPSHOT_DIR/postgres/outline.sql.gz"
SNAP_FILES="$SNAPSHOT_DIR/attachments/attachments.tar.gz"
SNAP_ENV="$SNAPSHOT_DIR/config/.env"
SNAP_DOMAIN="$(_manifest_get "$SNAPSHOT_DIR" "Domain")"
SNAP_VERSION="$(_manifest_get "$SNAPSHOT_DIR" "Outline version")"
[ "$SNAP_VERSION" = "unknown" ] && SNAP_VERSION=""
[ -f "$SNAP_DUMP" ] || _die "this snapshot has no database dump."
[ -f "$SNAP_ENV" ]  || _die "this snapshot has no .env - its SECRET_KEY is needed to read the database."
HAS_FILES=false; [ -f "$SNAP_FILES" ] && HAS_FILES=true

# ── 4. Verify the snapshot before anything changes ────────────────────────────
echo ""
echo "Verifying the snapshot..."
gzip -t "$SNAP_DUMP" || _die "$SNAP_DUMP is corrupt."
gunzip -c "$SNAP_DUMP" | tail -n 20 | grep 'PostgreSQL database dump complete' >/dev/null \
  || _die "$SNAP_DUMP is incomplete (no 'dump complete' trailer)."
if $HAS_FILES; then
  tar -tzf "$SNAP_FILES" >/dev/null || _die "$SNAP_FILES is corrupt."
fi
echo "  OK"

# ── 5. Target instance ────────────────────────────────────────────────────────
echo ""
read -rep "Outline instances base path [$DEFAULT_OUTLINE_PATH]: " OUTLINE_BASE_PATH
OUTLINE_BASE_PATH="${OUTLINE_BASE_PATH:-$DEFAULT_OUTLINE_PATH}"
OUTLINE_BASE_PATH="${OUTLINE_BASE_PATH/#\~/$HOME}"
OUTLINE_BASE_PATH="${OUTLINE_BASE_PATH%/}"
[ -d "$OUTLINE_BASE_PATH" ] || _die "'$OUTLINE_BASE_PATH' not found."

TARGETS=()
for f in "$OUTLINE_BASE_PATH"/*/docker-compose.yml; do
  if [ -r "${f%/*}/.env" ] && grep -q 'outlinewiki/outline' "$f"; then
    TARGETS+=("${f%/*}")
  fi
done
[ ${#TARGETS[@]} -gt 0 ] || _die "No Outline instances found in '$OUTLINE_BASE_PATH' - install one first with outline-docker-install.sh."

echo ""
if [ ${#TARGETS[@]} -eq 1 ]; then
  INSTANCE_DIR="${TARGETS[0]}"
  echo "Target instance: $(basename "$INSTANCE_DIR")  ($INSTANCE_DIR)"
else
  echo "Found instances:"
  for i in "${!TARGETS[@]}"; do
    echo "  $((i+1))) $(basename "${TARGETS[$i]}")  (${TARGETS[$i]})"
  done
  echo ""
  read -rp "Select instance number to restore INTO: " TGT_NUM
  if ! [[ "$TGT_NUM" =~ ^[0-9]+$ ]] || [ "$TGT_NUM" -lt 1 ] || [ "$TGT_NUM" -gt "${#TARGETS[@]}" ]; then
    _die "Invalid selection."
  fi
  INSTANCE_DIR="${TARGETS[$((TGT_NUM-1))]}"
fi

ENV_FILE="$INSTANCE_DIR/.env"
URL="$(_env_get "$ENV_FILE" URL)"
DOMAIN="${URL#*://}"; DOMAIN="${DOMAIN%%/*}"
PROJECT="$(_env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)"
[ -n "$DOMAIN" ] && [ -n "$PROJECT" ] \
  || _die "no URL or COMPOSE_PROJECT_NAME in $ENV_FILE - not an instance from outline-docker-install.sh?"

# Run from the instance directory, like the commands the installer prints:
# Compose then reads this instance's .env (re-read on every call, so a restored
# one applies to the very next command) and docker-compose.override.yml.
cd "$INSTANCE_DIR"

# -T: no TTY, so stdin can carry the dump. -h 127.0.0.1 in every client call:
# the official image trusts loopback, and while it initialises a new volume it
# runs a temporary socket-only server, so a TCP probe only succeeds once the
# final server is up.
db_sh() { docker compose exec -T postgres sh -c "$1"; }
db_ready() { db_sh 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' </dev/null >/dev/null 2>&1; }

wait_db() {
  echo -n "Waiting for PostgreSQL"
  for _ in $(seq 1 60); do
    if db_ready; then
      echo ""
      return 0
    fi
    echo -n "."
    sleep 2
  done
  echo ""
  _die "PostgreSQL did not become ready (cd $INSTANCE_DIR && docker compose logs postgres)."
}

# The real Docker volume behind a Compose volume, found by Compose's labels.
vol_of() {
  docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.volume=$1" | sed -n '1p'
}

# The target's Outline release, from its outline container's image.
TARGET_VERSION=""
OUTLINE_CID="$(docker compose ps -aq outline 2>/dev/null | head -n1 || true)"
if [ -n "$OUTLINE_CID" ]; then
  TARGET_VERSION="$(docker run --rm --network none --entrypoint node "$(docker inspect -f '{{.Image}}' "$OUTLINE_CID")" \
    -p "require('/opt/outline/package.json').version" 2>/dev/null || true)"
fi

# ── 6. What to restore ────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "  Full recovery puts back the snapshot's .env (SECRET_KEY, database"
echo "  password, OIDC and SMTP settings), the database and the attachments."
echo "  Use it on a new server or to roll the whole instance back. If the"
echo "  database password differs from this instance's (a fresh install), the"
echo "  database volume is re-created so that the snapshot's password applies."
echo ""
echo "  Data only puts back the database and the attachments and keeps this"
echo "  instance's .env. Use it to undo a bad upgrade or a deletion on the same"
echo "  install. It needs this instance to have the snapshot's SECRET_KEY."
echo "------------------------------------------------------------"
echo ""
echo "What do you want to restore?"
echo "  1) Full recovery (.env + database + attachments)"
echo "  2) Data only (database + attachments)"
read -rp "Select [1/2]: " ACTION
case "$ACTION" in
  1) FULL=true ;;
  2) FULL=false ;;
  *) _die "Invalid selection." ;;
esac

if $FULL; then
  # The .env carries the Compose project name and URL. Another domain's would
  # start a second stack beside this one, serving the wrong URL.
  SNAP_PROJECT="$(_env_get "$SNAP_ENV" COMPOSE_PROJECT_NAME)"
  [ "$SNAP_PROJECT" = "$PROJECT" ] \
    || _die "this snapshot belongs to '${SNAP_DOMAIN:-$SNAP_PROJECT}' but the target is '$DOMAIN'. Install with the snapshot's domain, or choose 'Data only' on an instance with its SECRET_KEY."
  NEW_ENV="$SNAP_ENV"
else
  [ "$(_env_get "$SNAP_ENV" SECRET_KEY)" = "$(_env_get "$ENV_FILE" SECRET_KEY)" ] \
    || _die "this instance's SECRET_KEY is not the snapshot's, so the restored database would be partly unreadable. Use 'Full recovery'."
  NEW_ENV="$ENV_FILE"
fi

# Postgres only reads its credentials when its volume is first initialised.
RESET_DB_VOLUME=false
if $FULL && [ "$(_env_get "$SNAP_ENV" POSTGRES_USER):$(_env_get "$SNAP_ENV" POSTGRES_PASSWORD)" \
           != "$(_env_get "$ENV_FILE" POSTGRES_USER):$(_env_get "$ENV_FILE" POSTGRES_PASSWORD)" ]; then
  RESET_DB_VOLUME=true
fi
OLD_OIDC_SECRET="$(_env_get "$ENV_FILE" OIDC_CLIENT_SECRET)"
PORT="$(_env_get "$NEW_ENV" OUTLINE_PORT)"
PORT="${PORT:-3000}"   # docker-compose.yml's default
[[ "$PORT" =~ ^[0-9]+$ ]] || _die "OUTLINE_PORT in $NEW_ENV is not a number."

# ── 7. Version check ──────────────────────────────────────────────────────────
if [ -z "$SNAP_VERSION" ] || [ -z "$TARGET_VERSION" ]; then
  echo ""
  echo "WARNING: could not compare versions (snapshot: ${SNAP_VERSION:-unknown}, target: ${TARGET_VERSION:-unknown})."
  read -rp "Restore anyway? [y/N]: " ANS_VER
  [[ "$ANS_VER" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; exit 0; }
elif ! _version_ge "$TARGET_VERSION" "$SNAP_VERSION"; then
  _die "the snapshot is from Outline $SNAP_VERSION but the target runs $TARGET_VERSION. Migrations only run forward - update the target first (cd $INSTANCE_DIR && docker compose pull && docker compose up -d; raise OUTLINE_VERSION in .env if it is pinned), then restore."
elif [ "$SNAP_VERSION" != "$TARGET_VERSION" ]; then
  echo ""
  echo "NOTE: the snapshot is from Outline $SNAP_VERSION and the target runs $TARGET_VERSION."
  echo "      Outline migrates the restored database when it starts, the same as an upgrade."
fi

# ── 8. Summary and confirmation ───────────────────────────────────────────────
echo ""
echo "A safety snapshot saves the target's CURRENT database, attachments and .env"
echo "to $BACKUP_ROOT/outline/$DOMAIN/ before anything is replaced, so the restore"
echo "can be undone."
read -rp "Take a safety snapshot first? [Y/n]: " ANS_SAFETY
if [[ "$ANS_SAFETY" =~ ^[Nn]$ ]]; then DO_SAFETY=false; else DO_SAFETY=true; fi

echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Backup snapshot : $SNAPSHOT_DIR"
echo "  from          : ${SNAP_DOMAIN:-?}, Outline ${SNAP_VERSION:-?}"
echo "Target instance : $DOMAIN (Outline ${TARGET_VERSION:-?})"
echo "Install dir     : $INSTANCE_DIR"
echo "Restoring       : $($FULL && echo ".env + ")database$($HAS_FILES && echo " + attachments")"
echo "Safety snapshot : $($DO_SAFETY && echo "yes, into $BACKUP_ROOT/outline/$DOMAIN/" || echo "NO")"
echo "========================================================="
echo ""
echo "WARNING: Outline is unavailable while this runs. Everything created after the"
echo "         snapshot is lost."
$RESET_DB_VOLUME && echo "WARNING: the database volume is removed and re-created (the .env has other database credentials)."
$HAS_FILES || echo "NOTE:    this snapshot has no attachments - the target's are left as they are."
$DO_SAFETY || echo "WARNING: no safety snapshot - the target's current data cannot be recovered afterwards."
echo ""
read -rp "Type 'restore' to continue: " CONFIRM
[ "$CONFIRM" = "restore" ] || { echo "Restore cancelled."; exit 0; }

# ── 9. Lock ───────────────────────────────────────────────────────────────────
# Shared with the backup script. Waits for a running backup to finish; a
# scheduled backup that starts during the restore fails instead of dumping a
# half-restored database.
exec 9>>"$INSTANCE_DIR/.maintenance.lock" || _die "cannot open $INSTANCE_DIR/.maintenance.lock."
echo ""
echo "Waiting for the instance lock..."
flock -w 600 9 || _die "another backup or restore of $DOMAIN is still running."

# ── 10. Safety snapshot ───────────────────────────────────────────────────────
# Made by the backup script in unattended mode while this script holds the
# lock, with pruning off: pruning could delete the very snapshot being restored.
if $DO_SAFETY; then
  echo ""
  echo "=== Safety snapshot of the target ==="
  docker compose up -d --wait postgres >/dev/null 2>&1 || true
  SAFETY_LOG="$(mktemp)"
  if OUTLINE_BACKUP_ROOT="$BACKUP_ROOT" OUTLINE_INSTANCE_DIR="$INSTANCE_DIR" OUTLINE_BACKUP_KEEP=0 \
     OUTLINE_BACKUP_TYPE="pre-restore safety snapshot" OUTLINE_BACKUP_LOCK_HELD=true \
     "$BACKUP_SCRIPT" 2>&1 | tee "$SAFETY_LOG"; then
    SAFETY_DEST="$(sed -n 's/^Backup complete: //p' "$SAFETY_LOG" | tail -n1)"
    rm -f "$SAFETY_LOG"
  else
    rm -f "$SAFETY_LOG"
    echo ""
    echo "The safety snapshot FAILED (see above)."
    read -rp "Continue WITHOUT a safety snapshot? [y/N]: " ANS_NOSAFE
    [[ "$ANS_NOSAFE" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; exit 1; }
  fi
fi

# ── 11. Stop Outline ──────────────────────────────────────────────────────────
echo ""
echo "=== Stopping Outline ==="
CHANGED=true
if $RESET_DB_VOLUME; then
  # down keeps the volumes; the database volume, which carries the old
  # credentials, is then removed by hand. storage-data is not touched here.
  docker compose down
  DB_VOL="$(vol_of database-data)"
  if [ -n "$DB_VOL" ]; then
    docker volume rm "$DB_VOL" >/dev/null
    echo "Removed volume $DB_VOL"
  fi
else
  docker compose stop outline
  # Redis holds only caches and queued jobs, all about the data being replaced.
  docker compose exec -T redis redis-cli FLUSHALL </dev/null >/dev/null 2>&1 || true
fi

# ── 12. .env ──────────────────────────────────────────────────────────────────
if $FULL; then
  echo ""
  echo "=== Restoring .env ==="
  cp "$SNAP_ENV" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Restored: $ENV_FILE"
fi

# ── 13. Database ──────────────────────────────────────────────────────────────
echo ""
echo "=== Restoring the database ==="
docker compose up -d postgres
wait_db

# DROP DATABASE cannot run inside a transaction or target the database it is
# connected to, so work from the maintenance database. WITH (FORCE) ends any
# lingering connection.
echo "Re-creating the database..."
db_sh 'psql -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -v db="$POSTGRES_DB"' <<'SQL'
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db";
SQL

# One transaction: a failure part-way leaves the empty database, not a
# half-loaded one.
echo "Loading the dump..."
gunzip -c "$SNAP_DUMP" \
  | db_sh 'psql -q -v ON_ERROR_STOP=1 --single-transaction -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
echo "Database restored."

# ── 14. Attachments ───────────────────────────────────────────────────────────
if $HAS_FILES; then
  echo ""
  echo "=== Restoring attachments ==="
  ATTACH_VOL="$(vol_of storage-data)"
  if [ -z "$ATTACH_VOL" ]; then
    # No volume yet: let Compose create it (with its labels) without starting Outline.
    docker compose up --no-start outline >/dev/null
    ATTACH_VOL="$(vol_of storage-data)"
  fi
  [ -n "$ATTACH_VOL" ] || _die "the storage-data volume of project $PROJECT could not be found or created."
  docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull "$HELPER_IMAGE" >/dev/null
  # Emptied in place (dotfiles included) and unpacked as root, which keeps the
  # stored owners - the outline container's user has to be able to write there.
  docker run --rm -i --network none -v "$ATTACH_VOL":/data "$HELPER_IMAGE" \
    sh -euc 'find /data -mindepth 1 -delete; tar -xzf - -C /data' < "$SNAP_FILES"
  echo "Attachments restored into $ATTACH_VOL."
fi

# ── 15. Start Outline ─────────────────────────────────────────────────────────
# /_health checks the database and Redis connections; Outline runs pending
# migrations before it starts answering.
echo ""
echo "=== Starting Outline ==="
docker compose up -d

echo -n "Waiting for Outline on 127.0.0.1:$PORT"
OUTLINE_UP=false
for _ in $(seq 1 100); do   # 5 minutes
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/_health" 2>/dev/null || true)"
  if [ "$CODE" = "200" ]; then
    OUTLINE_UP=true
    break
  fi
  echo -n "."
  sleep 3
done
echo ""

if ! $OUTLINE_UP; then
  echo ""
  echo "---- last 40 lines of the outline log ----"
  docker compose logs --no-color --tail 40 outline 2>&1 || true
  echo "------------------------------------------"
  _die "Outline did not answer on 127.0.0.1:$PORT/_health after the restore."
fi
exec 9>&-   # release the lock

# ── 16. Things a restore cannot check for you ─────────────────────────────────
NEW_OIDC_SECRET="$(_env_get "$ENV_FILE" OIDC_CLIENT_SECRET)"
if $FULL && [ -n "$NEW_OIDC_SECRET" ] && [ "$NEW_OIDC_SECRET" != "$OLD_OIDC_SECRET" ]; then
  echo ""
  echo "WARNING: the restored .env has a different OIDC_CLIENT_SECRET than this instance had."
  echo "         Keycloak sign-in works only if Keycloak's '$(_env_get "$ENV_FILE" OIDC_CLIENT_ID)' client has that"
  echo "         secret: restore Keycloak from the same time, or copy Keycloak's secret (Clients ->"
  echo "         $(_env_get "$ENV_FILE" OIDC_CLIENT_ID) -> Credentials) into OIDC_CLIENT_SECRET in $ENV_FILE, then:"
  echo "         cd $INSTANCE_DIR && docker compose up -d"
fi

NGINX_SITE="/etc/nginx/sites-enabled/$DOMAIN"
if [ -r "$NGINX_SITE" ] && ! grep -q "127.0.0.1:$PORT" "$NGINX_SITE"; then
  echo ""
  echo "WARNING: $NGINX_SITE does not proxy to 127.0.0.1:$PORT, where Outline is published now."
  echo "         Update proxy_pass there and reload Nginx."
fi

echo ""
echo "Restore complete. Outline answers on 127.0.0.1:$PORT."
echo "Instance: https://$DOMAIN"
[ -n "$SAFETY_DEST" ] && echo "The target's previous state is in: $SAFETY_DEST"
echo "Verify by signing in and opening a document that has an image."
echo ""
