#!/bin/bash
set -euo pipefail
# =============================================================================
# Keycloak Docker Restore Script v1.1
# =============================================================================
# Restores from a snapshot created by keycloak-docker-backup.sh:
#   <backup-root>/keycloak/<domain>/<date-n-time>/postgres/keycloak.sql.gz
#   <backup-root>/keycloak/<domain>/<date-n-time>/keycloak/<realm>.json
#   <backup-root>/keycloak/<domain>/<date-n-time>/env/.env
#   <backup-root>/keycloak/<domain>/<date-n-time>/themes/themes.tar.gz
#
# Restore options:
#   1) Keycloak  — realm JSON only (config, no users/credentials)
#   2) Postgres  — full database (authoritative, all realms + users)
#   3) Environment File (.env)
#   4) Both Postgres & Environment File — .env is restored and re-sourced
#      FIRST, so the Postgres restore that follows uses the credentials that
#      were just written, not whatever was on the target beforehand.
#   5) Themes    — custom login theme files only
# Any of 1-4 can also pull the theme files along, when the snapshot has them.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_KEYCLOAK_PATH="/var/www/docker/keycloak"
COMPOSE_FILENAME="docker-compose.external-cert.yml"

echo ""
echo "=====> Keycloak Restore"
echo "========================================"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: apt install jq"
  exit 1
fi

_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

# ── 1. Choose backup base directory ─────────────────────────────────────────
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

KEYCLOAK_BACKUPS_DIR="$BACKUP_ROOT/keycloak"
[ -d "$KEYCLOAK_BACKUPS_DIR" ] || { echo "Error: '$KEYCLOAK_BACKUPS_DIR' not found."; exit 1; }

# ── 2. Select instance (domain) ─────────────────────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$KEYCLOAK_BACKUPS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)

if [ ${#DOMAIN_DIRS[@]} -eq 0 ]; then
  echo "No domain backup folders found in '$KEYCLOAK_BACKUPS_DIR'."
  exit 1
fi

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
    echo "Invalid selection."
    exit 1
  fi
  DOMAIN_DIR="${DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

# ── 3. List available snapshots ─────────────────────────────────────────────
mapfile -t SNAPSHOTS < <(find "$DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
  echo "No backup snapshots found in '$(basename "$DOMAIN_DIR")'."
  exit 1
fi

echo ""
printf "  %-4s %-33s %-10s %-12s %-6s %-7s\n" "#" "Date" "Postgres" "Realms" ".env" "Themes"
printf "  %-4s %-33s %-10s %-12s %-6s %-7s\n" "----" "---------------------------------" "----------" "------------" "------" "-------"

for i in "${!SNAPSHOTS[@]}"; do
  STAMP=$(basename "${SNAPSHOTS[$i]}")
  NICE=$(_nice_date "$STAMP")
  PG_S=$([ -f "${SNAPSHOTS[$i]}/postgres/keycloak.sql.gz" ] && echo "ok" || echo "--")
  KC_N=$(find "${SNAPSHOTS[$i]}/keycloak" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  ENV_S=$([ -f "${SNAPSHOTS[$i]}/env/.env" ] && echo "ok" || echo "--")
  TH_S=$([ -f "${SNAPSHOTS[$i]}/themes/themes.tar.gz" ] && echo "ok" || echo "--")
  printf "  %-4s %-33s %-10s %-12s %-6s %-7s\n" "$((i+1)))" "$NICE" "$PG_S" "${KC_N} realm(s)" "$ENV_S" "$TH_S"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM

if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"

HAS_PG=false
[ -f "$SNAPSHOT_DIR/postgres/keycloak.sql.gz" ] && HAS_PG=true

mapfile -t REALM_FILES < <(find "$SNAPSHOT_DIR/keycloak" -maxdepth 1 -name "*.json" 2>/dev/null | sort)
HAS_KC=false
[ ${#REALM_FILES[@]} -gt 0 ] && HAS_KC=true

HAS_ENV=false
[ -f "$SNAPSHOT_DIR/env/.env" ] && HAS_ENV=true

HAS_THEMES=false
[ -f "$SNAPSHOT_DIR/themes/themes.tar.gz" ] && HAS_THEMES=true

# ── 4. Ask what to restore ──────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "About these options:"
echo ""
echo "  Postgres is the full, authoritative backup — every realm, every user,"
echo "  password hashes, clients, roles, groups, and the realm signing keys."
echo "  Use it for real disaster recovery: instance is gone, corrupted, or you"
echo "  need to roll the whole thing back to a known-good point in time."
echo ""
echo "  Keycloak (realm JSON) is config-only — clients, roles, groups, realm"
echo "  settings — and it does NOT include users or credentials. It also"
echo "  deletes and recreates the realm it targets. Use it for narrow repairs:"
echo "  undo a bad admin change to one realm's config without touching users"
echo "  or any other realm."
echo ""
echo "  These two are never offered together: a Postgres restore already"
echo "  brings back everything the realm JSON would, plus the users it can't."
echo "  Re-importing the JSON on top of a fresh Postgres restore would delete"
echo "  the very users Postgres just restored and replace that realm with a"
echo "  users-less config-only copy — so pick whichever one actually matches"
echo "  what's broken, not both."
echo ""
echo "  Themes are the custom login theme files from the instance's ./themes"
echo "  directory, which the compose file mounts read-only. Postgres records"
echo "  which theme a realm uses but not the files, so a database restore onto"
echo "  a fresh instance needs these too or the realm points at a theme that"
echo "  isn't there. Extracting them merges over what is already on disk; it"
echo "  never deletes a theme the snapshot doesn't have."
echo ""
echo "  Environment File (.env) restores credentials/config only — no data."
echo "  It pairs with Postgres (option 4) because the Postgres restore below"
echo "  needs POSTGRES_USER/PASSWORD to connect with; when both are selected,"
echo "  .env is restored and re-sourced first so Postgres uses the values"
echo "  that were just written, not whatever was on the target before."
echo "------------------------------------------------------------"
echo ""
echo "What do you want to restore?"
echo "  1) Keycloak (realm configuration JSON)"
echo "  2) Postgres (full database)"
echo "  3) Environment File (.env)"
echo "  4) Both Postgres & Environment File (.env)"
echo "  5) Custom theme files"
read -rp "Select [1-5]: " ACTION

DO_KC=false
DO_PG=false
DO_ENV=false
DO_THEMES=false
case "$ACTION" in
  1) DO_KC=true ;;
  2) DO_PG=true ;;
  3) DO_ENV=true ;;
  4) DO_PG=true; DO_ENV=true ;;
  5) DO_THEMES=true ;;
  *) echo "Invalid selection."; exit 1 ;;
