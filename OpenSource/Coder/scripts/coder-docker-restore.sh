#!/bin/bash
set -euo pipefail
# =============================================================================
# Coder Docker Restore Script v1.0
# =============================================================================
# Restores from a snapshot created by coder-docker-backup.sh:
#   <backup-root>/coder/<domain>/<date-n-time>/postgres/coder.sql.gz
#   <backup-root>/coder/<domain>/<date-n-time>/config/.env
#   <backup-root>/coder/<domain>/<date-n-time>/config/compose.yaml
#
# Restore options:
#   1) Full recovery - configuration + database (new server, or rolling the
#                      whole instance back)
#   2) Database only - the Coder database, e.g. after a bad upgrade or a bad
#                      admin change
#   3) Configuration - .env and compose.yaml only
#
# The database is restored the way Coder's docs describe (docs/admin/setup):
# the dump is loaded with psql into an empty database, while Coder is stopped.
#
# To recover onto a NEW server: run coder-docker-install.sh first (so the
# instance directory, images and host Nginx exist) with the SAME domain, then
# choose "Full recovery" here.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_CODER_PATH="/var/www/docker/coder"
COMPOSE_FILENAME="compose.yaml"

echo ""
echo "=====> Coder Restore"
echo "========================================"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Error: the Docker Compose plugin ('docker compose') is required."; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "Error: gzip is required."; exit 1; }

_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

