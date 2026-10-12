#!/bin/bash
set -euo pipefail
# =============================================================================
# EspoCRM Docker Backup Script
# =============================================================================
# Backs up an instance installed by espocrm-docker-install.sh into one
# timestamped snapshot:
#   <backup-root>/espocrm/<domain>/<date-n-time>/database/espocrm.sql.gz
#   <backup-root>/espocrm/<domain>/<date-n-time>/files/files.tar.gz
#   <backup-root>/espocrm/<domain>/<date-n-time>/config/.env
#   <backup-root>/espocrm/<domain>/<date-n-time>/config/docker-compose.yml
#   <backup-root>/espocrm/<domain>/<date-n-time>/manifest.txt
#
# database/  mariadb-dump of the "espocrm" database, run inside espocrm-db.
#            --single-transaction reads one consistent InnoDB snapshot, so
#            EspoCRM stays up. Checked for gzip integrity and for the
#            "-- Dump completed" trailer, so a truncated dump fails the backup.
# files/     The three EspoCRM 10 volumes: data (config.php, config-internal.php,
#            state.php, uploads in data/upload, logs), custom (Entity/Layout Manager
#            customizations, extensions) and client/custom. data/cache and
#            data/tmp are left out; EspoCRM rebuilds them. Taken AFTER the dump, so
#            a file uploaded in between is an orphan in the archive, never a
#            database row pointing at a missing file. config-internal.php holds
#            cryptKey, which decrypts the email-account passwords stored in the
#            database - the two halves only work together.
# config/    .env (mode 600) and docker-compose.yml as reference copies. The
#            restore does not put them back: the target's own .env decides its
#            domain, ports and passwords.
#
# The files are read through a throwaway container started from the instance's
# own EspoCRM image (--volumes-from, read-only, no network), so no sudo is
# needed, ownership is preserved, and it works even when the app container is
# stopped or crash-looping. Only espocrm-db has to be running.
#
# Unattended (cron) mode - set both to skip every prompt:
#   ESPOCRM_BACKUP_ROOT    backup root, e.g. /home/backup
#   ESPOCRM_INSTANCE_DIR   instance directory, e.g. /var/www/docker/espocrm/crm.example.com
#   ESPOCRM_BACKUP_KEEP    snapshots to keep per domain (default 7; 0 = never prune)
# Example crontab line (as a user in the docker group):
#   15 2 * * * ESPOCRM_BACKUP_ROOT=/home/backup ESPOCRM_INSTANCE_DIR=/var/www/docker/espocrm/crm.example.com /path/to/espocrm-docker-backup.sh >> $HOME/espocrm-backup.log 2>&1
#
# A lock file in the instance directory stops two backups, or a backup and a
# restore, from running against the same instance at once.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_ESPOCRM_PATH="/var/www/docker/espocrm"
RETAIN_COUNT="${ESPOCRM_BACKUP_KEEP:-7}"
# Internal: espocrm-docker-restore.sh sets this for its pre-restore snapshot.
SNAPSHOT_TYPE="${ESPOCRM_BACKUP_TYPE:-backup}"

UNATTENDED=false
[[ -n "${ESPOCRM_BACKUP_ROOT:-}" && -n "${ESPOCRM_INSTANCE_DIR:-}" ]] && UNATTENDED=true

BACKUP_DEST=""
BACKUP_DONE=false

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "Error: $*" >&2; exit 1; }

_human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# A key from a .env file, with one layer of matching quotes removed. Read
# instead of sourced, so nothing from .env leaks into this shell (Compose would
# prefer it over the file).
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
echo "=====> EspoCRM Backup"
echo "========================================"
$UNATTENDED && echo "Unattended mode ($(date -Iseconds))"

for cmd in docker gzip tar sed awk find df numfmt flock; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
[[ "$RETAIN_COUNT" =~ ^[0-9]+$ ]] || _die "ESPOCRM_BACKUP_KEEP must be a number (0 = never prune)."

# ── 1. Where to save the backup ───────────────────────────────────────────────
if [[ -n "${ESPOCRM_BACKUP_ROOT:-}" ]]; then
  BACKUP_ROOT="$ESPOCRM_BACKUP_ROOT"
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
if [[ -n "${ESPOCRM_INSTANCE_DIR:-}" ]]; then
  INSTANCE_DIR="${ESPOCRM_INSTANCE_DIR%/}"
