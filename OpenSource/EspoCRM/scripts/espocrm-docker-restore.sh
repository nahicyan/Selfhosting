#!/bin/bash
set -euo pipefail
# =============================================================================
# EspoCRM Docker Restore Script
# =============================================================================
# Restores a snapshot made by espocrm-docker-backup.sh into an instance
# installed by espocrm-docker-install.sh:
#   <backup-root>/espocrm/<domain>/<date-n-time>/database/espocrm.sql.gz
#   <backup-root>/espocrm/<domain>/<date-n-time>/files/files.tar.gz
#
# The database and the files are always restored together. custom/ defines
# the custom entities and fields the database tables must match, and
# data/config-internal.php holds cryptKey, which decrypts the email-account
# passwords stored in the database. Either half alone leaves EspoCRM broken.
#
# The target can be the instance the snapshot came from (rollback), or a fresh
# instance - on a new host, with another domain or other passwords (disaster
# recovery: run espocrm-docker-install.sh first, then restore into it). The
# target's .env stays the source of truth:
#   - the database credentials in the restored config-internal.php are
#     rewritten to the target's (ESPOCRM_DATABASE_PASSWORD in its .env);
#   - siteUrl and the WebSocket URL are re-applied from the target's
#     ESPOCRM_DOMAIN on start (ESPOCRM_CONFIG_* in docker-compose.yml).
# The snapshot's .env is never put back.
#
# What happens, in order:
#   1. The snapshot is verified (gzip integrity, the dump's "-- Dump completed"
#      trailer, config files present in the archive) before anything changes.
#   2. Optional safety snapshot of the target, made with
#      espocrm-docker-backup.sh, so the restore can itself be undone.
#   3. espocrm, espocrm-daemon and espocrm-websocket are stopped (MariaDB stays up).
#   4. The espocrm database is dropped, recreated and loaded from the dump.
#   5. data, custom and client/custom are emptied and extracted from the archive.
#      The database credentials are rewritten, data/cache is cleared and
#      ownership goes back to www-data.
#   6. espocrm starts. Its entrypoint clears the cache and runs migrations - the
#      same as an upgrade, when the snapshot is from an older EspoCRM. The
#      script waits until it answers, then starts the daemon and websocket.
#
# The target's EspoCRM version must be the snapshot's or newer: migrations run
# forward only.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/espocrm-docker-backup.sh"

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_ESPOCRM_PATH="/var/www/docker/espocrm"

CHANGED=false   # true once the target is touched (services stopped)
STOPPED=false
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
  if $STOPPED; then
    echo "EspoCRM is stopped (MariaDB is still running). To start it as it is now:" >&2
    echo "  cd $INSTANCE_DIR && docker compose up -d" >&2
  fi
  if [[ -n "$SAFETY_DEST" ]]; then
    echo "The target's previous state is in: $SAFETY_DEST" >&2
    echo "Restore it with this script to undo." >&2
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=====> EspoCRM Restore"
echo "========================================"

for cmd in docker gzip tar sed awk find sort curl flock; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
[ -x "$BACKUP_SCRIPT" ] || _die "espocrm-docker-backup.sh not found next to this script (needed for the safety snapshot)."

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

ESPOCRM_BACKUPS_DIR="$BACKUP_ROOT/espocrm"
[ -d "$ESPOCRM_BACKUPS_DIR" ] || _die "'$ESPOCRM_BACKUPS_DIR' not found."

# ── 2. Domain the backup came from ────────────────────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$ESPOCRM_BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || _die "No domain backup folders found in '$ESPOCRM_BACKUPS_DIR'."

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
printf "  %-4s %-28s %-9s %-9s %-9s %s\n" "#" "Date" "Version" "Database" "Files" "Note"
printf "  %-4s %-28s %-9s %-9s %-9s %s\n" "----" "----------------------------" "---------" "---------" "---------" "----"
for i in "${!SNAPSHOTS[@]}"; do
  S="${SNAPSHOTS[$i]}"
  DB_S="--";   [ -f "$S/database/espocrm.sql.gz" ] && DB_S="$(du -h "$S/database/espocrm.sql.gz" | cut -f1)"
  FILES_S="--"; [ -f "$S/files/files.tar.gz" ]     && FILES_S="$(du -h "$S/files/files.tar.gz" | cut -f1)"
  NOTE=""
  [ "$(_manifest_get "$S" "Type")" = "pre-restore safety snapshot" ] && NOTE="pre-restore"
  [ -f "$S/manifest.txt" ] || NOTE="no manifest - incomplete?"
  VER="$(_manifest_get "$S" "EspoCRM version")"
  printf "  %-4s %-28s %-9s %-9s %-9s %s\n" "$((i+1)))" "$(_nice_date "$(basename "$S")")" \
    "${VER:-?}" "$DB_S" "$FILES_S" "$NOTE"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM
if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  _die "Invalid selection."
fi

SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"
SNAP_DUMP="$SNAPSHOT_DIR/database/espocrm.sql.gz"
SNAP_FILES="$SNAPSHOT_DIR/files/files.tar.gz"
SNAP_VERSION="$(_manifest_get "$SNAPSHOT_DIR" "EspoCRM version")"
SNAP_DOMAIN="$(_manifest_get "$SNAPSHOT_DIR" "Domain")"
[ -f "$SNAP_DUMP" ]  || _die "this snapshot has no database dump."
[ -f "$SNAP_FILES" ] || _die "this snapshot has no files archive - the database cannot be used without it."

# ── 4. Verify the snapshot before anything changes ────────────────────────────
echo ""
echo "Verifying the snapshot..."
gzip -t "$SNAP_DUMP" || _die "$SNAP_DUMP is corrupt."
gunzip -c "$SNAP_DUMP" | tail -n 1 | grep -q '^-- Dump completed' \
  || _die "$SNAP_DUMP is incomplete (no '-- Dump completed' trailer)."
SNAP_LIST="$(tar -tzf "$SNAP_FILES")" || _die "$SNAP_FILES is corrupt."
for f in data/config.php data/config-internal.php data/state.php; do
  grep -qx "$f" <<< "$SNAP_LIST" || _die "$f is not in $SNAP_FILES."
done
echo "  OK"

