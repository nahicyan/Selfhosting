#!/bin/bash
set -euo pipefail
# =============================================================================
# Outline Docker Backup Script
# =============================================================================
# Backs up an instance installed by outline-docker-install.sh into one
# timestamped snapshot:
#   <backup-root>/outline/<domain>/<date-n-time>/postgres/outline.sql.gz
#   <backup-root>/outline/<domain>/<date-n-time>/attachments/attachments.tar.gz
#   <backup-root>/outline/<domain>/<date-n-time>/config/.env
#   <backup-root>/outline/<domain>/<date-n-time>/config/docker-compose.yml
#   <backup-root>/outline/<domain>/<date-n-time>/manifest.txt
#
# That is what Outline's backup guidance names: the database, the file
# storage and the environment.
#
# postgres/     A plain-SQL pg_dump of the outline database, run inside the
#               postgres container, so pg_dump always matches the server.
#               Documents, revisions, collections, users and team settings
#               live here. pg_dump reads one consistent snapshot, so Outline
#               stays up.
# attachments/  The storage-data volume (FILE_STORAGE=local: uploads and
#               images), read through a read-only busybox container. Taken
#               AFTER the dump, so a file uploaded in between is an unused
#               extra in the archive, never a database row pointing at a
#               missing file.
# config/       .env holds SECRET_KEY. Outline encrypts data in the database
#               with it - the dump is only fully readable with this .env.
#               docker-compose.yml (and docker-compose.override.yml, if any)
#               are reference copies; the restore does not put them back.
#
# Not archived: Redis (caches and queued jobs only) and Nginx/TLS (the
# installer regenerates the vhost, certbot re-issues the certificate).
# Keycloak has its own keycloak-docker-backup.sh.
#
# Unattended (cron) mode - set both to skip every prompt:
#   OUTLINE_BACKUP_ROOT    backup root, e.g. /home/backup
#   OUTLINE_INSTANCE_DIR   instance directory, e.g. /var/www/docker/outline/docs.example.com
#   OUTLINE_BACKUP_KEEP    snapshots to keep per domain (default 7; 0 = never prune)
# Example crontab line (as the user that owns the instance, in the docker group):
#   30 2 * * * OUTLINE_BACKUP_ROOT=/home/backup OUTLINE_INSTANCE_DIR=/var/www/docker/outline/docs.example.com /path/to/outline-docker-backup.sh >> $HOME/outline-backup.log 2>&1
#
# A lock file in the instance directory stops two backups, or a backup and a
# restore, from running against the same instance at once.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_OUTLINE_PATH="/var/www/docker/outline"
HELPER_IMAGE="busybox"
RETAIN_COUNT="${OUTLINE_BACKUP_KEEP:-7}"
# Internal: outline-docker-restore.sh sets these for its pre-restore snapshot,
# which it takes while already holding the instance lock.
SNAPSHOT_TYPE="${OUTLINE_BACKUP_TYPE:-backup}"
LOCK_HELD="${OUTLINE_BACKUP_LOCK_HELD:-false}"

UNATTENDED=false
[[ -n "${OUTLINE_BACKUP_ROOT:-}" && -n "${OUTLINE_INSTANCE_DIR:-}" ]] && UNATTENDED=true

BACKUP_DEST=""
BACKUP_DONE=false

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "Error: $*" >&2; exit 1; }