else
  echo ""
  echo "Where are your EspoCRM instances located?"
  echo "  1) Default: $DEFAULT_ESPOCRM_PATH"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " LOCATION_CHOICE
  if [ "$LOCATION_CHOICE" = "2" ]; then
    read -rep "Enter custom EspoCRM base path: " ESPOCRM_BASE_PATH
    ESPOCRM_BASE_PATH="${ESPOCRM_BASE_PATH/#\~/$HOME}"
  else
    ESPOCRM_BASE_PATH="$DEFAULT_ESPOCRM_PATH"
  fi
  ESPOCRM_BASE_PATH="${ESPOCRM_BASE_PATH%/}"
  [ -d "$ESPOCRM_BASE_PATH" ] || _die "Directory '$ESPOCRM_BASE_PATH' not found."

  # An instance is a directory with docker-compose.yml and a .env that has
  # ESPOCRM_DOMAIN (written by espocrm-docker-install.sh).
  INSTANCES=()
  for env_f in "$ESPOCRM_BASE_PATH"/.env "$ESPOCRM_BASE_PATH"/*/.env; do
    if [ -r "$env_f" ] && grep -q '^ESPOCRM_DOMAIN=' "$env_f" && [ -f "${env_f%/.env}/docker-compose.yml" ]; then
      INSTANCES+=("${env_f%/.env}")
    fi
  done
  [ ${#INSTANCES[@]} -gt 0 ] || _die "No EspoCRM instances found in '$ESPOCRM_BASE_PATH' (or their .env is not readable by $(id -un))."

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
COMPOSE_FILE="$INSTANCE_DIR/docker-compose.yml"
[ -f "$COMPOSE_FILE" ] || _die "$COMPOSE_FILE not found."
[ -r "$ENV_FILE" ]     || _die "cannot read $ENV_FILE."
DOMAIN="$(_env_get "$ENV_FILE" ESPOCRM_DOMAIN)"
[ -n "$DOMAIN" ] || _die "no ESPOCRM_DOMAIN in $ENV_FILE - not an instance from espocrm-docker-install.sh?"

dc() { docker compose --project-directory "$INSTANCE_DIR" -f "$COMPOSE_FILE" "$@"; }

# ── 3. Lock ───────────────────────────────────────────────────────────────────
LOCK_FILE="$INSTANCE_DIR/.maintenance.lock"
exec 9>>"$LOCK_FILE" || _die "cannot open $LOCK_FILE."
flock -n 9 || _die "another backup or restore of $DOMAIN is running (lock: $LOCK_FILE)."

# ── 4. Containers ─────────────────────────────────────────────────────────────
DB_CID="$(dc ps -q espocrm-db 2>/dev/null || true)"
[ -n "$DB_CID" ] || _die "espocrm-db is not running for $DOMAIN. Start it: cd $INSTANCE_DIR && docker compose up -d"
APP_CID="$(dc ps -aq espocrm 2>/dev/null || true)"
[ -n "$APP_CID" ] || _die "the espocrm container does not exist for $DOMAIN. Start the instance: cd $INSTANCE_DIR && docker compose up -d"

APP_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$APP_CID")"
APP_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP_CID")"
DB_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$DB_CID")"

# Run a command in a throwaway container that sees the app's volumes read-only.
_helper_ro() { docker run --rm --network none --volumes-from "$APP_CID:ro" --entrypoint "$1" "$APP_IMAGE_ID" "${@:2}"; }

# The version the data was last migrated to - what a restore target has to be
# able to run. EspoCRM 10 keeps it in data/state.php (older: data/config.php).
# shellcheck disable=SC2016  # PHP code, not shell
ESPO_VERSION="$(_helper_ro php -r 'foreach (["state", "config"] as $f) { $c = @include "/var/www/html/data/$f.php"; if (is_array($c) && !empty($c["version"])) { echo $c["version"]; break; } }' 2>/dev/null || true)"
[ -n "$ESPO_VERSION" ] || _die "could not read the version from data/state.php - is this instance installed?"

# ── 5. Sizes and free space ───────────────────────────────────────────────────
DB_BYTES="$(docker exec "$DB_CID" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -N -B -e "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = '"'"'espocrm'"'"'"' | tr -d '[:space:]')"
[[ "$DB_BYTES" =~ ^[0-9]+$ ]] || _die "could not read the database size from espocrm-db (is MARIADB_ROOT_PASSWORD in .env still the root password?)."
FILES_KB="$(_helper_ro du -sk --exclude=cache --exclude=tmp /var/www/html/data /var/www/html/custom /var/www/html/client/custom | awk '{s += $1} END {print s + 0}')"

# Upper bound: compression only makes it smaller.
NEED_KB=$(( DB_BYTES / 1024 + FILES_KB + 10240 ))
AVAIL_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"

TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/espocrm/$DOMAIN"
DEST="$DOMAIN_BACKUP_DIR/$TIMESTAMP"
[ ! -e "$DEST" ] || _die "$DEST already exists."

echo ""
echo "Instance        : $DOMAIN"
echo "Install dir     : $INSTANCE_DIR"
echo "EspoCRM version : $ESPO_VERSION  ($APP_IMAGE)"
echo "MariaDB image   : $DB_IMAGE"
echo "Database        : $(_human "$DB_BYTES") on disk"
echo "Files           : $(_human $(( FILES_KB * 1024 ))) (data, custom, client/custom)"
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
BACKUP_DEST="$DEST"
mkdir -p "$DEST/database" "$DEST/files" "$DEST/config"
chmod 700 "$DEST"   # database dump, cryptKey and passwords

# ── 7. Database ───────────────────────────────────────────────────────────────
# The root password is read inside the container from its own environment and
# passed as MYSQL_PWD, never on a command line other users can see in `ps`.
echo ""
echo "=== Backing up the database ==="
docker exec "$DB_CID" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot \
    --single-transaction --quick --routines --triggers --hex-blob \
    --default-character-set=utf8mb4 espocrm' \
  | gzip > "$DEST/database/espocrm.sql.gz"
gzip -t "$DEST/database/espocrm.sql.gz"
gunzip -c "$DEST/database/espocrm.sql.gz" | tail -n 1 | grep -q '^-- Dump completed' \
  || _die "the database dump is incomplete (no '-- Dump completed' trailer)."
echo "Saved: $DEST/database/espocrm.sql.gz ($(du -h "$DEST/database/espocrm.sql.gz" | cut -f1))"

# ── 8. Files ──────────────────────────────────────────────────────────────────
# GNU tar exits 1 when a file changed while it was read (logs being written);
# that is expected on a live instance. 2 is a real error.
echo ""
echo "=== Backing up files (data, custom, client/custom) ==="
# shellcheck disable=SC2016  # $rc is the helper shell's
_helper_ro sh -c '
  cd /var/www/html
  tar --warning=no-file-changed --warning=no-file-removed \
      --exclude=data/cache --exclude=data/tmp \
      -czf - data custom client/custom
  rc=$?
  [ "$rc" -le 1 ]
' > "$DEST/files/files.tar.gz"
echo "Verifying archive..."
FILE_LIST="$(tar -tzf "$DEST/files/files.tar.gz")"
for f in data/config.php data/config-internal.php data/state.php; do
  grep -qx "$f" <<< "$FILE_LIST" || _die "$f is not in the archive."
done
echo "Saved: $DEST/files/files.tar.gz ($(du -h "$DEST/files/files.tar.gz" | cut -f1))"

# ── 9. Config ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Backing up .env and docker-compose.yml ==="
cp "$ENV_FILE" "$DEST/config/.env"
chmod 600 "$DEST/config/.env"
cp "$COMPOSE_FILE" "$DEST/config/docker-compose.yml"
echo "Saved: $DEST/config/"

# ── 10. Manifest ──────────────────────────────────────────────────────────────
{
  echo "EspoCRM backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Type            : $SNAPSHOT_TYPE"
  echo "Domain          : $DOMAIN"
  echo "Install dir     : $INSTANCE_DIR"
  echo "EspoCRM version : $ESPO_VERSION"
  echo "EspoCRM image   : $APP_IMAGE"
  echo "MariaDB image   : $DB_IMAGE"
  echo "database/       : espocrm.sql.gz (mariadb-dump of the espocrm database)"
  echo "files/          : files.tar.gz (data, custom, client/custom - without data/cache, data/tmp)"
  echo "config/         : .env (passwords - mode 600), docker-compose.yml (reference copies)"
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