esac

# Theme files accompany any of the other options rather than replacing them.
if ! $DO_THEMES && $HAS_THEMES; then
  echo ""
  read -rp "This snapshot also has custom theme files. Restore those too? [y/N]: " ANS_THEMES
  [[ "$ANS_THEMES" =~ ^[Yy]$ ]] && DO_THEMES=true
fi

if $DO_KC && ! $HAS_KC; then
  echo "Error: this snapshot has no Keycloak realm JSON."
  exit 1
fi
if $DO_PG && ! $HAS_PG; then
  echo "Error: this snapshot has no PostgreSQL dump."
  exit 1
fi
if $DO_ENV && ! $HAS_ENV; then
  echo "Error: this snapshot has no .env backup."
  exit 1
fi
if $DO_THEMES && ! $HAS_THEMES; then
  echo "Error: this snapshot has no theme files."
  exit 1
fi

# ── 5. If restoring realm JSON, pick which realm(s) ─────────────────────────
SELECTED_REALM_FILES=()
if $DO_KC; then
  echo ""
  echo "Realms available in this snapshot:"
  for i in "${!REALM_FILES[@]}"; do
    echo "  $((i+1))) $(basename "${REALM_FILES[$i]}" .json)"
  done
  echo "  a) All realms"
  read -rp "Select realm number, or 'a' for all: " REALM_SEL

  if [[ "$REALM_SEL" =~ ^[Aa]$ ]]; then
    SELECTED_REALM_FILES=("${REALM_FILES[@]}")
  elif [[ "$REALM_SEL" =~ ^[0-9]+$ ]] && [ "$REALM_SEL" -ge 1 ] && [ "$REALM_SEL" -le "${#REALM_FILES[@]}" ]; then
    SELECTED_REALM_FILES=("${REALM_FILES[$((REALM_SEL-1))]}")
  else
    echo "Invalid selection."
    exit 1
  fi

  FILTERED=()
  for f in "${SELECTED_REALM_FILES[@]}"; do
    RNAME=$(jq -r '.realm' "$f")
    if [ "$RNAME" = "master" ]; then
      echo "Skipping 'master' — cannot be restored via realm import; use the PostgreSQL restore instead."
      continue
    fi
    FILTERED+=("$f")
  done
  SELECTED_REALM_FILES=("${FILTERED[@]}")

  if [ ${#SELECTED_REALM_FILES[@]} -eq 0 ]; then
    echo "No realms left to restore after filtering."
    exit 1
  fi
fi

# ── 6. Choose target instance to restore INTO ───────────────────────────────
echo ""
echo "Where should this be restored TO?"
echo "  1) Default: $DEFAULT_KEYCLOAK_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " TARGET_LOCATION_CHOICE

if [ "$TARGET_LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Keycloak base path: " KEYCLOAK_BASE_PATH
  KEYCLOAK_BASE_PATH="${KEYCLOAK_BASE_PATH/#\~/$HOME}"
else
  KEYCLOAK_BASE_PATH="$DEFAULT_KEYCLOAK_PATH"
fi

[ -d "$KEYCLOAK_BASE_PATH" ] || { echo "Error: '$KEYCLOAK_BASE_PATH' not found."; exit 1; }

echo ""
echo "Scanning for Keycloak instances in: $KEYCLOAK_BASE_PATH"
echo "--------------------------------------------"

mapfile -t TARGET_INSTANCES < <(find "$KEYCLOAK_BASE_PATH" -maxdepth 2 \
  -name "$COMPOSE_FILENAME" -exec dirname {} \; | sort -u)

if [ ${#TARGET_INSTANCES[@]} -eq 0 ]; then
  echo "No Keycloak instances found in '$KEYCLOAK_BASE_PATH'."
  exit 1
fi

echo "Found instances:"
for i in "${!TARGET_INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${TARGET_INSTANCES[$i]}")  (${TARGET_INSTANCES[$i]})"
done

echo ""
read -rp "Select instance number to restore INTO: " TGT_NUM

if ! [[ "$TGT_NUM" =~ ^[0-9]+$ ]] || [ "$TGT_NUM" -lt 1 ] || [ "$TGT_NUM" -gt "${#TARGET_INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

PROJECT_DIR="${TARGET_INSTANCES[$((TGT_NUM-1))]}"
COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_FILENAME"
ENV_FILE="$PROJECT_DIR/.env"

# Postgres/Keycloak restores need a target that's already configured; a pure
# or combined .env restore is allowed to provision .env for the first time.
if ! $DO_ENV && [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found."
  echo "This target has no configuration yet — restore option 3 or 4 to"
  echo "provision its .env first, or create $ENV_FILE manually."
  exit 1
fi

# Soft pre-read purely so the confirmation screen below can show a domain
# name; it gets superseded by the real (post-restore) source further down.
DISPLAY_DOMAIN="$(basename "$PROJECT_DIR")"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  DISPLAY_DOMAIN="${KEYCLOAK_URL:-$DISPLAY_DOMAIN}"
fi

# docker compose wrapper pinned to the target's file + env.
dc() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

PG_CONTAINER=""
KC_CONTAINER=""
if [ -f "$ENV_FILE" ]; then
  if $DO_PG; then
    PG_CONTAINER=$(dc ps --format "{{.Name}}" keycloak_postgres 2>/dev/null | head -n1)
    if [ -z "$PG_CONTAINER" ]; then
      echo "Error: keycloak_postgres service is not running for target $DISPLAY_DOMAIN."
      exit 1
    fi
  fi
  if $DO_KC; then
    KC_CONTAINER=$(dc ps --format "{{.Name}}" keycloak 2>/dev/null | head -n1)
    if [ -z "$KC_CONTAINER" ]; then
      echo "Error: keycloak service is not running for target $DISPLAY_DOMAIN."
      exit 1
    fi
  fi
else
  echo "Note: target has no .env yet — skipping pre-flight container checks;"
  echo "      .env will be provisioned first."
fi

# ── 7. Final confirmation ────────────────────────────────────────────────────
echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Backup snapshot : $SNAPSHOT_DIR"
echo "Target instance : $DISPLAY_DOMAIN"
echo "Compose file    : $COMPOSE_FILE"
echo "Restoring       :"
$DO_ENV && echo "  - .env (restored first)"
$DO_PG && echo "  - PostgreSQL database (full, authoritative)"
$DO_THEMES && echo "  - Custom theme files into ./themes"
if $DO_KC; then
  echo "  - Keycloak realm JSON:"
  for f in "${SELECTED_REALM_FILES[@]}"; do
    echo "      - $(basename "$f" .json)"
  done
fi
echo "============================================================"
echo ""
$DO_ENV && echo "WARNING: this OVERWRITES $ENV_FILE with the backed-up .env."
$DO_PG && echo "WARNING: this STOPS Keycloak and DROPS + REPLACES the entire 'keycloak' database on the target."
if $DO_KC; then
  echo "WARNING: the existing realm(s) listed above (if present) are DELETED and"
  echo "         replaced from JSON. The JSON snapshot does NOT include users or credentials."
fi
echo ""
read -rp "Type 'yes' to confirm and proceed: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Restore cancelled."
  exit 0
fi

# ── 8. Restore .env FIRST ────────────────────────────────────────────────────
if $DO_ENV; then
  echo ""
  echo "=== Restoring .env ==="
  cp "$SNAPSHOT_DIR/env/.env" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Restored: $ENV_FILE"
fi

# (Re)source whatever is now at ENV_FILE — either just-restored above, or the
# pre-existing file validated earlier — before anything reads KEYCLOAK_URL /
# POSTGRES_USER for the steps below. This is what makes the Postgres restore
# in option 4 use the credentials that were just written, not stale ones.
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${KEYCLOAK_URL:?KEYCLOAK_URL is not set in $ENV_FILE}"
$DO_PG && : "${POSTGRES_USER:?POSTGRES_USER is not set in $ENV_FILE}"
$DO_KC && : "${KEYCLOAK_USER:?KEYCLOAK_USER is not set in $ENV_FILE}"
$DO_KC && : "${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD is not set in $ENV_FILE}"
BASE_URL="https://${KEYCLOAK_URL}"

# ── 9. Restore PostgreSQL ────────────────────────────────────────────────────
if $DO_PG; then
  echo ""
  echo "=== Restoring PostgreSQL ==="
  echo "Stopping Keycloak..."
  dc stop keycloak

  echo "Waiting for PostgreSQL to accept connections..."
  for i in $(seq 1 30); do
    if dc exec -T keycloak_postgres pg_isready -U "$POSTGRES_USER" &>/dev/null; then
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "Error: keycloak_postgres did not become ready in time."
      exit 1
    fi
    sleep 2
  done

  echo "Dropping and recreating database..."
  dc exec -T keycloak_postgres psql -U "$POSTGRES_USER" postgres \
    -c "DROP DATABASE IF EXISTS keycloak;" \
    -c "CREATE DATABASE keycloak;"

  echo "Restoring dump..."
  gunzip -c "$SNAPSHOT_DIR/postgres/keycloak.sql.gz" \
    | dc exec -T keycloak_postgres psql -U "$POSTGRES_USER" keycloak

  echo "Starting Keycloak..."
  dc up -d keycloak
fi

# ── 10. Restore Keycloak realm JSON ─────────────────────────────────────────
if $DO_KC; then
  echo ""
  echo "=== Restoring Keycloak realm configuration ==="

  echo "Waiting for Keycloak admin API to respond..."
  TOKEN=""
  for i in $(seq 1 30); do
    TOKEN=$(curl -sf -X POST "${BASE_URL}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
      2>/dev/null | jq -r '.access_token' 2>/dev/null || true)
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
      break
    fi
    sleep 5
  done

  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "Error: failed to obtain admin token — Keycloak admin API did not become available."
    exit 1
  fi

  for f in "${SELECTED_REALM_FILES[@]}"; do
    RNAME=$(jq -r '.realm' "$f")

    echo "Restoring realm: $RNAME"
    HTTP_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/admin/realms/${RNAME}" \
      -H "Authorization: Bearer $TOKEN")
    if [ "$HTTP_CHECK" = "200" ]; then
      echo "  Deleting existing realm '$RNAME'..."
      curl -sf -X DELETE "${BASE_URL}/admin/realms/${RNAME}" -H "Authorization: Bearer $TOKEN"
    fi

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/admin/realms" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d @"$f")
    if [ "$HTTP_STATUS" = "201" ]; then
      echo "  Realm '$RNAME' restored successfully."
    else
      echo "  Import failed for '$RNAME' with HTTP status $HTTP_STATUS."
    fi
  done
fi

# ── 11. Restore custom themes ───────────────────────────────────────────────
if $DO_THEMES; then
  echo ""
  echo "=== Restoring custom themes ==="
  # The tarball holds a top-level themes/ directory, so extracting at the
  # project root puts it back exactly where the compose file mounts it.
  tar xzf "$SNAPSHOT_DIR/themes/themes.tar.gz" -C "$PROJECT_DIR"
  echo "Restored: $PROJECT_DIR/themes"
  # Keycloak caches themes in production mode, so a running container keeps
  # serving the old ones until it restarts.
  if [ -n "$(dc ps --format '{{.Name}}' keycloak 2>/dev/null | head -n1)" ]; then
    echo "Restarting Keycloak to clear the theme cache..."
    dc restart keycloak
  else
    echo "Keycloak is not running - the themes are picked up on next start."
  fi
fi

echo ""
echo "Restore complete."
echo "Instance: https://${KEYCLOAK_URL}"
