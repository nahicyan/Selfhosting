#!/bin/bash
# ============================================================
# Rocket.Chat Update Script v1.0
# ============================================================
# Updates every container of a Rocket.Chat instance set up by rocketchat-docker-install.sh:
# Rocket.Chat, MongoDB and NATS, plus ntfy when rocketchat-docker-notify.sh has been run. It follows
# the official Docker guide (set the versions in .env, then `docker compose up -d`) and, before it
# changes anything, takes a full backup (MongoDB + ntfy) with rocketchat-docker-backup.sh.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/nahicyan/Selfhosting/refs/heads/main/OpenSource/RocketChat/scripts/rocketchat-docker-update.sh)"

set -euo pipefail

DEFAULT_RC_PATH="/var/www/docker/rocketchat"
DEFAULT_BACKUP_DIR="/home/backup"
RAW_BASE="https://raw.githubusercontent.com/nahicyan/Selfhosting/refs/heads/main/OpenSource/RocketChat/scripts"
NOTIFY_COMPOSE="docker-compose-rc-notification.yml"
WAIT_SECS=600   # after an upgrade Rocket.Chat can spend minutes on database migrations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR=""
ENV_SNAPSHOT=""
COMPOSE_ARGS=()
declare -A NEW_VERSION=()

# An exported shell variable beats .env inside Compose; make sure the .env edits below are what counts.
unset RELEASE MONGODB_VERSION NATS_VERSION NTFY_VERSION

on_exit() {
  local rc=$?
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  echo ""
  echo "❌ Update did not complete (exit $rc)."
  if [ -n "$ENV_SNAPSHOT" ]; then
    echo "   Your previous settings are saved in $ENV_SNAPSHOT"
  fi
}
trap on_exit EXIT

# ── Helpers ─────────────────────────────────────────────────
die() { echo "Error: $*" >&2; exit 1; }

# The instance's compose files, plus ntfy's when notify.sh has been run - the same set notify.sh uses,
# so Compose sees one project.
dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }

env_get() { grep -m1 "^$1=" .env | cut -d= -f2- | tr -d '"' || true; }

env_set() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    [ -z "$(tail -c1 .env)" ] || echo >> .env   # never glue onto a last line that lacks a newline
    echo "$1=$2" >> .env
  fi
}