# _env_get <file> <key> - last KEY=value in a dotenv file, surrounding quotes removed.
_env_get() {
  local v
  v="$(grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  v="${v#[\'\"]}"; v="${v%[\'\"]}"
  printf '%s' "$v"
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

CODER_BACKUPS_DIR="$BACKUP_ROOT/coder"
[ -d "$CODER_BACKUPS_DIR" ] || { echo "Error: '$CODER_BACKUPS_DIR' not found."; exit 1; }

# ── 2. Select backup domain ─────────────────────────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$CODER_BACKUPS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || { echo "No domain backup folders found in '$CODER_BACKUPS_DIR'."; exit 1; }

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
[ ${#SNAPSHOTS[@]} -gt 0 ] || { echo "No backup snapshots found in '$(basename "$DOMAIN_DIR")'."; exit 1; }

echo ""
printf "  %-4s %-33s %-10s %-8s\n" "#" "Date" "Database" "Config"
printf "  %-4s %-33s %-10s %-8s\n" "----" "---------------------------------" "----------" "--------"
for i in "${!SNAPSHOTS[@]}"; do
  S="${SNAPSHOTS[$i]}"
  DB_S=$([ -f "$S/postgres/coder.sql.gz" ] && du -h "$S/postgres/coder.sql.gz" | cut -f1 || echo "--")
  CF_S=$([ -f "$S/config/.env" ] && [ -f "$S/config/compose.yaml" ] && echo "ok" || echo "--")
  printf "  %-4s %-33s %-10s %-8s\n" "$((i+1)))" "$(_nice_date "$(basename "$S")")" "$DB_S" "$CF_S"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM
if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi
SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"
SNAP_DUMP="$SNAPSHOT_DIR/postgres/coder.sql.gz"

HAS_DB=false;  [ -f "$SNAP_DUMP" ] && HAS_DB=true
HAS_CFG=false; [ -f "$SNAPSHOT_DIR/config/.env" ] && [ -f "$SNAPSHOT_DIR/config/compose.yaml" ] && HAS_CFG=true

# ── 4. Select the target instance ───────────────────────────────────────────
echo ""
read -rep "Coder instances base path [$DEFAULT_CODER_PATH]: " CODER_BASE_PATH
CODER_BASE_PATH="${CODER_BASE_PATH:-$DEFAULT_CODER_PATH}"
CODER_BASE_PATH="${CODER_BASE_PATH/#\~/$HOME}"
[ -d "$CODER_BASE_PATH" ] || { echo "Error: Directory '$CODER_BASE_PATH' not found."; exit 1; }

INSTANCES=()
while IFS= read -r f; do
  if [ -f "$(dirname "$f")/.env" ] && grep -q 'ghcr.io/coder/coder' "$f"; then
    INSTANCES+=("$(dirname "$f")")
  fi
done < <(find "$CODER_BASE_PATH" -maxdepth 2 -name "$COMPOSE_FILENAME" | sort -u)
[ ${#INSTANCES[@]} -gt 0 ] || { echo "No Coder instances found in '$CODER_BASE_PATH'. Run coder-docker-install.sh first."; exit 1; }

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
done
if [ ${#INSTANCES[@]} -eq 1 ]; then
  INST_NUM=1
else
  echo ""
  read -rp "Select instance number to restore INTO: " INST_NUM
fi
if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi
INSTALL_DIR="${INSTANCES[$((INST_NUM-1))]}"
COMPOSE_FILE="$INSTALL_DIR/$COMPOSE_FILENAME"
ENV_FILE="$INSTALL_DIR/.env"

ACCESS_URL="$(_env_get "$ENV_FILE" CODER_ACCESS_URL)"
DOMAIN="${ACCESS_URL#*://}"; DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN:-$(basename "$INSTALL_DIR")}"

# Everything below runs from the instance directory, exactly like the commands
# the installer prints. Compose re-reads compose.yaml and .env on every call, so
# a restored configuration is picked up by the very next command.
cd "$INSTALL_DIR"

# ── 5. Ask what to restore ──────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "About these options:"
echo ""
echo "  Full recovery restores the configuration (.env with the PostgreSQL"
echo "  password, compose.yaml) and the database. Use it on a new server or to"
echo "  roll the whole instance back. The configuration goes first, and the"
echo "  Compose volumes are REMOVED and re-created, because PostgreSQL only reads"
echo "  its password when its volume is first created - a volume made by the"
echo "  installer would otherwise reject the restored password. The current"
echo "  database is dumped to a safety copy first."
echo ""
echo "  Database only replaces the Coder database with the backup. It keeps the"
echo "  instance's CURRENT configuration and password, so it suits the same"
echo "  install, not a different one. A safety copy is taken first."
echo ""
echo "  Configuration alone restores .env and compose.yaml. If the database"
echo "  volume was created with a different PostgreSQL password than the backup's,"
echo "  Coder will not be able to log in to it - use Full recovery instead."
echo "------------------------------------------------------------"
echo ""
echo "What do you want to restore?"
echo "  1) Full recovery (configuration + database)"
echo "  2) Database only"
echo "  3) Configuration only"
read -rp "Select [1-3]: " ACTION

DO_DB=false; DO_CFG=false; RESET_VOLUME=false
case "$ACTION" in
  1) DO_DB=true; DO_CFG=true; RESET_VOLUME=true ;;
  2) DO_DB=true ;;
  3) DO_CFG=true ;;
  *) echo "Invalid selection."; exit 1 ;;
esac
if $DO_DB  && ! $HAS_DB;  then echo "Error: this snapshot has no database dump."; exit 1; fi
if $DO_CFG && ! $HAS_CFG; then echo "Error: this snapshot has no configuration (.env and compose.yaml)."; exit 1; fi

# pg_dump ends every complete dump with this line, so it also catches truncation.
if $DO_DB; then
  echo ""
  echo "Verifying the dump..."
  if ! gunzip -c "$SNAP_DUMP" | tail -n 20 | grep -q 'PostgreSQL database dump complete'; then
    echo "Error: $SNAP_DUMP is incomplete or corrupt. Nothing was changed."
    exit 1
  fi
fi

# The configuration switches Compose to whatever project name the snapshot
# carries. If that is a different instance, the new project would start beside
# the current containers instead of replacing them.
if $DO_CFG; then
  SNAP_PROJECT="$(_env_get "$SNAPSHOT_DIR/config/.env" COMPOSE_PROJECT_NAME)"
  CUR_PROJECT="$(_env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)"
  if [ "$SNAP_PROJECT" != "$CUR_PROJECT" ]; then
    echo ""
    echo "Error: this snapshot belongs to Compose project '${SNAP_PROJECT:-?}' but the target is"
    echo "'${CUR_PROJECT:-?}'. Restoring its configuration would leave the current containers"
    echo "running beside a second stack. Install with the snapshot's domain, or choose"
    echo "'Database only'."
    exit 1
  fi
fi

# ── 6. Summary and confirmation ─────────────────────────────────────────────
SNAP_VERSION="$(sed -n 's/^Coder version *: *//p' "$SNAPSHOT_DIR/manifest.txt" 2>/dev/null | head -n1 || true)"
echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Snapshot        : $(basename "$SNAPSHOT_DIR")  (${SNAP_VERSION:-Coder version unknown})"
echo "Target instance : $DOMAIN ($INSTALL_DIR)"
echo "Restoring       :"
$DO_CFG && echo "  - .env and compose.yaml (restored first)"
$DO_DB  && echo "  - PostgreSQL database (dropped and re-created from the dump)"
echo "========================================================="
echo ""
$DO_DB  && echo "WARNING: Coder is stopped and the current database is REPLACED. Anything created after this snapshot is lost."
$RESET_VOLUME && echo "WARNING: the Compose volumes are removed and re-created: PostgreSQL data and coder_home (Coder recreates it; a safety dump is taken first)."
$DO_DB  && echo "Coder cannot run against a database from a newer release than itself: keep the image at the snapshot's version or newer."
echo ""
read -rp "Type 'restore' to continue: " CONFIRM
[ "$CONFIRM" = "restore" ] || { echo "Aborted."; exit 0; }

# ── helpers ─────────────────────────────────────────────────────────────────
# -T: no TTY, so stdin can carry the dump. exec also attaches the script's own
# stdin, which would swallow the operator's answers, so callers that pass no
# input redirect from /dev/null.
db_sh() { docker compose exec -T database sh -c "$1"; }

# PostgreSQL's official image runs a temporary socket-only server while it
# initialises a new volume, then restarts. Probing over TCP only succeeds once
# the final server is up.
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
  echo "Error: PostgreSQL did not become ready (docker compose logs database)."
  exit 1
}

STAMP=$(date +"%Y%m%d-%H%M%S")

# ── 7. Safety copy of what is about to be replaced ──────────────────────────
echo ""
echo "=== Safety copy of the current state ==="
SAFETY_DIR="$INSTALL_DIR/pre-restore-$STAMP"
mkdir -p "$SAFETY_DIR"
chmod 700 "$SAFETY_DIR"
cp "$ENV_FILE" "$SAFETY_DIR/.env"
cp "$COMPOSE_FILE" "$SAFETY_DIR/compose.yaml"
chmod 600 "$SAFETY_DIR/.env" "$SAFETY_DIR/compose.yaml"
echo "Current .env and compose.yaml saved to $SAFETY_DIR"

if $DO_DB; then
  # A stopped or removed stack can still hold data in its volume, and the steps
  # below delete it, so bring the current database up (a no-op when it already
  # is) and save it. If that cannot be done, the operator decides.
  docker compose up -d database >/dev/null 2>&1 || true
  SAFETY_OK=false
  for _ in $(seq 1 15); do
    if db_ready; then SAFETY_OK=true; break; fi
    sleep 2
  done
  if $SAFETY_OK \
    && db_sh 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' </dev/null \
      | gzip > "$SAFETY_DIR/coder.sql.gz"; then
    chmod 600 "$SAFETY_DIR/coder.sql.gz"
    echo "Current database saved to $SAFETY_DIR/coder.sql.gz"
  else
    rm -f "$SAFETY_DIR/coder.sql.gz"
    echo "WARNING: the current database could not be dumped (not running, or a broken volume)."
    read -rp "Continue WITHOUT a safety dump of it? [y/N]: " ANS_NODUMP
    [[ "$ANS_NODUMP" =~ ^[Yy]$ ]] || { echo "Aborted - nothing was changed."; exit 1; }
  fi
fi

# From here on the instance is being changed. If a step fails, say where things
# stand instead of leaving a bare error with Coder possibly stopped.
on_error() {
  local code=$?
  echo ""
  echo "Restore FAILED (exit $code) part-way through - Coder may be stopped."
  echo "  Safety copies : $SAFETY_DIR"
  echo "  Logs          : (cd $INSTALL_DIR && docker compose logs)"
  echo "  The snapshot itself is untouched: fix the cause and run this script again."
  exit "$code"
}
set -o errtrace   # also fire the trap for failures inside helper functions
trap on_error ERR

# ── 8. Stop Coder ───────────────────────────────────────────────────────────
echo ""
echo "=== Stopping Coder ==="
if $RESET_VOLUME; then
  # down -v removes the volumes this compose.yaml declares (PostgreSQL data and
  # coder_home). Compose finds them itself, so this also works when the
  # containers are already gone.
  docker compose down -v
else
  docker compose stop coder
fi

# ── 9. Configuration ────────────────────────────────────────────────────────
if $DO_CFG; then
  echo ""
  echo "=== Restoring configuration ==="
  cp "$SNAPSHOT_DIR/config/.env" "$ENV_FILE"
  cp "$SNAPSHOT_DIR/config/compose.yaml" "$COMPOSE_FILE"
  chmod 600 "$ENV_FILE"
  echo "Restored: $ENV_FILE"
  echo "Restored: $COMPOSE_FILE"
fi

# ── 10. Database ────────────────────────────────────────────────────────────
if $DO_DB; then
  echo ""
  echo "=== Restoring the database ==="
  docker compose up -d database
  wait_db

  # DROP DATABASE cannot run inside a transaction and cannot target the database
  # it is connected to, so work from the maintenance database. WITH (FORCE)
  # ends any lingering connection (PostgreSQL 13+, Coder's minimum).
  echo "Re-creating the database..."
  db_sh 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v db="$POSTGRES_DB"' <<'SQL'
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db";
SQL

  # One transaction: a failure part-way leaves the empty database, not a
  # half-loaded one.
  echo "Loading the dump..."
  gunzip -c "$SNAP_DUMP" \
    | db_sh 'psql -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
  echo "Database restored."
fi

# ── 11. Start Coder ─────────────────────────────────────────────────────────
echo ""
echo "=== Starting Coder ==="
docker compose up -d

ADDR="$(docker compose port coder 7080 2>/dev/null | head -n1 || true)"
if [ -n "$ADDR" ] && command -v curl >/dev/null 2>&1; then
  # A restored database from an older release is migrated on first start.
  echo -n "Waiting for Coder on $ADDR"
  UP=false
  for _ in $(seq 1 90); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${ADDR}/healthz" 2>/dev/null || echo 000)
    [ "$CODE" = "200" ] && { UP=true; break; }
    echo -n "."
    sleep 3
  done
  echo ""
  if $UP; then
    echo "Coder is up."
  else
    echo "Warning: no answer yet - check: (cd $INSTALL_DIR && docker compose logs -f coder)"
    echo "         If it reports unknown encryption keys, the database was encrypted with keys"
    echo "         that are not in this .env/compose.yaml (CODER_EXTERNAL_TOKEN_ENCRYPTION_KEYS)."
  fi
fi

trap - ERR

# ── 12. Things a restore cannot check for you ───────────────────────────────
if $DO_DB && ! $DO_CFG; then
  keylines() { cat "$@" 2>/dev/null | grep 'CODER_EXTERNAL_TOKEN_ENCRYPTION_KEYS' | sort || true; }
  if [ "$(keylines "$SNAPSHOT_DIR/config/.env" "$SNAPSHOT_DIR/config/compose.yaml")" != "$(keylines "$ENV_FILE" "$COMPOSE_FILE")" ]; then
    echo ""
    echo "WARNING: CODER_EXTERNAL_TOKEN_ENCRYPTION_KEYS differ between the snapshot and this instance."
    echo "         If the database is encrypted, Coder will refuse to start until the keys match"
    echo "         (docs/admin/security/database-encryption.md)."
  fi
fi

if $DO_CFG; then
  # group_add carries the docker gid of the machine the snapshot came from.
  HOST_GID="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
  SNAP_GID="$(grep -A1 -E '^[[:space:]]*group_add:' "$COMPOSE_FILE" | grep -oE '[0-9]+' | head -n1 || true)"
  if [ -n "$SNAP_GID" ] && [ -n "$HOST_GID" ] && [ "$SNAP_GID" != "$HOST_GID" ]; then
    echo ""
    echo "WARNING: compose.yaml gives Coder docker gid $SNAP_GID but this host's docker group is $HOST_GID."
    echo "         Docker-based templates will fail until group_add is corrected, then:"
    echo "         (cd $INSTALL_DIR && docker compose up -d)"
  fi
fi

NGINX_SITE="/etc/nginx/sites-enabled/$DOMAIN"
if [ -n "$ADDR" ] && [ -r "$NGINX_SITE" ] && ! grep -q "proxy_pass http://$ADDR" "$NGINX_SITE"; then
  echo ""
  echo "WARNING: $NGINX_SITE does not proxy to $ADDR, where Coder is published now."
  echo "         Update proxy_pass there and reload Nginx."
fi

echo ""
echo "Restore complete."
echo "Instance      : https://$DOMAIN"
echo "Safety copies : $SAFETY_DIR (delete once you have verified the restore)"
echo "Verify by logging in and opening a workspace."
if $DO_DB; then
  echo "Workspaces created after the snapshot are not in the restored database: remove their"
  echo "containers or volumes by hand if they linger."
fi
echo ""
