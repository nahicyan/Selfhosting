#!/bin/bash
set -euo pipefail
# =============================================================================
# Keycloak Docker Backup Script v1.1
# =============================================================================
# Backs up the PostgreSQL database (authoritative, full-fidelity), a per-realm
# Keycloak JSON export (config-only, human-readable), and the instance's .env
# into a single timestamped snapshot:
#   <backup-root>/keycloak/<domain>/<date-n-time>/postgres/keycloak.sql.gz
#   <backup-root>/keycloak/<domain>/<date-n-time>/keycloak/<realm>.json
#   <backup-root>/keycloak/<domain>/<date-n-time>/env/.env
#   <backup-root>/keycloak/<domain>/<date-n-time>/themes/themes.tar.gz
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_KEYCLOAK_PATH="/var/www/docker/keycloak"
COMPOSE_FILENAME="docker-compose.external-cert.yml"
RETAIN_COUNT=7

echo ""
echo "=====> Keycloak Backup"
echo "========================================"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: apt install jq"
  exit 1
fi

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
    mkdir -p "$BACKUP_ROOT"
    echo "Created directory: $BACKUP_ROOT"
  else
    echo "Aborting."
    exit 1
  fi
fi

# ── 2. Ask for Keycloak instances location ──────────────────────────────────
echo ""
echo "Where are your Keycloak instances located?"
echo "  1) Default: $DEFAULT_KEYCLOAK_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Keycloak base path: " KEYCLOAK_BASE_PATH
  KEYCLOAK_BASE_PATH="${KEYCLOAK_BASE_PATH/#\~/$HOME}"
else
  KEYCLOAK_BASE_PATH="$DEFAULT_KEYCLOAK_PATH"
fi

if [ ! -d "$KEYCLOAK_BASE_PATH" ]; then
  echo "Error: Directory '$KEYCLOAK_BASE_PATH' not found."
  exit 1
fi

# ── 3. List installed instances ─────────────────────────────────────────────
echo ""
echo "Scanning for Keycloak instances in: $KEYCLOAK_BASE_PATH"
echo "--------------------------------------------"

mapfile -t INSTANCES < <(find "$KEYCLOAK_BASE_PATH" -maxdepth 2 \
  -name "$COMPOSE_FILENAME" -exec dirname {} \; | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Keycloak instances found in '$KEYCLOAK_BASE_PATH'."
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

PROJECT_DIR="${INSTANCES[$((INST_NUM-1))]}"
COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_FILENAME"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found."
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${KEYCLOAK_USER:?KEYCLOAK_USER is not set in $ENV_FILE}"
: "${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD is not set in $ENV_FILE}"
: "${KEYCLOAK_URL:?KEYCLOAK_URL is not set in $ENV_FILE}"
: "${POSTGRES_USER:?POSTGRES_USER is not set in $ENV_FILE}"

DOMAIN="$KEYCLOAK_URL"

# docker compose wrapper pinned to this instance's file + env, so compose
# variable interpolation always reads the .env we just sourced above, not
# whatever it would otherwise auto-discover.
dc() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

# ── 4. Verify both services are running ─────────────────────────────────────
PG_CONTAINER=$(dc ps --format "{{.Name}}" keycloak_postgres 2>/dev/null | head -n1)
KC_CONTAINER=$(dc ps --format "{{.Name}}" keycloak 2>/dev/null | head -n1)

if [ -z "$PG_CONTAINER" ]; then
  echo "Error: keycloak_postgres service is not running for $DOMAIN."
  exit 1
fi
if [ -z "$KC_CONTAINER" ]; then
  echo "Error: keycloak service is not running for $DOMAIN."
  exit 1
fi

# ── 5. Confirm ───────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DEST="$BACKUP_ROOT/keycloak/$DOMAIN/$TIMESTAMP"

echo ""
echo "Instance        : $DOMAIN"
echo "Compose file    : $COMPOSE_FILE"
echo "Postgres cntr   : $PG_CONTAINER"
echo "Keycloak cntr   : $KC_CONTAINER"
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
  echo "Backup failed (exit $code) — removing incomplete $BACKUP_DEST"
  rm -rf "$BACKUP_DEST"
  exit "$code"
}
trap cleanup_on_error ERR

mkdir -p "$BACKUP_DEST/postgres" "$BACKUP_DEST/keycloak" "$BACKUP_DEST/env"
chmod 700 "$BACKUP_DEST"   # contains DB dump, realm config, and .env secrets

# ── 6. PostgreSQL dump (authoritative, full-fidelity) ───────────────────────
echo ""
echo "=== Backing up PostgreSQL database ==="
PG_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$(dc ps -q keycloak_postgres)")

dc exec -T keycloak_postgres \
  pg_dump -U "$POSTGRES_USER" --no-owner --no-privileges keycloak \
  | gzip > "$BACKUP_DEST/postgres/keycloak.sql.gz"

echo "Saved: $BACKUP_DEST/postgres/keycloak.sql.gz"

# ── 7. Keycloak realm export (config-only, human-readable) ─────────────────
echo ""
echo "=== Backing up Keycloak realm configuration ==="
KC_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$(dc ps -q keycloak)")
BASE_URL="https://${KEYCLOAK_URL}"

TOKEN=$(curl -sf -X POST "${BASE_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
  2>/dev/null | jq -r '.access_token' 2>/dev/null || true)

REALM_LIST=""
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
  REALMS=$(curl -sf "${BASE_URL}/admin/realms" -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.[].realm' 2>/dev/null || true)
  for REALM in $REALMS; do
    echo "Exporting realm: $REALM"
    if curl -sf -X POST "${BASE_URL}/admin/realms/${REALM}/partial-export?exportClients=true&exportGroupsAndRoles=true" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq . > "$BACKUP_DEST/keycloak/${REALM}.json" 2>/dev/null; then
      REALM_LIST="${REALM_LIST}${REALM} "
    else
      echo "  Warning: export failed for realm '$REALM' — skipping it (other realms and the Postgres dump are unaffected)."
      rm -f "$BACKUP_DEST/keycloak/${REALM}.json"
    fi
  done
  echo "Saved: $BACKUP_DEST/keycloak/*.json"
else
  echo "Warning: could not obtain admin token — skipping realm JSON export."
  echo "         (Postgres dump above is unaffected and remains complete.)"
fi

# ── 8. Backup .env ───────────────────────────────────────────────────────────
echo ""
echo "=== Backing up .env ==="
cp "$ENV_FILE" "$BACKUP_DEST/env/.env"
chmod 600 "$BACKUP_DEST/env/.env"
echo "Saved: $BACKUP_DEST/env/.env"

# ── 8b. Custom themes ────────────────────────────────────────────────────────
# The compose file mounts ./themes read-only into the container. Postgres
# records which theme a realm uses; the files themselves live only here, so a
# restore without them leaves realms pointing at a theme that no longer exists.
THEMES_DIR="$PROJECT_DIR/themes"
THEME_LIST=""
if [ -d "$THEMES_DIR" ] && [ -n "$(ls -A "$THEMES_DIR" 2>/dev/null)" ]; then
  echo ""
  echo "=== Backing up custom themes ==="
  mkdir -p "$BACKUP_DEST/themes"
  tar czf "$BACKUP_DEST/themes/themes.tar.gz" -C "$PROJECT_DIR" themes
  THEME_LIST=$(find "$THEMES_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null || true)
  echo "Saved: $BACKUP_DEST/themes/themes.tar.gz  (${THEME_LIST:-no theme directories})"
else
  echo ""
  echo "=== No custom themes to back up ==="
fi

# ── 9. Manifest ──────────────────────────────────────────────────────────────
{
  echo "Keycloak backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Domain          : $DOMAIN"
  echo "Source compose  : $COMPOSE_FILE"
  echo "Keycloak image  : $KC_IMAGE"
  echo "Postgres image  : $PG_IMAGE"
  echo "Realms exported : ${REALM_LIST:-none}"
  echo "Themes saved    : ${THEME_LIST:-none}"
  echo "postgres/       : keycloak.sql.gz (full database — authoritative)"
  echo "keycloak/       : one JSON file per realm (config only, no users/credentials)"
  echo "env/            : .env (contains secrets — mode 600)"
  echo "themes/         : themes.tar.gz (custom login themes, if any)"
} > "$BACKUP_DEST/manifest.txt"

# ── 10. Prune old snapshots for this domain ─────────────────────────────────
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/keycloak/$DOMAIN"
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
