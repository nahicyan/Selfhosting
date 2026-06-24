#!/bin/bash
# ============================================================
# Rocket.Chat MongoDB Backup Script v1.0
# ============================================================

set -euo pipefail

DEFAULT_RC_PATH="/var/www/docker/rocketchat"

# ── 1. Ask where to save the backup ─────────────────────────
echo ""
echo "=====> Rocket.Chat MongoDB Backup"
echo "========================================"
echo "Choose the directory where you want to save the backup:"
echo "  1) Default: /home/backup"
echo "  2) Custom path"
read -rp "Select [1/2]: " BACKUP_CHOICE

if [ "$BACKUP_CHOICE" = "2" ]; then
  read -rep "Enter custom backup directory: " BACKUP_DIR
  BACKUP_DIR="${BACKUP_DIR/#\~/$HOME}"
else
  BACKUP_DIR="/home/backup"
fi

if [ ! -d "$BACKUP_DIR" ]; then
  read -rp "Directory '$BACKUP_DIR' does not exist. Create it? [y/N]: " CREATE_DIR
  if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
    mkdir -p "$BACKUP_DIR"
    echo "Created directory: $BACKUP_DIR"
  else
    echo "Aborting."
    exit 1
  fi
fi

# ── 2. Ask for Rocket.Chat instances location ────────────────
echo ""
echo "Where are your Rocket.Chat instances located?"
echo "  1) Default: $DEFAULT_RC_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Rocket.Chat base path: " RC_BASE_PATH
  RC_BASE_PATH="${RC_BASE_PATH/#\~/$HOME}"
else
  RC_BASE_PATH="$DEFAULT_RC_PATH"
fi

if [ ! -d "$RC_BASE_PATH" ]; then
  echo "Error: Directory '$RC_BASE_PATH' not found."
  exit 1
fi

# ── 3. List installed instances ──────────────────────────────
echo ""
echo "Scanning for Rocket.Chat instances in: $RC_BASE_PATH"
echo "--------------------------------------------"

# An instance dir should contain a compose file or .env
mapfile -t INSTANCES < <(find "$RC_BASE_PATH" -maxdepth 2 \
  \( -name "docker-compose.yml" -o -name "compose.yml" -o -name ".env" \) \
  -exec dirname {} \; | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Rocket.Chat instances found in '$RC_BASE_PATH'."
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

# ── 4. Find the MongoDB container for this instance ──────────
echo ""
echo "Looking for MongoDB container for instance: $INSTANCE_NAME"

# Try to find the container by label or name pattern
MONGO_CONTAINER=""

# First try: container_tag label set in compose files
MONGO_CONTAINER=$(docker ps --filter "label=container_tag=${INSTANCE_NAME}#mongodb" \
  --format "{{.Names}}" 2>/dev/null | head -n1 || true)

# Second try: name matching
if [ -z "$MONGO_CONTAINER" ]; then
  MONGO_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | \
    grep -i "${INSTANCE_NAME}.*mongo\|mongo.*${INSTANCE_NAME}" | head -n1 || true)
fi

# Third try: list all running mongo containers and ask user
if [ -z "$MONGO_CONTAINER" ]; then
  echo "Could not auto-detect MongoDB container. Listing all running containers:"
  echo ""
  mapfile -t ALL_CONTAINERS < <(docker ps --format "{{.Names}}" 2>/dev/null)
  for i in "${!ALL_CONTAINERS[@]}"; do
    echo "  $((i+1))) ${ALL_CONTAINERS[$i]}"
  done
  echo ""
  read -rp "Select MongoDB container number: " CONT_NUM
  if ! [[ "$CONT_NUM" =~ ^[0-9]+$ ]] || [ "$CONT_NUM" -lt 1 ] || [ "$CONT_NUM" -gt "${#ALL_CONTAINERS[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi
  MONGO_CONTAINER="${ALL_CONTAINERS[$((CONT_NUM-1))]}"
fi

echo "Using container: $MONGO_CONTAINER"

# ── 5. Perform backup ────────────────────────────────────────
DATE_STAMP=$(date +"%Y-%m-%d-%H-%M-%S")
INSTANCE_DIR="${BACKUP_DIR}/rocketchat-${INSTANCE_NAME}/${DATE_STAMP}"
mkdir -p "$INSTANCE_DIR"
BACKUP_FILE="${INSTANCE_DIR}/RC_${INSTANCE_NAME}_${DATE_STAMP}.dump"

echo ""
echo "Starting backup..."
echo "  Instance : $INSTANCE_NAME"
echo "  Container: $MONGO_CONTAINER"
echo "  Folder   : $INSTANCE_DIR"
echo "  Output   : $(basename "$BACKUP_FILE")"
echo ""

docker exec "$MONGO_CONTAINER" sh -c 'mongodump --archive' > "$BACKUP_FILE"

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
echo ""
echo "✅ Backup completed successfully!"
echo "   Folder : $INSTANCE_DIR"
echo "   File   : $(basename "$BACKUP_FILE")"
echo "   Size   : $BACKUP_SIZE"