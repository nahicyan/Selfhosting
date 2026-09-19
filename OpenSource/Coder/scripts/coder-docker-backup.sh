#!/bin/bash
set -euo pipefail
# =============================================================================
# Coder Docker Backup Script v1.0
# =============================================================================
# Backs up an instance installed by coder-docker-install.sh into one timestamped
# snapshot:
#   <backup-root>/coder/<domain>/<date-n-time>/postgres/coder.sql.gz
#   <backup-root>/coder/<domain>/<date-n-time>/config/.env
#   <backup-root>/coder/<domain>/<date-n-time>/config/compose.yaml
#   <backup-root>/coder/<domain>/<date-n-time>/manifest.txt
#
# postgres/   A plain-SQL pg_dump of the Coder database - the method Coder's own
#             docs use (docs/admin/setup: "pg_dump <connection-string> > coder.sql").
#             Users, templates, template files, workspaces and their Terraform
#             state, API keys, external-auth links and deployment settings all
#             live here, so this is the backup. It is taken from the running
#             database (pg_dump reads a consistent snapshot), so Coder stays up.
# config/     .env holds the PostgreSQL password, SMTP login and, if you turned
#             on database encryption, CODER_EXTERNAL_TOKEN_ENCRYPTION_KEYS -
#             without those keys an encrypted database will not start.
#             compose.yaml is saved as well because the installer patches it
#             (loopback port, docker gid, extra environment keys) and any
#             setting you added by hand lives there.
#
# Not archived: the coder_home volume (/home/coder). compose.yaml notes it is
# not needed in production - Coder recreates what it needs on restart.
# Nginx and TLS certificates are also left out; the installer regenerates the
# vhost and certbot re-issues the certificate.
#
# Coder does not support downgrades, so take a backup before every upgrade:
#   https://coder.com/docs/install/upgrade
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_CODER_PATH="/var/www/docker/coder"
COMPOSE_FILENAME="compose.yaml"
RETAIN_COUNT=7

echo ""
echo "=====> Coder Backup"
echo "========================================"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Error: the Docker Compose plugin ('docker compose') is required."; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "Error: gzip is required."; exit 1; }

