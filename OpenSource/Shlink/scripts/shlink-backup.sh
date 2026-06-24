#!/bin/bash
# ============================================================
# Shlink MariaDB Backup Script v1.0
# ============================================================

set -euo pipefail

DEFAULT_SHLINK_PATH="/var/www/docker/shlink"

# ── 1. Ask where to save the backup ─────────────────────────
echo ""
echo "=====> Shlink Backup"
echo "========================================"
echo "Choose the directory where you want to save the backup:"
echo "  1) Default: /home/backup"
echo "  2) Custom path"
read -rp "Select [1/2]: " BACKUP_CHOICE

if [ "$BACKUP_CHOICE" = "2" ]; then
  read -rep "Enter custom backup directory: " BACKUP_PARENT
  BACKUP_PARENT="${BACKUP_PARENT/#\~/$HOME}"
else
  BACKUP_PARENT="/home/backup"
fi

if [ ! -d "$BACKUP_PARENT" ]; then
  read -rp "Directory '$BACKUP_PARENT' does not exist. Create it? [y/N]: " CREATE_DIR
  if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
    mkdir -p "$BACKUP_PARENT"
    echo "Created directory: $BACKUP_PARENT"
  else
    echo "Aborting."
    exit 1
  fi
fi

# ── 2. Ask for Shlink instances location ─────────────────────
echo ""
echo "Where are your Shlink instances located?"
echo "  1) Default: $DEFAULT_SHLINK_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Shlink base path: " SHLINK_BASE
  SHLINK_BASE="${SHLINK_BASE/#\~/$HOME}"
else
  SHLINK_BASE="$DEFAULT_SHLINK_PATH"
fi

if [ ! -d "$SHLINK_BASE" ]; then
  echo "Error: Directory '$SHLINK_BASE' not found."
  exit 1
fi

# ── 3. Find Shlink instances ─────────────────────────────────
echo ""
echo "Scanning for Shlink instances in: $SHLINK_BASE"
echo "--------------------------------------------"

