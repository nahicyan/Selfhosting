#!/bin/bash
set -euo pipefail
# =============================================================================
# Bitwarden Docker Restore Script v1.0
# =============================================================================
# Restores from a snapshot created by bitwarden-docker-backup.sh:
#   <backup-root>/bitwarden/<domain>/<date-n-time>/database/<vault_FULL_*.BAK>
#   <backup-root>/bitwarden/<domain>/<date-n-time>/config/config.tar.gz
#   <backup-root>/bitwarden/<domain>/<date-n-time>/attachments/attachments.tar.gz
#
# Restore options:
#   1) Full recovery   - configuration + database + attachments (new/empty
#                        install, or rolling everything back)
#   2) Database only   - the vault data, e.g. after accidental deletion
#   3) Configuration   - env, identity cert, data-protection keys, config.yml
#   4) Attachments     - vault attachments and Sends
#
# The database is restored the way Bitwarden documents it (temp/backup.txt):
# RESTORE DATABASE ... WITH REPLACE via sqlcmd inside bitwarden-mssql.
#
# To recover onto a NEW server: run bitwarden-docker-install.sh first (so the
# instance directory, images and host Nginx exist), then choose "Full
# recovery" here.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_BITWARDEN_PATH="/var/www/docker/bitwarden"

echo ""
echo "=====> Bitwarden Restore"
echo "========================================"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }

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

BW_BACKUPS_DIR="$BACKUP_ROOT/bitwarden"
[ -d "$BW_BACKUPS_DIR" ] || { echo "Error: '$BW_BACKUPS_DIR' not found."; exit 1; }

# ── 2. Select backup domain ─────────────────────────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$BW_BACKUPS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || { echo "No domain backup folders found in '$BW_BACKUPS_DIR'."; exit 1; }

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
printf "  %-4s %-33s %-10s %-8s %-12s\n" "#" "Date" "Database" "Config" "Attachments"
printf "  %-4s %-33s %-10s %-8s %-12s\n" "----" "---------------------------------" "----------" "--------" "------------"
for i in "${!SNAPSHOTS[@]}"; do
  S="${SNAPSHOTS[$i]}"
  DB_S=$(compgen -G "$S/database/*.BAK" >/dev/null && echo "ok" || echo "--")
  CF_S=$([ -f "$S/config/config.tar.gz" ] && echo "ok" || echo "--")
  AT_S=$([ -f "$S/attachments/attachments.tar.gz" ] && echo "ok" || echo "--")
  printf "  %-4s %-33s %-10s %-8s %-12s\n" "$((i+1)))" "$(_nice_date "$(basename "$S")")" "$DB_S" "$CF_S" "$AT_S"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM
if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi
SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"

BAK_FILE=$(find "$SNAPSHOT_DIR/database" -maxdepth 1 -name '*.BAK' 2>/dev/null | sort | tail -n1 || true)
HAS_DB=false;  [ -n "$BAK_FILE" ] && HAS_DB=true
HAS_CFG=false; [ -f "$SNAPSHOT_DIR/config/config.tar.gz" ] && HAS_CFG=true
HAS_ATT=false; [ -f "$SNAPSHOT_DIR/attachments/attachments.tar.gz" ] && HAS_ATT=true

# ── 4. Select the target instance ───────────────────────────────────────────
echo ""
read -rep "Bitwarden instances base path [$DEFAULT_BITWARDEN_PATH]: " BW_BASE_PATH
BW_BASE_PATH="${BW_BASE_PATH:-$DEFAULT_BITWARDEN_PATH}"
BW_BASE_PATH="${BW_BASE_PATH/#\~/$HOME}"
[ -d "$BW_BASE_PATH" ] || { echo "Error: Directory '$BW_BASE_PATH' not found."; exit 1; }

mapfile -t INSTANCES < <(find "$BW_BASE_PATH" -maxdepth 2 -name bitwarden.conf -exec dirname {} \; | sort -u)
[ ${#INSTANCES[@]} -gt 0 ] || { echo "No Bitwarden instances found in '$BW_BASE_PATH'. Run bitwarden-docker-install.sh first."; exit 1; }

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
COMPOSE_FILE="$BWDATA/docker/docker-compose.yml"
ENV_FILE="$BWDATA/env/global.override.env"
[ -f "$COMPOSE_FILE" ] || { echo "Error: $COMPOSE_FILE not found."; exit 1; }
# shellcheck disable=SC1091
source "$INSTALL_DIR/bitwarden.conf"

# ── 5. Ask what to restore ──────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "About these options:"
echo ""
echo "  Full recovery restores everything: configuration (env with the database"
echo "  password, identity certificate, data-protection keys), the database and"
echo "  attachments. Use it on a new server or to roll the whole instance back."
echo "  Configuration is restored FIRST, and the mssql data directory is set"
echo "  aside (not deleted) so the database is re-created with the restored"
echo "  password before the backup is loaded."
echo ""
echo "  Database only replaces the vault database with the backup (RESTORE ..."
echo "  WITH REPLACE). It uses the instance's CURRENT password, so it suits the"
echo "  same install, not a different one. A safety backup is taken first."
echo ""
echo "  Configuration alone restores env/keys/certificates. Restoring it over a"
echo "  running install whose database password differs from the backup will"
echo "  leave the api unable to log in to mssql - use Full recovery instead."
echo ""
echo "  Attachments extracts over the existing files; nothing is deleted."
echo "------------------------------------------------------------"
echo ""
echo "What do you want to restore?"
echo "  1) Full recovery (configuration + database + attachments)"
echo "  2) Database only"
echo "  3) Configuration only"
echo "  4) Attachments only"
read -rp "Select [1-4]: " ACTION

DO_DB=false; DO_CFG=false; DO_ATT=false
case "$ACTION" in
  1) DO_DB=true; DO_CFG=true; DO_ATT=true ;;
  2) DO_DB=true ;;
  3) DO_CFG=true ;;
  4) DO_ATT=true ;;
  *) echo "Invalid selection."; exit 1 ;;