# True when both are plain versions (8.0.1) and $2 is older than $1.
is_downgrade() {
  local cur=$1 new=$2
  [[ "$cur" =~ ^[0-9]+(\.[0-9]+)*$ && "$new" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  [ "$cur" != "$new" ] && [ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | head -n1)" = "$new" ]
}

# ask_version VAR "Label": Enter keeps the current tag. The image is re-pulled either way, which still
# picks up patch releases of a floating tag such as MongoDB 8.2 or ntfy latest.
ask_version() {
  local var=$1 label=$2 cur ans
  cur="$(env_get "$var")"
  read -rp "$label [${cur:-compose default}] - new version, or Enter to keep: " ans
  [ -n "$ans" ] || return 0
  [[ "$ans" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "'$ans' is not a valid image tag."
  [ "$ans" != "$cur" ] || return 0
  if is_downgrade "$cur" "$ans"; then
    die "$var $cur -> $ans is a downgrade. Rocket.Chat and MongoDB migrate their data forward, so restore a backup first (rocketchat-docker-restore.sh), then edit .env by hand."
  fi
  NEW_VERSION[$var]="$ans"
}

wait_http() {
  local url=$1 label=$2 i
  printf '==> Waiting for %s' "$label"
  for ((i = 0; i < WAIT_SECS / 5; i++)); do
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      echo " - up."
      return 0
    fi
    printf '.'
    sleep 5
  done
  echo " - no response after ${WAIT_SECS}s."
  return 1
}

for cmd in docker curl flock; do
  command -v "$cmd" >/dev/null || die "'$cmd' is required."
done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Cannot reach Docker - is it running, and is your user in the docker group?"

echo ""
echo "=====> Rocket.Chat Update"
echo "========================================"

# ── 1. Ask for Rocket.Chat instances location ────────────────
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

[ -d "$RC_BASE_PATH" ] || die "Directory '$RC_BASE_PATH' not found."

# ── 2. Select the instance ───────────────────────────────────
echo ""
echo "Scanning for Rocket.Chat instances in: $RC_BASE_PATH"
echo "--------------------------------------------"

# An instance is a rocketchat-compose checkout: <base>/<domain>/compose.yml
mapfile -t INSTANCES < <(find "$RC_BASE_PATH" -mindepth 2 -maxdepth 2 -name compose.yml -exec dirname {} \; | sort)

[ ${#INSTANCES[@]} -gt 0 ] || die "No Rocket.Chat instances found in '$RC_BASE_PATH'."

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
done

echo ""
read -rp "Select instance number: " INST_NUM

if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  die "Invalid selection."
fi

INSTANCE_DIR="${INSTANCES[$((INST_NUM-1))]}"
INSTANCE_NAME="$(basename "$INSTANCE_DIR")"
cd "$INSTANCE_DIR"

# ── 3. Pre-flight checks ─────────────────────────────────────
for f in .env compose.yml compose.database.yml compose.nats.yml; do
  [ -f "$f" ] || die "$f not found in $INSTANCE_DIR - is this a rocketchat-compose checkout?"
done

exec 9> "${TMPDIR:-/tmp}/rocketchat-update-${INSTANCE_NAME}.lock"
flock -n 9 || die "Another update of $INSTANCE_NAME is already running."

for f in compose.database.yml compose.nats.yml compose.yml "$NOTIFY_COMPOSE"; do
  if [ -f "$f" ]; then COMPOSE_ARGS+=(-f "$f"); fi
done
HAS_NTFY=false
if [ -f "$NOTIFY_COMPOSE" ]; then HAS_NTFY=true; fi

# The backup below dumps MongoDB from the running container, so a stopped stack can't be updated safely.
MONGO_CID="$(dc ps -q mongodb 2>/dev/null | head -n1 || true)"
[ -n "$MONGO_CID" ] || die "MongoDB isn't running for $INSTANCE_NAME. Start the stack first - the update backs it up before changing anything."
MONGO_NAME="$(docker inspect -f '{{.Name}}' "$MONGO_CID")"
MONGO_NAME="${MONGO_NAME#/}"

# Use the backup script next to this one, or fetch it when this script was run through curl.
BACKUP_SCRIPT="$SCRIPT_DIR/rocketchat-docker-backup.sh"
if [ ! -f "$BACKUP_SCRIPT" ]; then
  TMP_DIR="$(mktemp -d)"
  BACKUP_SCRIPT="$TMP_DIR/rocketchat-docker-backup.sh"
  curl -fsSL "$RAW_BASE/rocketchat-docker-backup.sh" -o "$BACKUP_SCRIPT" \
    || die "could not download $RAW_BASE/rocketchat-docker-backup.sh"
fi
# An older backup script would prompt interactively and would not back up ntfy.
grep -q 'RC_INSTANCE_PATH' "$BACKUP_SCRIPT" && grep -q 'ntfy' "$BACKUP_SCRIPT" \
  || die "$BACKUP_SCRIPT is too old (no non-interactive mode / ntfy backup). Update it first."

echo ""
echo "Running now:"
dc ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}' || dc ps

# ── 4. Choose versions ───────────────────────────────────────
echo ""
echo "Press Enter to keep a version (its image is still re-pulled), or type a new one."
ask_version RELEASE         "Rocket.Chat (RELEASE)         "
ask_version MONGODB_VERSION "MongoDB     (MONGODB_VERSION) "
ask_version NATS_VERSION    "NATS        (NATS_VERSION)    "
if $HAS_NTFY; then
  ask_version NTFY_VERSION  "ntfy        (NTFY_VERSION)    "
fi

echo ""
read -rp "Backup directory [$DEFAULT_BACKUP_DIR]: " BACKUP_DIR
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
BACKUP_DIR="${BACKUP_DIR/#\~/$HOME}"

# ── 5. Confirm ───────────────────────────────────────────────
echo ""
echo "==> Instance : $INSTANCE_NAME ($INSTANCE_DIR)"
echo "==> Backup   : MongoDB$($HAS_NTFY && echo ' + ntfy') -> $BACKUP_DIR (taken first; the update stops if it fails)"
if [ ${#NEW_VERSION[@]} -eq 0 ]; then
  echo "==> Versions : unchanged - re-pulling the current tags"
else
  for var in "${!NEW_VERSION[@]}"; do
    old="$(env_get "$var")"
    echo "==> Version  : $var ${old:-compose default} -> ${NEW_VERSION[$var]}"
  done
fi
if [ -n "${NEW_VERSION[MONGODB_VERSION]:-}" ]; then
  echo "    MongoDB: move up one major version at a time - see the MongoDB section of the update guidelines"
  echo "    (https://docs.rocket.chat/v1/docs/guidelines-for-updating-rocketchat)."
fi
echo "==> Rocket.Chat is unavailable while its container is recreated (a minute or two, longer if the new"
echo "    version migrates the database)."
echo ""
read -rp "Proceed? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ── 6. Back up ───────────────────────────────────────────────
echo ""
RC_BACKUP_DIR="$BACKUP_DIR" RC_INSTANCE_PATH="$INSTANCE_DIR" RC_MONGO_CONTAINER="$MONGO_NAME" \
  bash "$BACKUP_SCRIPT" || die "Backup failed - nothing was changed. Fix the problem above and re-run."

# ── 7. Apply the new versions and pull ───────────────────────
OLD_IMAGE_IDS="$(dc images -q 2>/dev/null | sort -u || true)"

ENV_SNAPSHOT="$INSTANCE_DIR/.env.pre-update.$(date +%Y-%m-%d-%H-%M-%S)"
cp -p .env "$ENV_SNAPSHOT"
for var in "${!NEW_VERSION[@]}"; do
  env_set "$var" "${NEW_VERSION[$var]}"
done

# Pull before recreating anything, so a registry problem leaves the running stack untouched.
echo ""
echo "==> Pulling images (the running containers are not touched yet)…"
if ! dc pull; then
  cp -p "$ENV_SNAPSHOT" .env
  rm -f "$ENV_SNAPSHOT"
  ENV_SNAPSHOT=""
  die "Image pull failed - .env restored and no container was changed."
fi

# ── 8. Recreate the containers ───────────────────────────────
echo ""
echo "==> Recreating containers…"
dc up -d

# ── 9. Verify ────────────────────────────────────────────────
FAILED=0

HOST_PORT="$(env_get HOST_PORT)"
HOST_PORT="${HOST_PORT:-3000}"
BIND_IP="$(env_get BIND_IP)"
case "$BIND_IP" in ""|0.0.0.0) BIND_IP=127.0.0.1 ;; esac
RC_URL="http://$BIND_IP:$HOST_PORT"

echo ""
wait_http "$RC_URL/api/info" "Rocket.Chat" || FAILED=1
if $HAS_NTFY; then
  NTFY_IP="$(env_get NTFY_BIND_IP)"
  NTFY_PORT="$(env_get NTFY_HOST_PORT)"
  wait_http "http://${NTFY_IP:-127.0.0.1}:${NTFY_PORT:-8090}/v1/health" "ntfy" || FAILED=1
fi

RESTARTING="$(dc ps --status restarting --services 2>/dev/null || true)"
if [ -n "$RESTARTING" ]; then
  echo "⚠️  Containers stuck restarting: $(echo "$RESTARTING" | tr '\n' ' ')"
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "❌ The new versions were applied, but the checks above failed."
  echo "   Logs     : cd $INSTANCE_DIR && docker compose ${COMPOSE_ARGS[*]} logs --tail 100"
  echo "   Roll back: 1) restore the database with rocketchat-docker-restore.sh (a newer Rocket.Chat may have"
  echo "                 migrated it, and an older one can't read that)"
  echo "              2) cp $ENV_SNAPSHOT $INSTANCE_DIR/.env"
  echo "              3) cd $INSTANCE_DIR && docker compose ${COMPOSE_ARGS[*]} up -d"
  exit 1
fi

echo ""
echo "✅ Update completed successfully!"
echo "   Rocket.Chat   : $(curl -fsS --max-time 5 "$RC_URL/api/info" 2>/dev/null | grep -o '"version":"[^"]*"' || echo 'running')"
echo "   Previous .env : $ENV_SNAPSHOT"
echo ""
dc ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}' || dc ps

# ── 10. Optional: remove the images this update replaced ─────
# `docker rmi` refuses images that a container still uses, so anything shared with another instance stays.
STALE="$(comm -23 <(printf '%s\n' "$OLD_IMAGE_IDS") <(dc images -q | sort -u) | grep . || true)"
if [ -n "$STALE" ]; then
  echo ""
  read -rp "Remove the $(wc -l <<< "$STALE") image(s) this update replaced, to free disk space? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    xargs -r docker rmi <<< "$STALE" >/dev/null 2>&1 || true
    echo "==> Done."
  fi
fi
