#!/bin/bash
set -euo pipefail
# =============================================================================
# Bitwarden Docker Backup Script v1.0
# =============================================================================
# Follows Bitwarden's backup guidance (temp/backup.txt): a fresh database
# backup from the mssql container plus the parts of ./bwdata that cannot be
# regenerated. One timestamped snapshot per run:
#   <backup-root>/bitwarden/<domain>/<date-n-time>/database/<vault_FULL_*.BAK>
#   <backup-root>/bitwarden/<domain>/<date-n-time>/config/config.tar.gz
#   <backup-root>/bitwarden/<domain>/<date-n-time>/attachments/attachments.tar.gz
#   <backup-root>/bitwarden/<domain>/<date-n-time>/manifest.txt
#
# config.tar.gz   bitwarden.conf, bwdata/config.yml, bwdata/env (DB password,
#                 keys - but NOT uid.env, which is host-specific),
#                 bwdata/identity (identity.pfx), bwdata/core/aspnet-dataprotection
#                 (and the rest of bwdata/core except attachments), bwdata/web,
#                 bwdata/docker, bwdata/nginx, bwdata/ca-certificates,
#                 bwdata/key-connector (if enabled)
# attachments     bwdata/core/attachments (vault attachments and Sends)
#
# Logs and the live mssql data directory are deliberately not archived: the
# .BAK is the consistent copy of the database.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_BITWARDEN_PATH="/var/www/docker/bitwarden"
RETAIN_COUNT=7

echo ""
echo "=====> Bitwarden Backup"
echo "========================================"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }

# ── 1. Ask where to save the backup ─────────────────────────────────────────
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
BACKUP_ROOT="${BACKUP_ROOT%/}"

if [ ! -d "$BACKUP_ROOT" ]; then
  read -rp "Directory '$BACKUP_ROOT' does not exist. Create it? [y/N]: " CREATE_DIR
  if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
    mkdir -p "$BACKUP_ROOT" 2>/dev/null || sudo mkdir -p "$BACKUP_ROOT"
    [ -w "$BACKUP_ROOT" ] || sudo chown "$(id -u):$(id -g)" "$BACKUP_ROOT"
    echo "Created directory: $BACKUP_ROOT"
  else
    echo "Aborting."
    exit 1
  fi
fi
[ -w "$BACKUP_ROOT" ] || { echo "Error: '$BACKUP_ROOT' is not writable by $(id -un)."; exit 1; }

# ── 2. Ask for Bitwarden instances location ─────────────────────────────────
echo ""
echo "Where are your Bitwarden instances located?"
echo "  1) Default: $DEFAULT_BITWARDEN_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Bitwarden base path: " BW_BASE_PATH
  BW_BASE_PATH="${BW_BASE_PATH/#\~/$HOME}"
else
  BW_BASE_PATH="$DEFAULT_BITWARDEN_PATH"
fi

[ -d "$BW_BASE_PATH" ] || { echo "Error: Directory '$BW_BASE_PATH' not found."; exit 1; }

# ── 3. List installed instances ─────────────────────────────────────────────
echo ""
echo "Scanning for Bitwarden instances in: $BW_BASE_PATH"
echo "--------------------------------------------"