esac
# Full recovery restores whatever the snapshot has (attachments may be absent).
if [ "$ACTION" = "1" ] && ! $HAS_ATT; then DO_ATT=false; fi
$DO_DB  && ! $HAS_DB  && { echo "Error: this snapshot has no database backup."; exit 1; }
$DO_CFG && ! $HAS_CFG && { echo "Error: this snapshot has no configuration archive."; exit 1; }
$DO_ATT && ! $HAS_ATT && { echo "Error: this snapshot has no attachments archive."; exit 1; }

# Refuse a corrupt archive before anything is stopped or overwritten.
$DO_CFG && { tar tzf "$SNAPSHOT_DIR/config/config.tar.gz" >/dev/null || { echo "Error: config.tar.gz is corrupt."; exit 1; }; }
$DO_ATT && { tar tzf "$SNAPSHOT_DIR/attachments/attachments.tar.gz" >/dev/null || { echo "Error: attachments.tar.gz is corrupt."; exit 1; }; }

RESET_MSSQL=false
if [ "$ACTION" = "1" ]; then
  RESET_MSSQL=true
  echo ""
  echo "Full recovery will move $BWDATA/mssql/data aside so mssql is re-created"
  echo "with the restored credentials (it is kept as data.pre-restore-<time>)."
fi

echo ""
echo "Instance        : ${DOMAIN:-$(basename "$INSTALL_DIR")} ($INSTALL_DIR)"
echo "Snapshot        : $(basename "$SNAPSHOT_DIR")"
echo "Database        : $($DO_DB && echo "restore $(basename "$BAK_FILE")" || echo "no")"
echo "Configuration   : $($DO_CFG && echo yes || echo no)"
echo "Attachments     : $($DO_ATT && echo yes || echo no)"
echo ""
echo "WARNING: Bitwarden will be stopped and existing data will be overwritten."
read -rp "Type 'restore' to continue: " CONFIRM
[ "$CONFIRM" = "restore" ] || { echo "Aborted."; exit 0; }

# ── helpers ─────────────────────────────────────────────────────────────────
dc() {
  local files=(-f "$COMPOSE_FILE")
  [ -f "$BWDATA/docker/docker-compose.override.yml" ] && files+=(-f "$BWDATA/docker/docker-compose.override.yml")
  docker compose "${files[@]}" "$@"
}

wait_mssql() {
  local status=starting
  echo -n "Waiting for mssql to become healthy"
  for _ in $(seq 1 90); do
    status=$(docker inspect -f '{{.State.Health.Status}}' bitwarden-mssql 2>/dev/null || echo starting)
    [ "$status" = "healthy" ] && break
    echo -n "."
    sleep 2
  done
  echo ""
  [ "$status" = "healthy" ] || { echo "Error: bitwarden-mssql did not become healthy (docker logs bitwarden-mssql)."; exit 1; }
}

# Reads DB credentials from the (possibly just restored) env file.
load_db_credentials() {
  local conn
  conn=$(grep '^globalSettings__sqlServer__connectionString=' "$ENV_FILE" | head -n1 | cut -d= -f2-)
  SA_USER=$(sed -n 's/.*User Id=\([^;"]*\).*/\1/p' <<<"$conn")
  SA_PASSWORD=$(sed -n 's/.*Password=\([^;"]*\).*/\1/p' <<<"$conn")
  DB_NAME=$(sed -n 's/.*Initial Catalog=\([^;"]*\).*/\1/p' <<<"$conn")
  : "${SA_USER:=sa}"; : "${DB_NAME:=vault}"
  [ -n "$SA_PASSWORD" ] || { echo "Error: could not read the database password from $ENV_FILE."; exit 1; }
}

sql() {
  docker exec -e SQLCMDPASSWORD="$SA_PASSWORD" bitwarden-mssql /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U "$SA_USER" -C -b -Q "$1"
}

STAMP=$(date +"%Y%m%d-%H%M%S")