# _env_get <file> <key> - last KEY=value in a dotenv file, surrounding quotes removed.
_env_get() {
  local v
  v="$(grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  v="${v#[\'\"]}"; v="${v%[\'\"]}"
  printf '%s' "$v"
}

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

# ── 2. Ask for Coder instances location ─────────────────────────────────────
echo ""
echo "Where are your Coder instances located?"
echo "  1) Default: $DEFAULT_CODER_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Coder base path: " CODER_BASE_PATH
  CODER_BASE_PATH="${CODER_BASE_PATH/#\~/$HOME}"
else
  CODER_BASE_PATH="$DEFAULT_CODER_PATH"
fi

[ -d "$CODER_BASE_PATH" ] || { echo "Error: Directory '$CODER_BASE_PATH' not found."; exit 1; }

# ── 3. List installed instances ─────────────────────────────────────────────
echo ""
echo "Scanning for Coder instances in: $CODER_BASE_PATH"
echo "--------------------------------------------"

# An instance is a directory holding Coder's compose.yaml next to its .env.
INSTANCES=()
while IFS= read -r f; do
  if [ -f "$(dirname "$f")/.env" ] && grep -q 'ghcr.io/coder/coder' "$f"; then
    INSTANCES+=("$(dirname "$f")")
  fi
done < <(find "$CODER_BASE_PATH" -maxdepth 2 -name "$COMPOSE_FILENAME" | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Coder instances found in '$CODER_BASE_PATH'."
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

PROJECT_DIR="${INSTANCES[$((INST_NUM-1))]}"
COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_FILENAME"
ENV_FILE="$PROJECT_DIR/.env"

ACCESS_URL="$(_env_get "$ENV_FILE" CODER_ACCESS_URL)"
DOMAIN="${ACCESS_URL#*://}"; DOMAIN="${DOMAIN%%/*}"
[ -n "$DOMAIN" ] || { echo "Error: CODER_ACCESS_URL is not set in $ENV_FILE."; exit 1; }

# Everything below runs from the instance directory, exactly like the commands
# the installer prints, so Compose reads this instance's compose.yaml and .env.
cd "$PROJECT_DIR"

# ── 4. Verify the database is running ───────────────────────────────────────
if [ -z "$(docker compose ps -q database 2>/dev/null)" ]; then
  echo "Error: the 'database' service is not running for $DOMAIN."
  echo "Start it first: (cd \"$PROJECT_DIR\" && docker compose up -d)"
  exit 1
fi

# ── 5. Confirm ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DEST="$BACKUP_ROOT/coder/$DOMAIN/$TIMESTAMP"

echo ""
echo "Instance        : $DOMAIN"
echo "Install dir     : $PROJECT_DIR"
echo "Backup folder   : $BACKUP_DEST"
echo ""
read -rp "Proceed with backup? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# On any failure below, remove the half-written backup so a partial snapshot
# is never mistaken for a good one later during a restore.
cleanup_on_error() {
  local code=$?
  echo ""
  echo "Backup failed (exit $code) - removing incomplete $BACKUP_DEST"
  rm -rf "$BACKUP_DEST"
  exit "$code"
}
trap cleanup_on_error ERR

mkdir -p "$BACKUP_DEST/postgres" "$BACKUP_DEST/config"
chmod 700 "$BACKUP_DEST"   # contains the database dump and .env secrets

# ── 6. PostgreSQL dump ──────────────────────────────────────────────────────
# Run inside the database container: its pg_dump always matches the server, and
# it reads the credentials the container was created with. --no-owner and
# --no-privileges keep the dump loadable whatever the role is called.
echo ""
echo "=== Backing up the PostgreSQL database ==="
DUMP="$BACKUP_DEST/postgres/coder.sql.gz"
docker compose exec -T database \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' </dev/null \
  | gzip > "$DUMP"
chmod 600 "$DUMP"

# pg_dump ends every complete dump with this line, so it also catches truncation.
echo "Verifying the dump..."
if ! gunzip -c "$DUMP" | tail -n 20 | grep -q 'PostgreSQL database dump complete'; then
  echo "Error: $DUMP is incomplete or corrupt."
  exit 1
fi
echo "Saved: $DUMP ($(du -h "$DUMP" | cut -f1))"

# ── 7. Configuration ────────────────────────────────────────────────────────
echo ""
echo "=== Backing up configuration ==="
cp "$ENV_FILE" "$BACKUP_DEST/config/.env"
cp "$COMPOSE_FILE" "$BACKUP_DEST/config/compose.yaml"
chmod 600 "$BACKUP_DEST/config/.env" "$BACKUP_DEST/config/compose.yaml"
echo "Saved: $BACKUP_DEST/config/{.env,compose.yaml}"

# ── 8. Manifest ─────────────────────────────────────────────────────────────
# Best-effort details; none of them can fail the backup. exec would otherwise
# attach this script's stdin, hence </dev/null.
CODER_VERSION_LINE="$(docker compose exec -T coder /opt/coder version </dev/null 2>/dev/null | head -n1 | tr -d '\r' || true)"
PG_VERSION_LINE="$(docker compose exec -T database sh -c 'postgres --version' </dev/null 2>/dev/null | tr -d '\r' || true)"
SCHEMA_LEVEL="$(docker compose exec -T database sh -c 'psql -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT max(version) FROM schema_migrations"' </dev/null 2>/dev/null | tr -d '\r' || true)"
DBCRYPT="no"
if grep -qs 'CODER_EXTERNAL_TOKEN_ENCRYPTION_KEYS' "$ENV_FILE" "$COMPOSE_FILE"; then DBCRYPT="yes"; fi

{
  echo "Coder backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Domain          : $DOMAIN"
  echo "Source dir      : $PROJECT_DIR"
  echo "Coder version   : ${CODER_VERSION_LINE:-unknown}"
  echo "Image tag       : $(_env_get "$ENV_FILE" CODER_VERSION)"
  echo "PostgreSQL      : ${PG_VERSION_LINE:-unknown}"
  echo "Schema level    : ${SCHEMA_LEVEL:-unknown}"
  echo "DB encryption   : $DBCRYPT"
  echo "postgres/       : coder.sql.gz (full database, verified complete)"
  echo "config/         : .env and compose.yaml (secrets - mode 600)"
  echo "Note            : Coder cannot run against a database from a newer release than"
  echo "                  itself; restore onto the same version or newer."
  if [ "$DBCRYPT" = "yes" ]; then
    echo "Note            : database encryption is on - the keys are in config/. Without them"
    echo "                  the restored database will not start. Keep this snapshot secret."
  fi
} > "$BACKUP_DEST/manifest.txt"

# ── 9. Prune old snapshots for this domain ──────────────────────────────────
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/coder/$DOMAIN"
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
