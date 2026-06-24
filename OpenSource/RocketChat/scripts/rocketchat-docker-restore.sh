#!/bin/bash
# ============================================================
# Rocket.Chat MongoDB Restore Script v1.0
# ============================================================

set -euo pipefail

DEFAULT_RC_PATH="/var/www/docker/rocketchat"

echo ""
echo "=====> Rocket.Chat MongoDB Restore"
echo "========================================"

# ── 1. Choose backup base directory ─────────────────────────
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

# ── 2. Select instance (domain) ──────────────────────────────
echo ""
mapfile -t RC_DOMAIN_DIRS < <(find "$BACKUP_BASE" -maxdepth 1 -type d -name "rocketchat-*" | sort)

if [ ${#RC_DOMAIN_DIRS[@]} -eq 0 ]; then
  echo "No rocketchat-* backup folders found in '$BACKUP_BASE'."
  exit 1
fi

if [ ${#RC_DOMAIN_DIRS[@]} -eq 1 ]; then
  RC_DOMAIN_DIR="${RC_DOMAIN_DIRS[0]}"
  echo "Using backup folder: $(basename "$RC_DOMAIN_DIR")"
else
  echo "Found backup folders:"
  for i in "${!RC_DOMAIN_DIRS[@]}"; do
    echo "  $((i+1))) $(basename "${RC_DOMAIN_DIRS[$i]}")"
  done
  echo ""
  read -rp "Select domain number: " DOM_NUM
  if ! [[ "$DOM_NUM" =~ ^[0-9]+$ ]] || [ "$DOM_NUM" -lt 1 ] || [ "$DOM_NUM" -gt "${#RC_DOMAIN_DIRS[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi
  RC_DOMAIN_DIR="${RC_DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

# ── 3. List available backups ────────────────────────────────
_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

mapfile -t TIMESTAMPS < <(find "$RC_DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

if [ ${#TIMESTAMPS[@]} -eq 0 ]; then
  echo "No backup snapshots found in '$(basename "$RC_DOMAIN_DIR")'."
  exit 1
fi

echo ""
printf "  %-4s %-33s %-8s\n" "#" "Date" "Dump"
printf "  %-4s %-33s %-8s\n" "----" "---------------------------------" "--------"

for i in "${!TIMESTAMPS[@]}"; do
  STAMP=$(basename "${TIMESTAMPS[$i]}")
  NICE=$(_nice_date "$STAMP")
  DUMP_CHECK=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "*.dump" | head -1)
  DUMP_S=$( [ -n "$DUMP_CHECK" ] && echo "ok" || echo "--" )
  printf "  %-4s %-33s %-8s\n" "$((i+1)))" "$NICE" "$DUMP_S"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM

if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#TIMESTAMPS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED_DIR="${TIMESTAMPS[$((TS_NUM-1))]}"
SELECTED_DUMP=$(find "$SELECTED_DIR" -maxdepth 1 -name "*.dump" | head -1)

if [ -z "$SELECTED_DUMP" ]; then
  echo "ERROR: No .dump file found in the selected backup. Cannot restore."
  exit 1
fi

echo "Selected: $(basename "$SELECTED_DUMP")"

# ── 3. Ask for Rocket.Chat instances location ────────────────
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

# ── 4. List installed instances ──────────────────────────────
echo ""
echo "Scanning for Rocket.Chat instances in: $RC_BASE_PATH"
echo "--------------------------------------------"

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
read -rp "Select instance number to restore INTO: " INST_NUM

if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED_PATH="${INSTANCES[$((INST_NUM-1))]}"
INSTANCE_NAME=$(basename "$SELECTED_PATH")

# ── 5. Find the MongoDB container for this instance ──────────
echo ""
echo "Looking for MongoDB container for instance: $INSTANCE_NAME"

MONGO_CONTAINER=""

# First try: container_tag label
MONGO_CONTAINER=$(docker ps --filter "label=container_tag=${INSTANCE_NAME}#mongodb" \
  --format "{{.Names}}" 2>/dev/null | head -n1 || true)

# Second try: name pattern
if [ -z "$MONGO_CONTAINER" ]; then
  MONGO_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | \
    grep -i "${INSTANCE_NAME}.*mongo\|mongo.*${INSTANCE_NAME}" | head -n1 || true)
fi

# Third try: list all and ask
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

# ── 6. Confirm before restoring ─────────────────────────────
echo ""
echo "⚠️  WARNING: This will DROP all existing collections and overwrite them from the backup!"
echo "            Stop the RocketChat container before restoring to avoid write conflicts."
echo ""
echo "  Backup file : $(basename "$SELECTED_DUMP")"
echo "  Target      : $INSTANCE_NAME"
echo "  Container   : $MONGO_CONTAINER"
echo ""
read -rp "Are you sure you want to proceed? Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Restore cancelled."
  exit 0
fi

# ── 7. Perform restore ───────────────────────────────────────
echo ""
echo "Starting restore..."
echo "(--drop: each collection is dropped before being restored for a clean slate)"
echo ""

docker exec -i "$MONGO_CONTAINER" sh -c 'mongorestore --archive --drop' < "$SELECTED_DUMP"

echo ""
echo "✅ Restore completed successfully!"
echo "   Restored from : $(basename "$SELECTED_DUMP")"
echo "   Into instance : $INSTANCE_NAME"
echo ""
echo "💡 Tip: Restart both containers to apply changes:"
echo "   cd $SELECTED_PATH && docker compose -f compose.database.yml -f compose.yml restart"