# ── 6. Safety backup of what is about to be replaced ────────────────────────
echo ""
echo "=== Safety backup of the current state ==="
SAFETY_DIR="$INSTALL_DIR/pre-restore-$STAMP"
mkdir -p "$SAFETY_DIR"
chmod 700 "$SAFETY_DIR"
if $DO_DB && docker ps --format '{{.Names}}' | grep -qx bitwarden-mssql; then
  docker exec -i bitwarden-mssql /backup-db.sh \
    && echo "Database backup written to $BWDATA/mssql/backups (kept)" \
    || echo "Warning: safety database backup failed - continuing."
fi
if $DO_CFG; then
  SAFE=()
  for p in bitwarden.conf bwdata/config.yml bwdata/env bwdata/identity bwdata/core/aspnet-dataprotection; do
    [ -e "$INSTALL_DIR/$p" ] && SAFE+=("$p")
  done
  [ ${#SAFE[@]} -eq 0 ] || tar czf "$SAFETY_DIR/config-before.tar.gz" -C "$INSTALL_DIR" "${SAFE[@]}"
  echo "Current configuration saved to $SAFETY_DIR/config-before.tar.gz"
fi

# ── 7. Stop Bitwarden ───────────────────────────────────────────────────────
echo ""
echo "=== Stopping Bitwarden ==="
dc down || true

# ── 8. Configuration ────────────────────────────────────────────────────────
if $DO_CFG; then
  echo ""
  echo "=== Restoring configuration ==="
  tar xzf "$SNAPSHOT_DIR/config/config.tar.gz" -C "$INSTALL_DIR"
  chmod 600 "$ENV_FILE" "$INSTALL_DIR/bitwarden.conf" 2>/dev/null || true
  echo "Restored config.tar.gz (env/uid.env was left untouched)."
fi

# ── 9. Attachments ──────────────────────────────────────────────────────────
if $DO_ATT; then
  echo ""
  echo "=== Restoring attachments ==="
  tar xzf "$SNAPSHOT_DIR/attachments/attachments.tar.gz" -C "$INSTALL_DIR"
  echo "Restored attachments."
fi

# ── 10. Database ────────────────────────────────────────────────────────────
if $DO_DB; then
  echo ""
  echo "=== Restoring the database ==="
  if $RESET_MSSQL && [ -d "$BWDATA/mssql/data" ] && [ -n "$(ls -A "$BWDATA/mssql/data" 2>/dev/null)" ]; then
    mv "$BWDATA/mssql/data" "$BWDATA/mssql/data.pre-restore-$STAMP"
    echo "Moved existing mssql data to $BWDATA/mssql/data.pre-restore-$STAMP"
  fi
  load_db_credentials

  dc up -d mssql
  wait_mssql

  BAK_NAME="restore_${STAMP}_$(basename "$BAK_FILE")"
  mkdir -p "$BWDATA/mssql/backups"
  cp "$BAK_FILE" "$BWDATA/mssql/backups/$BAK_NAME"

  echo "Verifying backup file..."
  sql "RESTORE VERIFYONLY FROM DISK = N'/etc/bitwarden/mssql/backups/$BAK_NAME'" >/dev/null

  echo "Restoring $DB_NAME from $(basename "$BAK_FILE")..."
  # Same effect as the documented offline restore: kick out connections,
  # replace the database, let everyone back in. On a fresh mssql the database
  # does not exist yet, hence the DB_ID guard.
  sql "IF DB_ID(N'$DB_NAME') IS NOT NULL ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$DB_NAME] FROM DISK = N'/etc/bitwarden/mssql/backups/$BAK_NAME' WITH REPLACE;
ALTER DATABASE [$DB_NAME] SET MULTI_USER;" >/dev/null
  rm -f "$BWDATA/mssql/backups/$BAK_NAME"
  echo "Database restored."
fi

# ── 11. Start Bitwarden ─────────────────────────────────────────────────────
echo ""
echo "=== Starting Bitwarden ==="
dc up -d

PORT="${PORT:-}"
if [ -n "$PORT" ]; then
  echo -n "Waiting for Bitwarden on 127.0.0.1:$PORT"
  UP=false
  for _ in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${PORT}/alive" 2>/dev/null || echo 000)
    [ "$CODE" = "200" ] && { UP=true; break; }
    echo -n "."
    sleep 2
  done
  echo ""
  $UP && echo "Bitwarden is up." || echo "Warning: no answer yet - check: (cd $INSTALL_DIR && ./manage.sh logs)"
fi

echo ""
echo "Restore complete."
echo "Safety copies : $SAFETY_DIR"
$RESET_MSSQL && echo "Old mssql data: $BWDATA/mssql/data.pre-restore-$STAMP (delete once you have verified the restore)"
echo "Verify by logging in at https://${DOMAIN:-your-domain}. If the host Nginx vhost or certificate is"
echo "missing on this server, re-run the installer's Nginx step or copy bitwarden-nginx.conf."
echo ""