mapfile -t INSTANCES < <(find "$SHLINK_BASE" -maxdepth 2 \
  -name "docker-compose.yaml" \
  -exec dirname {} \; | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Shlink instances found in '$SHLINK_BASE'."
  exit 1
fi

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  INST_NAME=$(basename "${INSTANCES[$i]}")
  echo "  $((i+1))) $INST_NAME  (${INSTANCES[$i]})"
done

echo ""
read -rp "Select instance number: " INST_NUM

if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED_PATH="${INSTANCES[$((INST_NUM-1))]}"
INSTANCE_NAME=$(basename "$SELECTED_PATH")
COMPOSE_FILE="$SELECTED_PATH/docker-compose.yaml"

echo "Selected: $INSTANCE_NAME"

DATE_STAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DIR="${BACKUP_PARENT}/shlink-${INSTANCE_NAME}/${DATE_STAMP}"
mkdir -p "$BACKUP_DIR"
echo "Backup folder: $BACKUP_DIR"

# ── 4. Parse ALL variables from compose file ─────────────────
echo ""
echo "Reading configuration from $COMPOSE_FILE..."

[ -f "$COMPOSE_FILE" ] || { echo "Error: $COMPOSE_FILE not found."; exit 1; }

# Helper: extract value after KEY= from compose, strip leading whitespace
_parse() { grep -m1 "${1}=" "$COMPOSE_FILE" | sed "s/.*${1}=//" | tr -d ' \r'; }

BACKEND_DOMAIN=$(_parse 'DEFAULT_DOMAIN')
CORS_RAW=$(_parse 'CORS_ALLOW_ORIGIN')
FRONTEND_DOMAIN="${CORS_RAW#https://}"   # strip https:// prefix
TZ_VAL=$(_parse 'TZ')
GEOLITE_KEY=$(_parse 'GEOLITE_LICENSE_KEY')
DB_NAME=$(_parse 'DB_NAME')
DB_USER=$(_parse 'DB_USER')
DB_PASSWORD=$(_parse 'DB_PASSWORD')
DB_ROOT_PASSWORD=$(_parse 'MARIADB_ROOT_PASSWORD')
SERVER_NAME=$(_parse 'SHLINK_SERVER_NAME')
API_KEY=$(_parse 'SHLINK_SERVER_API_KEY')

# Ports: two lines match "- XXXX:8080"; first = backend, second = frontend
PORT_LINES=$(grep -E '^\s+-\s+[0-9]+:8080\s*$' "$COMPOSE_FILE" || true)
BACKEND_PORT=$(echo "$PORT_LINES" | head -1 | grep -oP '[0-9]+(?=:8080)' || true)
FRONTEND_PORT=$(echo "$PORT_LINES" | tail -1 | grep -oP '[0-9]+(?=:8080)' || true)

# Fall back to defaults for anything that couldn't be parsed
[ -z "$DB_NAME" ]       && { echo "Warning: DB_NAME not found, defaulting to 'shlink'."; DB_NAME="shlink"; }
[ -z "$BACKEND_PORT" ]  && { echo "Warning: backend port not found, defaulting to 8282."; BACKEND_PORT="8282"; }
[ -z "$FRONTEND_PORT" ] && { echo "Warning: frontend port not found, defaulting to 8280."; FRONTEND_PORT="8280"; }

echo ""
echo "  Backend domain  : ${BACKEND_DOMAIN:-(not found)}"
echo "  Frontend domain : ${FRONTEND_DOMAIN:-(not found)}"
echo "  Backend port    : ${BACKEND_PORT}"
echo "  Frontend port   : ${FRONTEND_PORT}"
echo "  Timezone        : ${TZ_VAL:-(not found)}"
echo "  GeoLite key     : ${GEOLITE_KEY:-(empty)}"
echo "  DB name/user    : ${DB_NAME} / ${DB_USER:-(not found)}"
echo "  Server name     : ${SERVER_NAME:-(not found)}"
echo "  API key         : ${API_KEY:-(not found)}"
echo "  Root password   : ${DB_ROOT_PASSWORD:+(parsed from compose)}"
[ -z "$DB_ROOT_PASSWORD" ] && echo "  Root password   : (not in compose — will ask)"

# ── 5. Root password: use parsed value or ask ────────────────
if [ -z "$DB_ROOT_PASSWORD" ]; then
  echo ""
  read -rsp "Enter MariaDB root password: " DB_ROOT_PASSWORD
  echo
fi

# ── 6. Verify container is running ───────────────────────────
echo ""
echo "Checking shlink-database container..."
if ! docker ps --format "{{.Names}}" | grep -q "^shlink-database$"; then
  echo "Error: Container 'shlink-database' is not running."
  echo "       Start it with: cd $SELECTED_PATH && docker compose up -d database"
  exit 1
fi

if ! docker exec shlink-database mysqladmin ping \
     -u root -p"${DB_ROOT_PASSWORD}" --silent 2>/dev/null; then
  echo "Error: Could not connect to MariaDB. Root password may be incorrect."
  exit 1
fi
echo "  Connection OK."

# ── 7. Dump the database ─────────────────────────────────────
SQL_FILE="${BACKUP_DIR}/shlink_backup_${DATE_STAMP}.sql"

echo ""
echo "Starting backup..."
echo "  Instance  : $INSTANCE_NAME"
echo "  Database  : $DB_NAME"
echo "  Container : shlink-database"
echo "  Output    : $SQL_FILE"
echo ""

docker exec shlink-database \
  sh -c "exec mysqldump -u root -p\"${DB_ROOT_PASSWORD}\" ${DB_NAME}" \
  > "$SQL_FILE"

SQL_SIZE=$(du -sh "$SQL_FILE" | cut -f1)

# ── 8. Save full config snapshot ─────────────────────────────
CONFIG_FILE="${BACKUP_DIR}/shlink-${INSTANCE_NAME}_${DATE_STAMP}.txt"

cat > "$CONFIG_FILE" << EOF
# ============================================================
# Shlink backup configuration
# Instance  : ${INSTANCE_NAME}
# Date      : ${DATE_STAMP}
# SQL file  : $(basename "$SQL_FILE")
# ============================================================

backend_domain="${BACKEND_DOMAIN}"
frontend_domain="${FRONTEND_DOMAIN}"
backend_port="${BACKEND_PORT}"
frontend_port="${FRONTEND_PORT}"
tz="${TZ_VAL}"
geolite_key="${GEOLITE_KEY}"
db_name="${DB_NAME}"
db_user="${DB_USER}"
db_password="${DB_PASSWORD}"
db_root_password="${DB_ROOT_PASSWORD}"
server_name="${SERVER_NAME}"
api_key="${API_KEY}"
EOF

# ── 9. Summary ───────────────────────────────────────────────
echo ""
echo "=====> Backup complete!"
echo "   Folder : $BACKUP_DIR"
echo "   SQL    : $(basename "$SQL_FILE")  [$SQL_SIZE]"
echo "   Config : $(basename "$CONFIG_FILE")"
