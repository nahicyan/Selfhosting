#!/bin/bash
set -euo pipefail

DEFAULT_GITLAB_PATH="/var/www/docker/gitlab"

echo ""
echo "=====> GitLab Restore"
echo "========================================"

# ── 1. Choose backup base directory ─────────────────────────────────────────
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

# ── 2. Select instance (domain) ──────────────────────────────────────────────
echo ""
mapfile -t GITLAB_DOMAIN_DIRS < <(find "$BACKUP_BASE" -maxdepth 1 -type d -name "gitlab-*" | sort)

if [ ${#GITLAB_DOMAIN_DIRS[@]} -eq 0 ]; then
  echo "No gitlab-* backup folders found in '$BACKUP_BASE'."
  exit 1
fi

if [ ${#GITLAB_DOMAIN_DIRS[@]} -eq 1 ]; then
  GITLAB_DOMAIN_DIR="${GITLAB_DOMAIN_DIRS[0]}"
  echo "Using backup folder: $(basename "$GITLAB_DOMAIN_DIR")"
else
  echo "Found backup folders:"
  for i in "${!GITLAB_DOMAIN_DIRS[@]}"; do
    echo "  $((i+1))) $(basename "${GITLAB_DOMAIN_DIRS[$i]}")"
  done
  echo ""
  read -rp "Select domain number: " DOM_NUM
  if ! [[ "$DOM_NUM" =~ ^[0-9]+$ ]] || [ "$DOM_NUM" -lt 1 ] || [ "$DOM_NUM" -gt "${#GITLAB_DOMAIN_DIRS[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi
  GITLAB_DOMAIN_DIR="${GITLAB_DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

# ── 3. List available backups ────────────────────────────────────────────────
_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

mapfile -t TIMESTAMPS < <(find "$GITLAB_DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

if [ ${#TIMESTAMPS[@]} -eq 0 ]; then
  echo "No backup snapshots found in '$(basename "$GITLAB_DOMAIN_DIR")'."
  exit 1
fi

echo ""
printf "  %-4s %-33s %-8s %-8s\n" "#" "Date" "Archive" "Config"
printf "  %-4s %-33s %-8s %-8s\n" "----" "---------------------------------" "--------" "--------"

for i in "${!TIMESTAMPS[@]}"; do
  STAMP=$(basename "${TIMESTAMPS[$i]}")
  NICE=$(_nice_date "$STAMP")
  TAR_CHECK=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "*_gitlab_backup.tar" | head -1)
  CFG_CHECK=$(find "${TIMESTAMPS[$i]}" -maxdepth 1 -name "gitlab-config.tar.gz" | head -1)
  TAR_S=$( [ -n "$TAR_CHECK" ] && echo "ok" || echo "--" )
  CFG_S=$( [ -n "$CFG_CHECK" ] && echo "ok" || echo "--" )
  printf "  %-4s %-33s %-8s %-8s\n" "$((i+1)))" "$NICE" "$TAR_S" "$CFG_S"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM

if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#TIMESTAMPS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED_DIR="${TIMESTAMPS[$((TS_NUM-1))]}"
SELECTED_TAR=$(find "$SELECTED_DIR" -maxdepth 1 -name "*_gitlab_backup.tar" | head -1)
SELECTED_CFG=$(find "$SELECTED_DIR" -maxdepth 1 -name "gitlab-config.tar.gz" | head -1)

if [ -z "$SELECTED_TAR" ]; then
  echo "ERROR: No *_gitlab_backup.tar file found in the selected backup. Cannot restore."
  exit 1
fi

echo "Selected: $(basename "$SELECTED_TAR")"

# ── 4. Ask for GitLab instances location ─────────────────────────────────────
echo ""
echo "Where are your GitLab instances located?"
echo "  1) Default: $DEFAULT_GITLAB_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom GitLab base path: " GITLAB_BASE_PATH
  GITLAB_BASE_PATH="${GITLAB_BASE_PATH/#\~/$HOME}"
else
  GITLAB_BASE_PATH="$DEFAULT_GITLAB_PATH"
fi

if [ ! -d "$GITLAB_BASE_PATH" ]; then
  echo "Error: Directory '$GITLAB_BASE_PATH' not found."
  exit 1
fi

# ── 5. List installed instances ──────────────────────────────────────────────
echo ""
echo "Scanning for GitLab instances in: $GITLAB_BASE_PATH"
echo "--------------------------------------------"

mapfile -t INSTANCES < <(find "$GITLAB_BASE_PATH" -maxdepth 2 -name "docker-compose.yml" -exec dirname {} \; | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No GitLab instances found in '$GITLAB_BASE_PATH'."
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
cd "$SELECTED_PATH"

# ── 6. Find the GitLab container for this instance ───────────────────────────
CONTAINER=$(docker compose ps --format "{{.Name}}" gitlab 2>/dev/null | head -n1)

if [ -z "$CONTAINER" ]; then
  echo "Error: gitlab service is not running in '$SELECTED_PATH'."
  echo "Start it first with: (cd \"$SELECTED_PATH\" && docker compose up -d)"
  exit 1
fi

echo "Using container: $CONTAINER"

# ── 7. Confirm before restoring ───────────────────────────────────────────────
echo ""
echo "⚠️  WARNING: This will OVERWRITE the repositories, database, and uploads"
echo "            currently in '$INSTANCE_NAME' with the contents of this backup!"
echo ""
echo "  Backup archive : $(basename "$SELECTED_TAR")"
if [ -n "$SELECTED_CFG" ]; then
  echo "  Config archive : $(basename "$SELECTED_CFG")  (gitlab.rb / gitlab-secrets.json — restore manually if needed)"
fi
echo "  Target instance: $INSTANCE_NAME"
echo "  Container      : $CONTAINER"
echo ""
read -rp "Are you sure you want to proceed? Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Restore cancelled."
  exit 0
fi

# ── 8. Copy the archive into the backups volume ───────────────────────────────
# gitlab-backup restore only looks inside /var/opt/gitlab/backups (bind-mounted
# at ./data/backups on the host) and expects ownership by the container's git user.
BACKUP_FILENAME=$(basename "$SELECTED_TAR")
cp -f "$SELECTED_TAR" "$SELECTED_PATH/data/backups/$BACKUP_FILENAME"
BACKUP_ID="${BACKUP_FILENAME%_gitlab_backup.tar}"

# ── 9. Stop services that write to the data being restored ───────────────────
echo ""
echo "Stopping puma and sidekiq (repositories/database must be quiescent during restore)..."
docker compose exec -T gitlab gitlab-ctl stop puma
docker compose exec -T gitlab gitlab-ctl stop sidekiq

# ── 10. Perform restore ────────────────────────────────────────────────────────
echo ""
echo "Starting restore..."
echo ""

docker compose exec -T gitlab gitlab-backup restore BACKUP="$BACKUP_ID" force=yes

echo ""
echo "Restarting GitLab..."
docker compose exec -T gitlab gitlab-ctl restart
docker compose exec -T gitlab gitlab-rake gitlab:check SANITIZE=true || true

echo ""
echo "✅ Restore completed successfully!"
echo "   Restored from : $BACKUP_FILENAME"
echo "   Into instance : $INSTANCE_NAME"
if [ -n "$SELECTED_CFG" ]; then
  echo ""
  echo "💡 If this is a fresh instance (not the one the backup was taken from), also restore"
  echo "   gitlab-secrets.json — otherwise GitLab cannot decrypt existing CI variables/tokens:"
  echo "   tar -xzf \"$SELECTED_CFG\" -C \"$SELECTED_PATH\" config/gitlab-secrets.json"
  echo "   (cd \"$SELECTED_PATH\" && docker compose restart)"
fi