# ── 5. Target instance ────────────────────────────────────────────────────────
echo ""
echo "Where should this be restored TO?"
echo "  1) Default: $DEFAULT_ESPOCRM_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " TARGET_LOCATION_CHOICE
if [ "$TARGET_LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom EspoCRM base path: " ESPOCRM_BASE_PATH
  ESPOCRM_BASE_PATH="${ESPOCRM_BASE_PATH/#\~/$HOME}"
else
  ESPOCRM_BASE_PATH="$DEFAULT_ESPOCRM_PATH"
fi
ESPOCRM_BASE_PATH="${ESPOCRM_BASE_PATH%/}"
[ -d "$ESPOCRM_BASE_PATH" ] || _die "'$ESPOCRM_BASE_PATH' not found."

TARGETS=()
for env_f in "$ESPOCRM_BASE_PATH"/.env "$ESPOCRM_BASE_PATH"/*/.env; do
  if [ -r "$env_f" ] && grep -q '^ESPOCRM_DOMAIN=' "$env_f" && [ -f "${env_f%/.env}/docker-compose.yml" ]; then
    TARGETS+=("${env_f%/.env}")
  fi
done
[ ${#TARGETS[@]} -gt 0 ] || _die "No EspoCRM instances found in '$ESPOCRM_BASE_PATH' - install one first with espocrm-docker-install.sh."

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
COMPOSE_FILE="$INSTANCE_DIR/docker-compose.yml"
DOMAIN="$(_env_get "$ENV_FILE" ESPOCRM_DOMAIN)"
PORT="$(_env_get "$ENV_FILE" ESPOCRM_PORT)"
DB_PASSWORD="$(_env_get "$ENV_FILE" ESPOCRM_DATABASE_PASSWORD)"
[ -n "$DOMAIN" ]      || _die "no ESPOCRM_DOMAIN in $ENV_FILE."
[[ "$PORT" =~ ^[0-9]+$ ]] || _die "no valid ESPOCRM_PORT in $ENV_FILE."
[ -n "$DB_PASSWORD" ] || _die "no ESPOCRM_DATABASE_PASSWORD in $ENV_FILE."

dc() { docker compose --project-directory "$INSTANCE_DIR" -f "$COMPOSE_FILE" "$@"; }

# The app container only has to exist (any state): the restore writes its
# volumes through a helper container, and a broken instance is a common reason
# to restore.
APP_CID="$(dc ps -aq espocrm 2>/dev/null || true)"
[ -n "$APP_CID" ] || _die "the espocrm container does not exist for $DOMAIN. Start the instance once: cd $INSTANCE_DIR && docker compose up -d"
APP_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP_CID")"
APP_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$APP_CID")"
TARGET_VERSION="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$APP_IMAGE_ID" \
  | sed -n 's/^ESPOCRM_VERSION=//p' | head -n1)"

# ── 6. Version check ──────────────────────────────────────────────────────────
if [ -z "$SNAP_VERSION" ] || [ -z "$TARGET_VERSION" ]; then
  echo ""
  echo "WARNING: could not compare versions (snapshot: ${SNAP_VERSION:-unknown}, target: ${TARGET_VERSION:-unknown})."
  read -rp "Restore anyway? [y/N]: " ANS_VER
  [[ "$ANS_VER" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; exit 0; }
elif [ "$SNAP_VERSION" != "$TARGET_VERSION" ]; then
  _version_ge "$TARGET_VERSION" "$SNAP_VERSION" || \
    _die "the snapshot is from EspoCRM $SNAP_VERSION but the target runs $TARGET_VERSION. Migrations only run forward - set ESPOCRM_VERSION=$SNAP_VERSION (or newer) in $ENV_FILE, run 'docker compose up -d', then restore."
  echo ""
  echo "NOTE: the snapshot is from EspoCRM $SNAP_VERSION and the target runs $TARGET_VERSION."
  echo "      EspoCRM migrates the restored data when it starts, the same as an upgrade."
  echo "      Extensions in the snapshot must support $TARGET_VERSION."
  read -rp "Continue? [y/N]: " ANS_VER
  [[ "$ANS_VER" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; exit 0; }
fi

# ── 7. Safety snapshot ────────────────────────────────────────────────────────
echo ""
echo "A safety snapshot saves the target's CURRENT database and files to"
echo "$BACKUP_ROOT/espocrm/$DOMAIN/ before anything is replaced, so the restore"
echo "can be undone."
read -rp "Take a safety snapshot first? [Y/n]: " ANS_SAFETY
if [[ "$ANS_SAFETY" =~ ^[Nn]$ ]]; then DO_SAFETY=false; else DO_SAFETY=true; fi

# ── 8. Final confirmation ─────────────────────────────────────────────────────
echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Backup snapshot : $SNAPSHOT_DIR"
echo "  from          : ${SNAP_DOMAIN:-?}, EspoCRM ${SNAP_VERSION:-?}"
echo "Target instance : $DOMAIN (EspoCRM ${TARGET_VERSION:-?}, $APP_IMAGE)"
echo "Install dir     : $INSTANCE_DIR"
echo "Restoring       : database 'espocrm' + data, custom, client/custom"
echo "Safety snapshot : $($DO_SAFETY && echo "yes, into $BACKUP_ROOT/espocrm/$DOMAIN/" || echo "NO")"
echo "========================================================="
echo ""
echo "WARNING: EspoCRM is unavailable while this runs."
echo "WARNING: this DROPS + REPLACES the target's database and ALL of its files"
echo "         (uploads, customizations, extensions)."
$DO_SAFETY || echo "WARNING: no safety snapshot - the target's current data cannot be recovered afterwards."
if [ -n "$SNAP_DOMAIN" ] && [ "$SNAP_DOMAIN" != "$DOMAIN" ]; then
  echo "NOTE:    the snapshot comes from $SNAP_DOMAIN; it will be served as $DOMAIN."
fi
echo ""
read -rp "Type 'yes' to confirm and proceed: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Restore cancelled."; exit 0; }

# ── 9. MariaDB must be up (for the safety snapshot and the restore) ───────────
if [ -z "$(dc ps -q espocrm-db 2>/dev/null || true)" ]; then
  echo ""
  echo "=== Starting MariaDB ==="
  dc up -d --wait espocrm-db
fi
DB_CID="$(dc ps -q espocrm-db)"
[ -n "$DB_CID" ] || _die "espocrm-db is not running."

# ── 10. Safety snapshot ───────────────────────────────────────────────────────
# Made by the backup script in unattended mode, with pruning off: pruning here
# could delete the very snapshot being restored.
if $DO_SAFETY; then
  echo ""
  echo "=== Safety snapshot of the target ==="
  SAFETY_LOG="$(mktemp)"
  if ESPOCRM_BACKUP_ROOT="$BACKUP_ROOT" ESPOCRM_INSTANCE_DIR="$INSTANCE_DIR" \
     ESPOCRM_BACKUP_KEEP=0 ESPOCRM_BACKUP_TYPE="pre-restore safety snapshot" \
     "$BACKUP_SCRIPT" 2>&1 | tee "$SAFETY_LOG"; then
    SAFETY_DEST="$(sed -n 's/^Backup complete: //p' "$SAFETY_LOG" | tail -n1)"
    rm -f "$SAFETY_LOG"
  else
    rm -f "$SAFETY_LOG"
    echo ""
    echo "The safety snapshot FAILED (see above). A target whose files cannot be"
    echo "read - e.g. a failed install - cannot be snapshotted."
    read -rp "Continue WITHOUT a safety snapshot? [y/N]: " ANS_NOSAFE
    [[ "$ANS_NOSAFE" =~ ^[Yy]$ ]] || { echo "Restore cancelled. Nothing was changed."; exit 1; }
  fi
fi

# ── 11. Lock ──────────────────────────────────────────────────────────────────
# Shared with the backup script. Waits for a running backup to finish; a
# scheduled backup that starts during the restore fails instead of dumping a
# half-restored database.
exec 9>>"$INSTANCE_DIR/.maintenance.lock" || _die "cannot open $INSTANCE_DIR/.maintenance.lock."
echo ""
echo "Waiting for the instance lock..."
flock -w 600 9 || _die "another backup or restore of $DOMAIN is still running."

# ── 12. Stop EspoCRM ──────────────────────────────────────────────────────────
echo ""
echo "=== Stopping espocrm, espocrm-daemon, espocrm-websocket ==="
CHANGED=true
STOPPED=true
dc stop espocrm-daemon espocrm-websocket espocrm

# ── 13. Database ──────────────────────────────────────────────────────────────
# Root password from the container's own environment, passed as MYSQL_PWD (not
# visible in `ps`). The espocrm user's grants are on `espocrm`.* and survive
# the drop.
echo ""
echo "=== Restoring the database ==="
echo "Dropping and recreating database 'espocrm'..."
docker exec "$DB_CID" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot \
  -e "DROP DATABASE IF EXISTS espocrm; CREATE DATABASE espocrm"'
echo "Loading dump..."
gunzip -c "$SNAP_DUMP" | docker exec -i "$DB_CID" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot espocrm'
echo "Database restored."

# ── 14. Files ─────────────────────────────────────────────────────────────────
# Through a helper container from the target's image, as root, against the
# stopped app's volumes. The snapshot's config-internal.php carries the source
# instance's database password, so the credentials are set to the target's
# with EspoCRM's own `config:set` (how the entrypoint writes them at install),
# before ownership goes back to www-data.
echo ""
echo "=== Restoring files (data, custom, client/custom) ==="
ESPO_DB_PW="$DB_PASSWORD" docker run --rm -i --network none -e ESPO_DB_PW \
  --volumes-from "$APP_CID" --entrypoint sh "$APP_IMAGE_ID" -c '
  set -e
  cd /var/www/html
  find data custom client/custom -mindepth 1 -delete
  tar -xzf -
  test -s data/config-internal.php
  bin/command config:set database.host espocrm-db >/dev/null
  bin/command config:set database.dbname espocrm >/dev/null
  bin/command config:set database.user espocrm >/dev/null
  bin/command config:set database.password "$ESPO_DB_PW" >/dev/null
  rm -rf data/cache
  chown -R www-data:www-data data custom client/custom
' < "$SNAP_FILES"
echo "Files restored; database credentials set to the target's."

# ── 15. Start EspoCRM ─────────────────────────────────────────────────────────
# Ready = Apache answers: the entrypoint runs migrations first and only then
# starts Apache. Repeated restarts mean the migration failed.
echo ""
echo "=== Starting EspoCRM (clears the cache, runs migrations) ==="
dc up -d espocrm
APP_CID="$(dc ps -aq espocrm)"
BASE_RESTARTS="$(docker inspect -f '{{.RestartCount}}' "$APP_CID" 2>/dev/null || echo 0)"

echo -n "Waiting for EspoCRM to answer on 127.0.0.1:$PORT"
APP_UP=false
APP_FAILED=false
for _ in $(seq 1 120); do   # 10 minutes
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  if [[ "$CODE" =~ ^[0-9]{3}$ && "$CODE" != "000" && "$CODE" -lt 500 ]]; then
    APP_UP=true
    break
  fi
  restarts="$(docker inspect -f '{{.RestartCount}}' "$APP_CID" 2>/dev/null || echo 0)"
  if (( restarts - BASE_RESTARTS >= 2 )); then
    APP_FAILED=true
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

if ! $APP_UP; then
  echo ""
  echo "---- last 40 lines of the espocrm log ----"
  dc logs --no-color --tail 40 espocrm 2>&1 || true
  echo "------------------------------------------"
  if $APP_FAILED; then
    echo "EspoCRM keeps restarting. If the log says the migration failed because of"
    echo "incompatible customizations, the snapshot's extensions do not support"
    echo "EspoCRM ${TARGET_VERSION:-this version}."
  fi
  _die "EspoCRM did not come up after the restore."
fi

echo "=== Starting espocrm-daemon and espocrm-websocket ==="
dc up -d
STOPPED=false
exec 9>&-   # release the lock

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "Restore complete. EspoCRM answers on 127.0.0.1:$PORT (HTTP $CODE)."
echo "Instance: https://$DOMAIN"
echo ""
echo "  - Users and passwords are the snapshot's, including admin's."
echo "    ESPOCRM_ADMIN_PASSWORD in .env only applied to the target's first start."
echo "  - The target's .env was kept; the snapshot's is in $SNAPSHOT_DIR/config/ for reference."
if [ -n "$SNAP_DOMAIN" ] && [ "$SNAP_DOMAIN" != "$DOMAIN" ]; then
  echo "  - siteUrl is now https://$DOMAIN (from .env). Links in emails sent before the"
  echo "    move still point to $SNAP_DOMAIN."
fi
[ -n "$SAFETY_DEST" ] && echo "  - The target's previous state is in: $SAFETY_DEST"
echo ""
