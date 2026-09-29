#!/bin/bash
# ============================================================
# Rocket.Chat Backup Script v1.2 (MongoDB + ntfy)
# ============================================================
# Backs up the instance's MongoDB and, when rocketchat-docker-notify.sh has been run for it, ntfy's
# users, access rules and tokens.
#
# Non-interactive mode: rocketchat-docker-update.sh sets these to skip the matching prompts.
# With none of them set the script behaves exactly as it always has.
#   RC_BACKUP_DIR       directory to save the backup in
#   RC_INSTANCE_PATH    the instance's compose directory (e.g. /var/www/docker/rocketchat/chat.example.com)
#   RC_MONGO_CONTAINER  name of that instance's running MongoDB container

set -euo pipefail

DEFAULT_RC_PATH="/var/www/docker/rocketchat"
NOTIFY_COMPOSE="docker-compose-rc-notification.yml"

echo ""
echo "=====> Rocket.Chat Backup (MongoDB + ntfy)"
echo "========================================"

# ── 1. Ask where to save the backup ─────────────────────────
if [ -n "${RC_BACKUP_DIR:-}" ]; then
  BACKUP_DIR="$RC_BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
else
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

if [ -n "${RC_INSTANCE_PATH:-}" ]; then
  [ -d "$RC_INSTANCE_PATH" ] || { echo "Error: Directory '$RC_INSTANCE_PATH' not found."; exit 1; }
  SELECTED_PATH="$RC_INSTANCE_PATH"
  INSTANCE_NAME=$(basename "$SELECTED_PATH")
else
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
fi

# ── 4. Find the MongoDB container for this instance ──────────
echo ""
echo "Looking for MongoDB container for instance: $INSTANCE_NAME"

MONGO_CONTAINER=""

if [ -n "${RC_MONGO_CONTAINER:-}" ]; then
  MONGO_CONTAINER="$RC_MONGO_CONTAINER"
else
  # Try to find the container by label or name pattern

  # Docker Compose sanitizes the project name (strips dots and special chars) when setting
  # the container_tag label, so portal.landersinvestment.com → portallandersinvestmentcom
  SANITIZED_NAME=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')

  # First try: container_tag label set in compose files (uses sanitized project name)
  MONGO_CONTAINER=$(docker ps --filter "label=container_tag=${SANITIZED_NAME}#mongodb" \
    --format "{{.Names}}" 2>/dev/null | head -n1 || true)

  # Second try: name matching
  if [ -z "$MONGO_CONTAINER" ]; then
    MONGO_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | \
      grep -i "${INSTANCE_NAME}.*mongo\|mongo.*${INSTANCE_NAME}\|${SANITIZED_NAME}.*mongo\|mongo.*${SANITIZED_NAME}" | \
      grep -iv "exporter" | head -n1 || true)
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
fi

echo "Using container: $MONGO_CONTAINER"

# ── 5. Perform backup ────────────────────────────────────────
DATE_STAMP=$(date +"%Y-%m-%d-%H-%M-%S")
INSTANCE_DIR="${BACKUP_DIR}/rocketchat/${INSTANCE_NAME}/${DATE_STAMP}"
mkdir -p "$INSTANCE_DIR"
BACKUP_FILE="${INSTANCE_DIR}/RC_${INSTANCE_NAME}_${DATE_STAMP}.dump"

echo ""
echo "Starting backup..."
echo "  Instance : $INSTANCE_NAME"
echo "  Container: $MONGO_CONTAINER"
echo "  Folder   : $INSTANCE_DIR"
echo "  Output   : $(basename "$BACKUP_FILE")"
echo ""

# A failed dump must not leave a partial .dump behind: the restore script lists any *.dump as usable.
if ! docker exec "$MONGO_CONTAINER" sh -c 'mongodump --archive' > "$BACKUP_FILE" || [ ! -s "$BACKUP_FILE" ]; then
  rm -f "$BACKUP_FILE"
  rmdir "$INSTANCE_DIR" 2>/dev/null || true
  echo ""
  echo "❌ Backup FAILED - mongodump returned an error or an empty archive. The partial file was removed."
  exit 1
fi

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)

# ── 6. Back up ntfy, if this instance has it ─────────────────
# ntfy keeps its users, access rules and API tokens in auth.db; losing it means re-creating every login
# and issuing a new token for the Rocket.Chat App. cache.db and the attachments only hold the last few
# hours of messages, so they are left out. Changes to auth.db are rare, so a copy of the running
# container's files (including any -wal/-shm) is safe without stopping ntfy.
NTFY_FILE=""
if [ -f "$SELECTED_PATH/$NOTIFY_COMPOSE" ]; then
  NTFY_CONTAINER=$(cd "$SELECTED_PATH" && docker compose -f compose.database.yml -f compose.nats.yml \
    -f compose.yml -f "$NOTIFY_COMPOSE" ps -q ntfy 2>/dev/null | head -n1 || true)

  if [ -z "$NTFY_CONTAINER" ]; then
    echo ""
    echo "⚠️  ntfy is set up for this instance but is not running - it was NOT backed up."
  else
    NTFY_FILE="${INSTANCE_DIR}/NTFY_${INSTANCE_NAME}_${DATE_STAMP}.tar.gz"
    echo ""
    echo "Backing up ntfy..."
    if ! docker exec "$NTFY_CONTAINER" sh -c 'cd /var/lib/ntfy && tar cf - auth.db*' | gzip > "$NTFY_FILE" \
      || ! tar -tzf "$NTFY_FILE" | grep -x 'auth.db' > /dev/null; then
      rm -f "$NTFY_FILE"
      echo ""
      echo "❌ ntfy backup FAILED. The MongoDB dump is intact: $(basename "$BACKUP_FILE")"
      exit 1
    fi
  fi
fi

echo ""
echo "✅ Backup completed successfully!"
echo "   Folder : $INSTANCE_DIR"
echo "   File   : $(basename "$BACKUP_FILE")"
echo "   Size   : $BACKUP_SIZE"
if [ -n "$NTFY_FILE" ]; then
  echo "   ntfy   : $(basename "$NTFY_FILE") ($(du -sh "$NTFY_FILE" | cut -f1))"
fi
