#!/bin/bash
set -euo pipefail
# =============================================================================
# Frappe LMS Docker Backup Script v1.0
# =============================================================================

DEFAULT_FRAPPE_PATH="/var/www/docker/frappe-lms"
CONTAINER="learning_prod_setup-backend-1"

# ── 1. Ask where to save the backup ──────────────────────────────────────────
echo ""
echo "=====> Frappe LMS Backup"
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

# ── 2. Ask for Frappe LMS instances location ──────────────────────────────────
echo ""
echo "Where are your Frappe LMS instances located?"
echo "  1) Default: $DEFAULT_FRAPPE_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Frappe LMS base path: " FRAPPE_BASE_PATH
  FRAPPE_BASE_PATH="${FRAPPE_BASE_PATH/#\~/$HOME}"
else
  FRAPPE_BASE_PATH="$DEFAULT_FRAPPE_PATH"
fi

if [ ! -d "$FRAPPE_BASE_PATH" ]; then
  echo "Error: Directory '$FRAPPE_BASE_PATH' not found."
  exit 1
fi

# ── 3. List installed instances ────────────────────────────────────────────────
echo ""
echo "Scanning for Frappe LMS instances in: $FRAPPE_BASE_PATH"
echo "--------------------------------------------"

mapfile -t INSTANCES < <(find "$FRAPPE_BASE_PATH" -maxdepth 2 \
  -name "learning_prod_setup-compose.yml" \
  -exec dirname {} \; | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Frappe LMS instances found in '$FRAPPE_BASE_PATH'."
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
DOMAIN=$(basename "$SELECTED_PATH")
DOMAIN_UNDERSCORE=$(echo "$DOMAIN" | tr '.' '_')

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DEST="${BACKUP_PARENT}/frappe-lms-${DOMAIN}/${TIMESTAMP}"
mkdir -p "$BACKUP_DEST"

echo ""
echo "Instance : $DOMAIN"
echo "Folder   : $BACKUP_DEST"

echo "=== Step 1: Creating backup directory in container ==="
docker exec $CONTAINER mkdir -p /home/frappe/backups

echo "=== Step 2: Running bench backup inside container ==="
docker exec $CONTAINER \
    bench --site "$DOMAIN" backup \
        --with-files \
        --compress

if [ $? -ne 0 ]; then
    echo "ERROR: bench backup failed."
    exit 1
fi

echo "=== Step 3: Finding latest backup files in container ==="

DB_FILE=$(docker exec $CONTAINER bash -c \
    "ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-database.sql.gz 2>/dev/null | head -1")
FILES_TAR=$(docker exec $CONTAINER bash -c \
    "ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-files.tgz 2>/dev/null | grep -v '\-private-files' | head -1")
PRIVATE_TAR=$(docker exec $CONTAINER bash -c \
    "ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-private-files.tgz 2>/dev/null | head -1")
CONFIG_JSON=$(docker exec $CONTAINER bash -c \
    "ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-site_config_backup.json 2>/dev/null | head -1")

echo "Database:      $DB_FILE"
echo "Public files:  $FILES_TAR"
echo "Private files: $PRIVATE_TAR"
echo "Config:        $CONFIG_JSON"

if [ -z "$DB_FILE" ]; then
    echo "ERROR: No database backup found for $DOMAIN"
    exit 1
fi

echo "=== Step 4: Copying backup files to host ==="
docker cp "$CONTAINER:$DB_FILE" "$BACKUP_DEST/"

if [ -n "$FILES_TAR" ]; then
    docker cp "$CONTAINER:$FILES_TAR" "$BACKUP_DEST/"
else
    echo "WARNING: No public files backup found, skipping."
fi

if [ -n "$PRIVATE_TAR" ]; then
    docker cp "$CONTAINER:$PRIVATE_TAR" "$BACKUP_DEST/"
else
    echo "WARNING: No private files backup found, skipping."
fi

if [ -n "$CONFIG_JSON" ]; then
    docker cp "$CONTAINER:$CONFIG_JSON" "$BACKUP_DEST/"
else
    echo "WARNING: No site config backup found, skipping."
fi

echo "=== Step 5: Verifying copied files ==="
ls -lh "$BACKUP_DEST/"

echo "=== Step 6: Cleaning up old backups inside container (keeping last 3) ==="
docker exec $CONTAINER bash -c "
    ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-database.sql.gz 2>/dev/null | \
    tail -n +4 | xargs -r rm --
    ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-files.tgz 2>/dev/null | grep -v '\-private-files' | \
    tail -n +4 | xargs -r rm --
    ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-private-files.tgz 2>/dev/null | \
    tail -n +4 | xargs -r rm --
    ls -t /home/frappe/frappe-bench/sites/$DOMAIN/private/backups/*-site_config_backup.json 2>/dev/null | \
    tail -n +4 | xargs -r rm --
"

echo ""
echo "=== Backup complete! ==="
echo "Site:     https://$DOMAIN"
echo "Saved to: $BACKUP_DEST"
echo ""
echo "Files saved:"
ls -lh "$BACKUP_DEST/"
