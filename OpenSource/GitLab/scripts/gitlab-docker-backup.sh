#!/bin/bash
set -euo pipefail

DEFAULT_GITLAB_PATH="/var/www/docker/gitlab"

# ── 1. Ask where to save the backup ─────────────────────────────────────────
echo ""
echo "=====> GitLab Backup"
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

# ── 2. Ask for GitLab instances location ────────────────────────────────────
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

# ── 3. List installed instances ──────────────────────────────────────────────
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
read -rp "Select instance number: " INST_NUM

if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED_PATH="${INSTANCES[$((INST_NUM-1))]}"
INSTANCE_NAME=$(basename "$SELECTED_PATH")
cd "$SELECTED_PATH"

# ── 4. Find the GitLab container for this instance ───────────────────────────
CONTAINER=$(docker compose ps --format "{{.Name}}" gitlab 2>/dev/null | head -n1)

if [ -z "$CONTAINER" ]; then
  echo "Error: gitlab service is not running in '$SELECTED_PATH'."
  exit 1
fi

echo "Using container: $CONTAINER"

# ── 5. Choose backup scope ────────────────────────────────────────────────────
echo ""
echo "What would you like to back up?"
echo "  1) Full backup (repositories, uploads, artifacts, registry, etc.)"
echo "  2) Database only (fast — useful right before an upgrade)"
read -rp "Select [1/2]: " SCOPE_CHOICE

SKIP_ARG=""
if [ "$SCOPE_CHOICE" = "2" ]; then
  SKIP_ARG="SKIP=artifacts,repositories,registry,uploads,builds,pages,lfs,packages,terraform_state"
fi

# ── 6. Run gitlab-backup create ───────────────────────────────────────────────
echo ""
echo "Starting GitLab application backup (this can take a while for large instances)..."
echo ""

docker compose exec -T gitlab gitlab-backup create $SKIP_ARG

# gitlab-backup writes into /var/opt/gitlab/backups inside the container,
# which is bind-mounted at ./data/backups on the host.
LATEST_TAR=$(find "$SELECTED_PATH/data/backups" -maxdepth 1 -name "*_gitlab_backup.tar" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)

if [ -z "$LATEST_TAR" ]; then
  echo "ERROR: No backup archive found in $SELECTED_PATH/data/backups after running gitlab-backup create."
  exit 1
fi

# ── 7. Collect the archive + secrets/config (gitlab-secrets.json, gitlab.rb) ─
# The application backup does NOT include /etc/gitlab — losing gitlab-secrets.json
# makes an existing backup undecryptable, so it must be saved alongside it.
DATE_STAMP=$(date +"%Y-%m-%d-%H-%M-%S")
INSTANCE_DIR="${BACKUP_DIR}/gitlab-${INSTANCE_NAME}/${DATE_STAMP}"
mkdir -p "$INSTANCE_DIR"

cp "$LATEST_TAR" "$INSTANCE_DIR/"
tar -czf "$INSTANCE_DIR/gitlab-config.tar.gz" -C "$SELECTED_PATH" config

echo ""
echo "✅ Backup completed successfully!"
echo "   Instance : $INSTANCE_NAME"
echo "   Folder   : $INSTANCE_DIR"
echo "   Archive  : $(basename "$LATEST_TAR")  ($(du -sh "$LATEST_TAR" | cut -f1))"
echo "   Config   : gitlab-config.tar.gz  ($(du -sh "$INSTANCE_DIR/gitlab-config.tar.gz" | cut -f1))"