_human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# A key from .env, with one layer of matching quotes removed. Read, not
# sourced: a value such as SMTP_FROM_EMAIL=Outline <noreply@example.com> is not
# valid shell, and nothing from .env should leak into this shell.
_env_get() {  # _env_get <file> <key>
  local v
  v="$(sed -n "s/^${2}=//p" "$1" | tail -n1)"
  if [[ "$v" == \'*\' || "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# Every failure after the snapshot directory exists removes it, so a partial
# snapshot is never mistaken for a good one during a restore.
_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$BACKUP_DONE" != "true" && -n "$BACKUP_DEST" && -d "$BACKUP_DEST" ]]; then
    echo "" >&2
    echo "Backup failed (exit $rc) - removing incomplete $BACKUP_DEST" >&2
    rm -rf "$BACKUP_DEST"
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=====> Outline Backup"
echo "========================================"
$UNATTENDED && echo "Unattended mode ($(date -Iseconds))"

for cmd in docker gzip tar sed awk find df numfmt flock; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
[[ "$RETAIN_COUNT" =~ ^[0-9]+$ ]] || _die "OUTLINE_BACKUP_KEEP must be a number (0 = never prune)."

# ── 1. Where to save the backup ───────────────────────────────────────────────
if [[ -n "${OUTLINE_BACKUP_ROOT:-}" ]]; then
  BACKUP_ROOT="$OUTLINE_BACKUP_ROOT"
else
  echo "Choose the directory where you want to save the backup:"
  echo "  1) Default: $DEFAULT_BACKUP_ROOT"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " BACKUP_CHOICE
  if [ "$BACKUP_CHOICE" = "2" ]; then
    read -rep "Enter custom backup directory: " BACKUP_ROOT
    BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
  else
    BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
  fi
fi
BACKUP_ROOT="${BACKUP_ROOT%/}"
[[ "$BACKUP_ROOT" = /* ]] || _die "the backup directory must be an absolute path."

if [ ! -d "$BACKUP_ROOT" ]; then
  if $UNATTENDED; then
    mkdir -p "$BACKUP_ROOT" || _die "cannot create $BACKUP_ROOT."
  else
    read -rp "Directory '$BACKUP_ROOT' does not exist. Create it? [y/N]: " CREATE_DIR
    [[ "$CREATE_DIR" =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
    mkdir -p "$BACKUP_ROOT" 2>/dev/null || sudo mkdir -p "$BACKUP_ROOT"
    [ -w "$BACKUP_ROOT" ] || sudo chown "$(id -u):$(id -g)" "$BACKUP_ROOT"
    echo "Created directory: $BACKUP_ROOT"
  fi
fi
[ -w "$BACKUP_ROOT" ] || _die "$BACKUP_ROOT is not writable by $(id -un)."

# ── 2. Pick the instance ──────────────────────────────────────────────────────
if [[ -n "${OUTLINE_INSTANCE_DIR:-}" ]]; then
  INSTANCE_DIR="${OUTLINE_INSTANCE_DIR%/}"
else
  echo ""
  echo "Where are your Outline instances located?"
  echo "  1) Default: $DEFAULT_OUTLINE_PATH"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " LOCATION_CHOICE
  if [ "$LOCATION_CHOICE" = "2" ]; then
    read -rep "Enter custom Outline base path: " OUTLINE_BASE_PATH
    OUTLINE_BASE_PATH="${OUTLINE_BASE_PATH/#\~/$HOME}"
  else
    OUTLINE_BASE_PATH="$DEFAULT_OUTLINE_PATH"
  fi
  OUTLINE_BASE_PATH="${OUTLINE_BASE_PATH%/}"
  [ -d "$OUTLINE_BASE_PATH" ] || _die "Directory '$OUTLINE_BASE_PATH' not found."

  # An instance is a directory with Outline's docker-compose.yml next to a .env.
  INSTANCES=()
  for f in "$OUTLINE_BASE_PATH"/*/docker-compose.yml; do
    if [ -r "${f%/*}/.env" ] && grep -q 'outlinewiki/outline' "$f"; then
      INSTANCES+=("${f%/*}")
    fi
  done
  [ ${#INSTANCES[@]} -gt 0 ] || _die "No Outline instances found in '$OUTLINE_BASE_PATH' (or their .env is not readable by $(id -un))."

  echo ""
  if [ ${#INSTANCES[@]} -eq 1 ]; then
    INSTANCE_DIR="${INSTANCES[0]}"
    echo "Using instance: $(basename "$INSTANCE_DIR")  ($INSTANCE_DIR)"
  else
    echo "Found instances:"
    for i in "${!INSTANCES[@]}"; do
      echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
    done
    echo ""
    read -rp "Select instance number: " INST_NUM
    if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
      _die "Invalid selection."
    fi
    INSTANCE_DIR="${INSTANCES[$((INST_NUM-1))]}"
  fi
fi

ENV_FILE="$INSTANCE_DIR/.env"
[ -f "$INSTANCE_DIR/docker-compose.yml" ] || _die "$INSTANCE_DIR/docker-compose.yml not found."
[ -r "$ENV_FILE" ] || _die "cannot read $ENV_FILE."
URL="$(_env_get "$ENV_FILE" URL)"
DOMAIN="${URL#*://}"; DOMAIN="${DOMAIN%%/*}"
PROJECT="$(_env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)"
[ -n "$DOMAIN" ] && [ -n "$PROJECT" ] \
  || _die "no URL or COMPOSE_PROJECT_NAME in $ENV_FILE - not an instance from outline-docker-install.sh?"

# Run from the instance directory, like the commands the installer prints:
# Compose then reads this instance's .env and docker-compose.override.yml.
cd "$INSTANCE_DIR"

# A shell command inside the postgres container. psql/pg_dump use -h 127.0.0.1,
# which the official image trusts, so no password is needed. exec would
# otherwise attach this script's stdin, hence </dev/null.
pg() { docker compose exec -T postgres sh -c "$1" </dev/null; }

# The real Docker volume behind a Compose volume, found by Compose's labels.
vol_of() {
  docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.volume=$1" | sed -n '1p'
}

# ── 3. Lock ───────────────────────────────────────────────────────────────────
if [ "$LOCK_HELD" != "true" ]; then
  exec 9>>"$INSTANCE_DIR/.maintenance.lock" || _die "cannot open $INSTANCE_DIR/.maintenance.lock."
  flock -n 9 || _die "another backup or restore of $DOMAIN is running (lock: $INSTANCE_DIR/.maintenance.lock)."
fi

# ── 4. What there is to back up ───────────────────────────────────────────────
[ -n "$(docker compose ps -q postgres 2>/dev/null || true)" ] \
  || _die "the postgres service is not running for $DOMAIN. Start it: cd $INSTANCE_DIR && docker compose up -d"

FILE_STORAGE="$(_env_get "$ENV_FILE" FILE_STORAGE)"
ATTACH_VOL=""
if [ "$FILE_STORAGE" = "local" ]; then
  ATTACH_VOL="$(vol_of storage-data)"
  [ -n "$ATTACH_VOL" ] || _die "the storage-data volume of project $PROJECT was not found."
  # Fetch the helper image now, so a missing image cannot fail the backup halfway.
  docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull "$HELPER_IMAGE" >/dev/null
fi

# The Outline release that last migrated this database - what a restore target
# has to be able to run. Read from the outline container's image, so it works
# whether the container is running or not.
OUTLINE_CID="$(docker compose ps -aq outline 2>/dev/null | head -n1 || true)"
OUTLINE_IMAGE="unknown"
OUTLINE_VERSION=""
if [ -n "$OUTLINE_CID" ]; then
  OUTLINE_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$OUTLINE_CID")"
  OUTLINE_VERSION="$(docker run --rm --network none --entrypoint node "$(docker inspect -f '{{.Image}}' "$OUTLINE_CID")" \
    -p "require('/opt/outline/package.json').version" 2>/dev/null || true)"
fi

# ── 5. Sizes and free space ───────────────────────────────────────────────────
DB_BYTES="$(pg 'psql -h 127.0.0.1 -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_database_size(current_database())"' 2>/dev/null \
  | tr -d '[:space:]' || true)"
[[ "$DB_BYTES" =~ ^[0-9]+$ ]] || _die "could not read the database size from the postgres container."
FILES_KB=0
if [ -n "$ATTACH_VOL" ]; then
  FILES_KB="$(docker run --rm --network none -v "$ATTACH_VOL":/data:ro "$HELPER_IMAGE" du -sk /data | awk '{print $1}')"
fi

# Upper bound: compression only makes it smaller.
NEED_KB=$(( DB_BYTES / 1024 + FILES_KB + 10240 ))
AVAIL_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"

TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/outline/$DOMAIN"
DEST="$DOMAIN_BACKUP_DIR/$TIMESTAMP"
[ ! -e "$DEST" ] || _die "$DEST already exists."

echo ""
echo "Instance        : $DOMAIN"
echo "Install dir     : $INSTANCE_DIR"
echo "Outline         : ${OUTLINE_VERSION:-version unknown}  ($OUTLINE_IMAGE)"
echo "Database        : $(_human "$DB_BYTES") on disk"
if [ -n "$ATTACH_VOL" ]; then
  echo "Attachments     : $(_human $(( FILES_KB * 1024 ))) in volume $ATTACH_VOL"
else
  echo "Attachments     : NOT included - FILE_STORAGE=${FILE_STORAGE:-unset}, back that storage up separately"
fi
echo "Backup folder   : $DEST"
echo "Keep            : $([ "$RETAIN_COUNT" -eq 0 ] && echo "all snapshots" || echo "last $RETAIN_COUNT snapshots of $DOMAIN")"

if [ "$NEED_KB" -gt "$AVAIL_KB" ]; then
  echo ""
  echo "WARNING: this backup needs up to $(_human $(( NEED_KB * 1024 ))), but only"
  echo "         $(_human $(( AVAIL_KB * 1024 ))) is free on $BACKUP_ROOT."
  $UNATTENDED && _die "not enough free space on $BACKUP_ROOT."
  read -rp "Continue anyway? [y/N]: " ANS_SPACE
  [[ "$ANS_SPACE" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

if ! $UNATTENDED; then
  echo ""
  read -rp "Proceed with backup? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── 6. Snapshot directory ─────────────────────────────────────────────────────
# Everything from here on is created 700/600: database dump and SECRET_KEY.
umask 077
BACKUP_DEST="$DEST"
mkdir -p "$DEST/postgres" "$DEST/config"

# ── 7. Database ───────────────────────────────────────────────────────────────
# --no-owner and --no-privileges keep the dump loadable whatever the role is called.
echo ""
echo "=== Backing up the database ==="
DUMP="$DEST/postgres/outline.sql.gz"
pg 'pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' | gzip > "$DUMP"
gzip -t "$DUMP"
# pg_dump ends every complete dump with this line, so it also catches truncation.
gunzip -c "$DUMP" | tail -n 20 | grep 'PostgreSQL database dump complete' >/dev/null \
  || _die "the database dump is incomplete (no 'dump complete' trailer)."
echo "Saved: $DUMP ($(du -h "$DUMP" | cut -f1))"

# ── 8. Attachments ────────────────────────────────────────────────────────────
if [ -n "$ATTACH_VOL" ]; then
  echo ""
  echo "=== Backing up attachments ($ATTACH_VOL) ==="
  mkdir -p "$DEST/attachments"
  # Read-only mount: Outline keeps running and nothing here can change its files.
  docker run --rm --network none -v "$ATTACH_VOL":/data:ro "$HELPER_IMAGE" \
    tar -czf - -C /data . > "$DEST/attachments/attachments.tar.gz"
  tar -tzf "$DEST/attachments/attachments.tar.gz" >/dev/null || _die "the attachments archive is corrupt."
  echo "Saved: $DEST/attachments/attachments.tar.gz ($(du -h "$DEST/attachments/attachments.tar.gz" | cut -f1))"
fi

# ── 9. Configuration ──────────────────────────────────────────────────────────
echo ""
echo "=== Backing up .env and compose files ==="
cp "$ENV_FILE" "$DEST/config/.env"
cp docker-compose.yml "$DEST/config/"
[ -f docker-compose.override.yml ] && cp docker-compose.override.yml "$DEST/config/"
echo "Saved: $DEST/config/"

# ── 10. Manifest ──────────────────────────────────────────────────────────────
# Best-effort details; none of them can fail the backup.
PG_VERSION="$(pg 'postgres --version' 2>/dev/null | tr -d '\r' || true)"
LAST_MIGRATION="$(pg 'psql -h 127.0.0.1 -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT max(name) FROM \"SequelizeMeta\""' 2>/dev/null | tr -d '\r' || true)"
{
  echo "Outline backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Type            : $SNAPSHOT_TYPE"
  echo "Domain          : $DOMAIN"
  echo "Install dir     : $INSTANCE_DIR"
  echo "Compose project : $PROJECT"
  echo "Outline version : ${OUTLINE_VERSION:-unknown}"
  echo "Outline image   : $OUTLINE_IMAGE"
  echo "PostgreSQL      : ${PG_VERSION:-unknown}"
  echo "Last migration  : ${LAST_MIGRATION:-unknown}"
  echo "postgres/       : outline.sql.gz (pg_dump of the outline database, verified complete)"
  if [ -n "$ATTACH_VOL" ]; then
    echo "attachments/    : attachments.tar.gz (the storage-data volume)"
  else
    echo "attachments/    : none - FILE_STORAGE=${FILE_STORAGE:-unset}"
  fi
  echo "config/         : .env (SECRET_KEY - keep it with the dump), reference compose files"
} > "$DEST/manifest.txt"
BACKUP_DONE=true

# ── 11. Prune old snapshots for this domain ───────────────────────────────────
# Only directories named like a timestamp are considered, oldest first out.
if [ "$RETAIN_COUNT" -gt 0 ]; then
  mapfile -t OLD_SNAPSHOTS < <(find "$DOMAIN_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{4}(-[0-9]{2}){5}' | sort -r | tail -n +$((RETAIN_COUNT + 1)))
  if [ ${#OLD_SNAPSHOTS[@]} -gt 0 ]; then
    echo ""
    echo "Pruning old snapshots (keeping last $RETAIN_COUNT)..."
    for OLD in "${OLD_SNAPSHOTS[@]}"; do
      echo "  Removing: $OLD"
      rm -rf "$OLD"
    done
  fi
fi

echo ""
echo "Backup complete: $DEST"
echo ""
cat "$DEST/manifest.txt"
