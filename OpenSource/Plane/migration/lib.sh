# shellcheck shell=bash
# shellcheck disable=SC2034  # the constants below are used by the scripts that source this file
# =============================================================================
# Shared helpers for the migration/ steps (sourced by 01-03, not run directly).
# Same conventions as ../scripts/plane-docker-backup.sh - keep them in step.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_PLANE_PATH="/var/www/docker/plane"
COMPOSE_FILENAME="docker-compose.yaml"

# The image Plane pinned upstream (makeplane/plane #9829, commit f25814c, on the
# preview branch, 2026-09-15): the last regular MinIO community release, which
# MinIO serves from quay.io after removing minio/minio from Docker Hub.
# MINIO_TARGET_TAG / MINIO_TARGET_IMAGE override it - for testing, or if a later
# tag is deliberately chosen (see README.md, "Notes for LLMs").
PINNED_TAG="${MINIO_TARGET_TAG:-RELEASE.2025-09-07T16-13-09Z}"
TARGET_IMAGE="${MINIO_TARGET_IMAGE:-quay.io/minio/minio:$PINNED_TAG}"
ROLLBACK_REPO="plane-minio-rollback"
FRESH_BACKUP_HOURS=24

_die() { echo "ERROR: $*" >&2; exit 1; }

# _env_get <file> <key> - last KEY=value in a dotenv file, surrounding quotes removed.
_env_get() {
  local v
  v="$(grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  v="${v#[\'\"]}"; v="${v%[\'\"]}"
  printf '%s' "$v"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || _die "docker is required."
  docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
  docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is your user in the 'docker' group (or run as root)?"
}

# select_instance - asks for the instances folder, lists the Plane instances found
# there (a docker-compose.yaml naming makeplane/plane-backend next to a plane.env)
# and sets PROJECT_DIR, COMPOSE_FILE, ENV_FILE, DOMAIN and PROJECT, then defines
# dc() and vol_of() for that instance and moves into its directory.
select_instance() {
  local base f i n
  read -rep "Plane instances base path [$DEFAULT_PLANE_PATH]: " base
  base="${base:-$DEFAULT_PLANE_PATH}"
  base="${base/#\~/$HOME}"
  [ -d "$base" ] || _die "Directory '$base' not found."
  base="$(cd "$base" && pwd)"

  local -a instances=()
  while IFS= read -r f; do
    if [ -f "$(dirname "$f")/plane.env" ] && grep -q 'makeplane/plane-backend' "$f"; then
      instances+=("$(dirname "$f")")
    fi
  done < <(find "$base" -maxdepth 2 -name "$COMPOSE_FILENAME" | sort -u)
  [ ${#instances[@]} -gt 0 ] || _die "No Plane instances found in '$base'."

  echo "Found instances:"
  for i in "${!instances[@]}"; do
    echo "  $((i+1))) $(basename "${instances[$i]}")  (${instances[$i]})"
  done
  if [ ${#instances[@]} -eq 1 ]; then
    n=1
  else
    echo ""
    read -rp "Select instance number: " n
  fi
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#instances[@]}" ]; then
    _die "Invalid selection."
  fi

  PROJECT_DIR="${instances[$((n-1))]}"
  COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_FILENAME"
  ENV_FILE="$PROJECT_DIR/plane.env"
  DOMAIN="$(_env_get "$ENV_FILE" APP_DOMAIN)"
  DOMAIN="${DOMAIN:-$(basename "$PROJECT_DIR")}"
  # Same name plane-docker-install.sh gives the Compose project.
  PROJECT="plane-${DOMAIN//./-}"

  cd "$PROJECT_DIR" || _die "cannot enter $PROJECT_DIR"
}

dc() { docker compose -f "$COMPOSE_FILENAME" --env-file=plane.env --project-name "$PROJECT" "$@"; }

# ask_backup_root - same menu as the backup and restore scripts; sets BACKUP_ROOT.
ask_backup_root() {
  local choice
  echo "Where are your Plane backups?"
  echo "  1) Default: $DEFAULT_BACKUP_ROOT"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " choice
  if [ "$choice" = "2" ]; then
    read -rep "Enter custom backup directory: " BACKUP_ROOT
    BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
  else
    BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
  fi
  BACKUP_ROOT="${BACKUP_ROOT%/}"
}

# ── MinIO facts ─────────────────────────────────────────────────────────────

minio_cid() { dc ps -q plane-minio 2>/dev/null | sed -n '1p'; }

# The image reference the container was created from, and the image it runs.
minio_image_ref() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }
minio_image_id()  { docker inspect -f '{{.Image}}' "$1" 2>/dev/null; }

# The MinIO release the container really runs: `minio --version` prints
# "minio version RELEASE.2025-09-07T16-13-09Z (commit-id=...)".
minio_version() {
  docker exec "$1" minio --version 2>/dev/null </dev/null | grep -oE 'RELEASE\.[^ ]+' | sed -n '1p'
}

# Image reference(s) the compose file gives plane-minio (only the minio image line).
compose_minio_images() { grep -E "^[[:space:]]*image:[[:space:]]*.*(minio/minio|$ROLLBACK_REPO)" "$COMPOSE_FILE" | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+$//' || true; }

# registry_pullable <ref> - can this host read the image's manifest? (no pull)
registry_pullable() { timeout 40 docker manifest inspect "$1" >/dev/null 2>&1; }

# s3_stats - "<objects>:<bytes>" in Plane's bucket, listed through Plane's own S3
# client in the api container (the same endpoint, credentials and bucket Plane uses).
# Read-only.
s3_stats() {
  dc exec -T api python3 -c "
import os, boto3
s = boto3.client('s3', endpoint_url=os.environ['AWS_S3_ENDPOINT_URL'],
                 aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
                 aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
                 region_name=os.environ.get('AWS_REGION') or 'us-east-1')
n = b = 0
for page in s.get_paginator('list_objects_v2').paginate(Bucket=os.environ['AWS_S3_BUCKET_NAME']):
    for o in page.get('Contents', []):
        n += 1; b += o['Size']
print('%d:%d' % (n, b))" </dev/null 2>/dev/null | tr -d '\r' | tail -n1
}

# minio_healthy - MinIO's liveness endpoint, asked from inside the compose network
# the way Plane's own setup.sh probes its API.
minio_healthy() {
  dc exec -T api python3 -c "import urllib.request; urllib.request.urlopen('http://plane-minio:9000/minio/health/live', timeout=3)" </dev/null >/dev/null 2>&1
}

# newest_backup_age_hours <backup-root> - age in whole hours of the newest snapshot
# (folders named YYYY-MM-DD-HH-MM-SS) for this domain, or nothing if there is none.
newest_backup_age_hours() {
  local dir="$1/plane/$DOMAIN" newest stamp epoch
  [ -d "$dir" ] || return 0
  newest="$(find "$dir" -maxdepth 1 -mindepth 1 -type d -name '????-??-??-??-??-??' | sort -r | sed -n '1p')"
  [ -n "$newest" ] || return 0
  stamp="$(basename "$newest")"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  epoch="$(date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" +%s 2>/dev/null)" || return 0
  echo $(( ($(date +%s) - epoch) / 3600 ))
}

# safe_tag <version> - a MinIO release string as a valid Docker tag (they already are).
safe_tag() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }
