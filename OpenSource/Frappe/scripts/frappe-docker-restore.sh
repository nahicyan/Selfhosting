#!/bin/bash
set -euo pipefail

# =============================================================================
# Frappe LMS Docker Restore Script v1.0
# =============================================================================
#
# ── UPSTREAM BUG WORKAROUND — lms main branch / frappe/lms#2350 ──────────────
# Because ghcr.io/frappe/lms:stable ships without lms, the install script
# builds lms from the main branch (see frappe-docker-install.sh for details).
# The main branch can have entries in patches.txt whose Python files have since
# been deleted (cleaned up after execution). When restoring an older backup into
# a fresh v16 install, bench migrate tries to run those missing patches and
# fails with: ModuleNotFoundError: No module named 'lms.patches.v2_0.<name>'
#
# Fix: --skip-failing on bench migrate tells frappe to log and skip any patch
# whose module cannot be imported rather than aborting the whole migration.
#
# HOW TO REVERT once the upstream image is fixed and we switch to a stable
# tagged release of lms (not main branch):
#   In Step 6 below, remove --skip-failing from bench migrate:
#     docker exec $CONTAINER bench --site $DOMAIN migrate
# ─────────────────────────────────────────────────────────────────────────────


CONTAINER="learning_prod_setup-backend-1"

echo ""
echo "=====> Frappe LMS Restore"
echo "========================================"

# ── 1. Choose backup base directory ──────────────────────────
echo "Choose the directory where your backup files are located:"
echo "  1) Default: /home/backup"
echo "  2) Custom path"
read -rp "Select [1/2]: " BACKUP_BASE_CHOICE

if [ "$BACKUP_BASE_CHOICE" = "2" ]; then
  read -rep "Enter custom backup base path: " BACKUP_BASE
  BACKUP_BASE="${BACKUP_BASE/#\~/$HOME}"
else
  BACKUP_BASE="/home/backup"
fi

[ -d "$BACKUP_BASE" ] || { echo "Error: '$BACKUP_BASE' not found."; exit 1; }

# ── 2. Select instance (domain) ───────────────────────────────
echo ""
mapfile -t FRAPPE_DOMAIN_DIRS < <(find "$BACKUP_BASE" -maxdepth 1 -type d -name "frappe-lms-*" | sort)

if [ ${#FRAPPE_DOMAIN_DIRS[@]} -eq 0 ]; then
  echo "No frappe-lms-* backup folders found in '$BACKUP_BASE'."
  exit 1
fi

if [ ${#FRAPPE_DOMAIN_DIRS[@]} -eq 1 ]; then
  FRAPPE_DOMAIN_DIR="${FRAPPE_DOMAIN_DIRS[0]}"
  echo "Using backup folder: $(basename "$FRAPPE_DOMAIN_DIR")"
else
  echo "Found backup folders:"
  for i in "${!FRAPPE_DOMAIN_DIRS[@]}"; do
    echo "  $((i+1))) $(basename "${FRAPPE_DOMAIN_DIRS[$i]}")"
  done
  echo ""
  read -rp "Select domain number: " DOM_NUM
  if ! [[ "$DOM_NUM" =~ ^[0-9]+$ ]] || [ "$DOM_NUM" -lt 1 ] || [ "$DOM_NUM" -gt "${#FRAPPE_DOMAIN_DIRS[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi
  FRAPPE_DOMAIN_DIR="${FRAPPE_DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

DOMAIN="${FRAPPE_DOMAIN_DIR##*/frappe-lms-}"

# ── 3. List available backups ──────────────────────────────────
_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

mapfile -t TIMESTAMPS < <(find "$FRAPPE_DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

if [ ${#TIMESTAMPS[@]} -eq 0 ]; then
  echo "No backup snapshots found in '$(basename "$FRAPPE_DOMAIN_DIR")'."
  exit 1
fi

echo ""
printf "  %-4s %-33s %-6s %-8s %-10s %-8s\n" "#" "Date" "DB" "Files" "Private" "Config"
printf "  %-4s %-33s %-6s %-8s %-10s %-8s\n" "----" "---------------------------------" "------" "--------" "----------" "--------"

for i in "${!TIMESTAMPS[@]}"; do
  STAMP=$(basename "${TIMESTAMPS[$i]}")
  NICE=$(_nice_date "$STAMP")
  db_c=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "*-database.sql.gz" | head -1)
  fl_c=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "*-files.tgz" ! -name "*-private-files.tgz" | head -1)
  pr_c=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "*-private-files.tgz" | head -1)
  cf_c=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "*-site_config_backup.json" | head -1)
  db_s=$( [ -n "$db_c" ] && echo "ok" || echo "--" )
  fl_s=$( [ -n "$fl_c" ] && echo "ok" || echo "--" )
  pr_s=$( [ -n "$pr_c" ] && echo "ok" || echo "--" )
  cf_s=$( [ -n "$cf_c" ] && echo "ok" || echo "--" )
  printf "  %-4s %-33s %-6s %-8s %-10s %-8s\n" "$((i+1)))" "$NICE" "$db_s" "$fl_s" "$pr_s" "$cf_s"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM

if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#TIMESTAMPS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

BACKUP_PATH="${TIMESTAMPS[$((TS_NUM-1))]}"

# ── Validate selected backup ───────────────────────────────────
DB_HOST=$(find "$BACKUP_PATH" -maxdepth 1 -name "*-database.sql.gz" | head -1)
FILES_HOST=$(find "$BACKUP_PATH" -maxdepth 1 -name "*-files.tgz" ! -name "*-private-files.tgz" | head -1)
PRIVATE_HOST=$(find "$BACKUP_PATH" -maxdepth 1 -name "*-private-files.tgz" | head -1)
CONFIG_HOST=$(find "$BACKUP_PATH" -maxdepth 1 -name "*-site_config_backup.json" | head -1)

if [ -z "$DB_HOST" ]; then
  echo "ERROR: No database backup (*-database.sql.gz) found in selected backup. Cannot restore."
  exit 1
fi

if [ -z "$FILES_HOST" ] || [ -z "$PRIVATE_HOST" ]; then
  echo ""
  echo "WARNING: Some files are missing from this backup:"
  [ -z "$FILES_HOST" ]   && echo "  -- Public files (*-files.tgz) not found"
  [ -z "$PRIVATE_HOST" ] && echo "  -- Private files (*-private-files.tgz) not found"
  echo "  The database will be restored. Missing files will be skipped."
  echo ""
  read -rp "Proceed? [y/N]: " ans_missing
  [[ "$ans_missing" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

[ -z "$CONFIG_HOST" ] && echo "NOTE: No site config backup found — site config will not be restored."

# ── Set derived paths ──────────────────────────────────────────
DOMAIN_UNDERSCORE=$(echo "$DOMAIN" | tr '.' '_')
DOCKER_DIR="/var/www/docker/frappe-lms/$DOMAIN"

# Show password file and ask for password
echo "=== Password file contents ==="
cat "$DOCKER_DIR/learning_prod_setup-passwords.txt"
echo ""
read -sp "Enter MySQL root password: " MYSQL_PWD
echo

echo "=== Step 1: Creating backup directory in container ==="
docker exec $CONTAINER mkdir -p /home/frappe/backups

echo "=== Step 2: Copying backup files to container ==="
docker cp "$BACKUP_PATH/." $CONTAINER:/home/frappe/backups/

echo "=== Step 3: Fixing permissions ==="
docker exec $CONTAINER chown -R frappe:frappe /home/frappe/backups/

echo "=== Step 4: Finding latest backup files ==="
# bench backup --compress creates .tgz for files (not .tar).
DB_FILE=$(docker exec $CONTAINER bash -c "ls -t /home/frappe/backups/*${DOMAIN_UNDERSCORE}-database.sql.gz 2>/dev/null | head -1")
FILES_TAR=$(docker exec $CONTAINER bash -c "ls -t /home/frappe/backups/*${DOMAIN_UNDERSCORE}-files.tgz 2>/dev/null | head -1")
PRIVATE_TAR=$(docker exec $CONTAINER bash -c "ls -t /home/frappe/backups/*${DOMAIN_UNDERSCORE}-private-files.tgz 2>/dev/null | head -1")

echo "Database:      $DB_FILE"
echo "Public files:  $FILES_TAR"
echo "Private files: $PRIVATE_TAR"

if [ -z "$DB_FILE" ]; then
    echo "ERROR: No database backup found for $DOMAIN"
    exit 1
fi
if [ -z "$FILES_TAR" ]; then
    echo "WARNING: No public files backup found — files will not be restored."
fi
if [ -z "$PRIVATE_TAR" ]; then
    echo "WARNING: No private files backup found — private files will not be restored."
fi

echo "=== Step 5: Restoring backup ==="
RESTORE_CMD="bench --site $DOMAIN restore $DB_FILE --db-root-password $MYSQL_PWD"
[ -n "$FILES_TAR" ]   && RESTORE_CMD="$RESTORE_CMD --with-public-files $FILES_TAR"
[ -n "$PRIVATE_TAR" ] && RESTORE_CMD="$RESTORE_CMD --with-private-files $PRIVATE_TAR"
docker exec $CONTAINER bash -c "$RESTORE_CMD"

echo "=== Step 6: Running migrations ==="
# --skip-failing: skips patches whose Python files no longer exist in the lms
# main branch (see header comment above). Remove once using a stable lms release.
docker exec $CONTAINER bench --site $DOMAIN migrate --skip-failing

echo "=== Step 7: Clearing caches ==="
docker exec $CONTAINER bench --site $DOMAIN clear-cache
docker exec $CONTAINER bench --site $DOMAIN clear-website-cache

echo "=== Step 8: Restarting containers ==="
cd "$DOCKER_DIR"
docker compose -f learning_prod_setup-compose.yml restart

echo "=== Restore complete! ==="
echo "Site: https://$DOMAIN"