mapfile -t INSTANCES < <(find "$BW_BASE_PATH" -maxdepth 2 -name bitwarden.conf -exec dirname {} \; | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Bitwarden instances found in '$BW_BASE_PATH'."
  exit 1
fi

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
done

if [ ${#INSTANCES[@]} -eq 1 ]; then
  INST_NUM=1
else
  echo ""
  read -rp "Select instance number: " INST_NUM
fi
if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

INSTALL_DIR="${INSTANCES[$((INST_NUM-1))]}"
BWDATA="$INSTALL_DIR/bwdata"
# shellcheck disable=SC1091
source "$INSTALL_DIR/bitwarden.conf"
DOMAIN="${DOMAIN:?DOMAIN is not set in $INSTALL_DIR/bitwarden.conf}"

ENV_FILE="$BWDATA/env/global.override.env"
[ -f "$ENV_FILE" ] || { echo "Error: $ENV_FILE not found."; exit 1; }

# The database backup is taken by the running mssql container.
if ! docker ps --format '{{.Names}}' | grep -qx bitwarden-mssql; then
  echo "Error: the bitwarden-mssql container is not running. Start Bitwarden first (./manage.sh start)."
  exit 1
fi

# DB name/user/password exactly as Bitwarden itself uses them.
CONN=$(grep '^globalSettings__sqlServer__connectionString=' "$ENV_FILE" | head -n1 | cut -d= -f2-)
SA_USER=$(sed -n 's/.*User Id=\([^;"]*\).*/\1/p' <<<"$CONN")
SA_PASSWORD=$(sed -n 's/.*Password=\([^;"]*\).*/\1/p' <<<"$CONN")
DB_NAME=$(sed -n 's/.*Initial Catalog=\([^;"]*\).*/\1/p' <<<"$CONN")
: "${SA_USER:=sa}"; : "${DB_NAME:=vault}"
[ -n "$SA_PASSWORD" ] || { echo "Error: could not read the database password from $ENV_FILE."; exit 1; }

# ── 4. Confirm ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DEST="$BACKUP_ROOT/bitwarden/$DOMAIN/$TIMESTAMP"

echo ""
echo "Instance        : $DOMAIN"
echo "Install dir     : $INSTALL_DIR"
echo "Database        : $DB_NAME (container bitwarden-mssql)"
echo "Backup folder   : $BACKUP_DEST"
echo ""
read -rp "Proceed with backup? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# On any failure below, remove the half-written backup so a partial snapshot
# is never mistaken for a good one later during a restore.
MARKER=""
cleanup_on_error() {
  local code=$?
  echo ""
  echo "Backup failed (exit $code) - removing incomplete $BACKUP_DEST"
  rm -rf "$BACKUP_DEST"
  [ -z "$MARKER" ] || rm -f "$MARKER"
  exit "$code"
}
trap cleanup_on_error ERR

mkdir -p "$BACKUP_DEST/database" "$BACKUP_DEST/config" "$BACKUP_DEST/attachments"
chmod 700 "$BACKUP_DEST"   # contains DB dump, keys and secrets

# ── 5. Database (fresh backup from the mssql container) ─────────────────────
echo ""
echo "=== Backing up the database ==="
MARKER=$(mktemp)
sleep 1   # backup file mtimes must be strictly newer than the marker
docker exec -i bitwarden-mssql /backup-db.sh

BAK_SRC=$(find "$BWDATA/mssql/backups" -maxdepth 1 -type f -name '*.BAK' -newer "$MARKER" | sort | tail -n1)
rm -f "$MARKER"; MARKER=""
[ -n "$BAK_SRC" ] || { echo "Error: /backup-db.sh produced no new .BAK in $BWDATA/mssql/backups"; exit 1; }
[ -s "$BAK_SRC" ] || { echo "Error: $BAK_SRC is empty."; exit 1; }

echo "Verifying $(basename "$BAK_SRC")..."
docker exec -e SQLCMDPASSWORD="$SA_PASSWORD" bitwarden-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U "$SA_USER" -C -b \
  -Q "RESTORE VERIFYONLY FROM DISK = N'/etc/bitwarden/mssql/backups/$(basename "$BAK_SRC")'" >/dev/null

cp "$BAK_SRC" "$BACKUP_DEST/database/"
chmod 600 "$BACKUP_DEST/database/"*
BAK_NAME=$(basename "$BAK_SRC")
echo "Saved: $BACKUP_DEST/database/$BAK_NAME"

# ── 6. Configuration, keys and certificates ─────────────────────────────────
echo ""
echo "=== Backing up configuration, keys and certificates ==="
CONFIG_PATHS=(bitwarden.conf bwdata/config.yml bwdata/env bwdata/identity bwdata/core \
  bwdata/web bwdata/docker bwdata/nginx bwdata/ca-certificates bwdata/key-connector)
EXISTING=()
for p in "${CONFIG_PATHS[@]}"; do [ -e "$INSTALL_DIR/$p" ] && EXISTING+=("$p"); done
tar czf "$BACKUP_DEST/config/config.tar.gz" -C "$INSTALL_DIR" \
  --exclude='bwdata/env/uid.env' --exclude='bwdata/core/attachments' "${EXISTING[@]}"
chmod 600 "$BACKUP_DEST/config/config.tar.gz"
echo "Saved: $BACKUP_DEST/config/config.tar.gz"

# ── 7. Attachments ──────────────────────────────────────────────────────────
HAS_ATT=no
if [ -d "$BWDATA/core/attachments" ] && [ -n "$(ls -A "$BWDATA/core/attachments" 2>/dev/null)" ]; then
  echo ""
  echo "=== Backing up attachments ==="
  tar czf "$BACKUP_DEST/attachments/attachments.tar.gz" -C "$INSTALL_DIR" bwdata/core/attachments
  chmod 600 "$BACKUP_DEST/attachments/attachments.tar.gz"
  HAS_ATT=yes
  echo "Saved: $BACKUP_DEST/attachments/attachments.tar.gz"
else
  rmdir "$BACKUP_DEST/attachments"
  echo ""
  echo "=== No attachments to back up ==="
fi

# ── 8. Manifest ─────────────────────────────────────────────────────────────
{
  echo "Bitwarden backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Domain          : $DOMAIN"
  echo "Source dir      : $INSTALL_DIR"
  echo "Core version    : ${CORE_VERSION:-unknown}"
  echo "Web version     : ${WEB_VERSION:-unknown}"
  echo "Database name   : $DB_NAME"
  echo "database/       : $BAK_NAME (full backup, verified with RESTORE VERIFYONLY)"
  echo "config/         : config.tar.gz (secrets, identity cert, data-protection keys - mode 600)"
  echo "attachments/    : ${HAS_ATT} (attachments.tar.gz)"
  echo "Note            : database and attachments are captured while Bitwarden runs;"
  echo "                  a file uploaded during the backup may be in one but not the other."
} > "$BACKUP_DEST/manifest.txt"

# ── 9. Prune old snapshots for this domain ──────────────────────────────────
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/bitwarden/$DOMAIN"
mapfile -t OLD_SNAPSHOTS < <(find "$DOMAIN_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r | tail -n +$((RETAIN_COUNT+1)))
if [ ${#OLD_SNAPSHOTS[@]} -gt 0 ]; then
  echo ""
  echo "Pruning old snapshots (keeping last $RETAIN_COUNT)..."
  for OLD in "${OLD_SNAPSHOTS[@]}"; do
    echo "  Removing: $OLD"
    rm -rf "$OLD"
  done
fi

trap - ERR
echo ""
echo "Backup complete: $BACKUP_DEST"
echo ""
cat "$BACKUP_DEST/manifest.txt"
