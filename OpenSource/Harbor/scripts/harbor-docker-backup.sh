#!/bin/bash
set -euo pipefail
# =============================================================================
# Harbor Docker Backup Script
# =============================================================================
# Backs up an instance installed by harbor-docker-install.sh into one
# timestamped snapshot:
#   <backup-root>/harbor/<domain>/<date-n-time>/postgres/registry.sql.gz
#   <backup-root>/harbor/<domain>/<date-n-time>/secret/secret.tar.gz
#   <backup-root>/harbor/<domain>/<date-n-time>/registry/registry.tar   (optional)
#   <backup-root>/harbor/<domain>/<date-n-time>/config/harbor.yml
#   <backup-root>/harbor/<domain>/<date-n-time>/manifest.txt
#
# postgres/   A plain-SQL pg_dump of "registry", Harbor's only database, run
#             inside harbor-db. Projects, repositories, artifacts and tags,
#             users, robot accounts, replication rules, scan results and every
#             setting changed in the UI live here. pg_dump reads a consistent
#             snapshot, so Harbor stays up.
# secret/     data/secret. keys/secretkey is the key Harbor encrypts the secrets
#             it keeps in the database with (registry endpoint and replication
#             credentials, the OIDC client secret, ...). A database restored
#             without it loads, but none of those can be decrypted. Also the
#             token-signing pair core/private_key.pem + registry/root.crt.
# registry/   data/registry - the image storage (layers and manifests). Optional,
#             because it is usually most of the size. An uncompressed tar: layers
#             are gzip already, so compressing again only costs CPU. Taken AFTER
#             the database dump, so an artifact pushed in between leaves an
#             unreferenced blob (garbage collection removes it), never a database
#             row pointing at a missing layer. Do not run garbage collection while
#             a backup is running. In-progress uploads (_uploads) are skipped.
# config/     harbor.yml as a reference copy (mode 600 - it holds passwords). The
#             restore does not put it back: the target's own harbor.yml decides
#             its domain, port and paths.
#
# Not archived: redis (cache, sessions, job queue), job_logs, the Trivy DB cache
# (downloaded again), logs/, the generated docker-compose.yml and common/config
# (./prepare regenerates them from harbor.yml), Nginx and TLS certificates.
#
# No sudo for the data: Harbor's files are owned by root, 10000 and 999, so they
# are read through a throwaway busybox container, as the Plane scripts do.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_HARBOR_PATH="/var/www/docker/harbor"
HELPER_IMAGE="busybox"
RETAIN_COUNT=7

_die() { echo "Error: $*" >&2; exit 1; }

_human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# Directory of the Compose project a container was started from ("" if none).
_container_dir() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2>/dev/null || true
}

echo ""
echo "=====> Harbor Backup"
echo "========================================"

for cmd in docker gzip tar numfmt df find realpath; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"

# ── 1. Ask where to save the backup ─────────────────────────────────────────
echo "Choose the directory where you want to save the backup:"
echo "  1) Default: $DEFAULT_BACKUP_ROOT"
echo "  2) Custom path"
read -rp "Select [1/2]: " BACKUP_CHOICE

if [ "$BACKUP_CHOICE" = "2" ]; then
  read -rep "Enter custom backup directory: " BACKUP_ROOT
  BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
else
  BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
fi
BACKUP_ROOT="${BACKUP_ROOT%/}"

if [ ! -d "$BACKUP_ROOT" ]; then
  read -rp "Directory '$BACKUP_ROOT' does not exist. Create it? [y/N]: " CREATE_DIR
  if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
    mkdir -p "$BACKUP_ROOT" 2>/dev/null || sudo mkdir -p "$BACKUP_ROOT"
    [ -w "$BACKUP_ROOT" ] || sudo chown "$(id -u):$(id -g)" "$BACKUP_ROOT"
    echo "Created directory: $BACKUP_ROOT"
  else
    echo "Aborting."
    exit 1
  fi
fi

# ── 2. Ask for Harbor instances location ────────────────────────────────────
echo ""
echo "Where are your Harbor instances located?"
echo "  1) Default: $DEFAULT_HARBOR_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Harbor base path: " HARBOR_BASE_PATH
  HARBOR_BASE_PATH="${HARBOR_BASE_PATH/#\~/$HOME}"
else
  HARBOR_BASE_PATH="$DEFAULT_HARBOR_PATH"
fi
HARBOR_BASE_PATH="${HARBOR_BASE_PATH%/}"

[ -d "$HARBOR_BASE_PATH" ] || _die "Directory '$HARBOR_BASE_PATH' not found."

# ── 3. Pick the instance ────────────────────────────────────────────────────
mapfile -t INSTANCES < <(find "$HARBOR_BASE_PATH" -mindepth 3 -maxdepth 3 \
  -path '*/harbor/harbor.yml' -printf '%h\n' | sed 's|/harbor$||' | sort -u)

[ ${#INSTANCES[@]} -gt 0 ] || _die "No Harbor instances found in '$HARBOR_BASE_PATH'."

echo ""
if [ ${#INSTANCES[@]} -eq 1 ]; then
  INSTANCE_DIR="${INSTANCES[0]}"
  echo "Using instance: $(basename "$INSTANCE_DIR")  ($INSTANCE_DIR)"
else
  echo "Found instances:"
  for i in "${!INSTANCES[@]}"; do
    echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
  done
  echo ""
  read -rp "Select instance number: " INST_NUM
  if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
    _die "Invalid selection."
  fi
  INSTANCE_DIR="${INSTANCES[$((INST_NUM-1))]}"
fi

HARBOR_DIR="$INSTANCE_DIR/harbor"
HARBOR_YML="$HARBOR_DIR/harbor.yml"
[ -r "$HARBOR_YML" ] || _die "cannot read $HARBOR_YML."

# Read the same way ./prepare reads data_volume.
DOMAIN="$(sed -n 's/^hostname:[[:space:]]*//p' "$HARBOR_YML" | head -n1 | tr -d "\"' ")"
DATA_DIR="$(grep '^[^#]*data_volume:' "$HARBOR_YML" | awk '{print $NF}' | head -n1 | tr -d "\"'")"
[ -n "$DOMAIN" ]   || _die "no hostname in $HARBOR_YML."
[ -d "$DATA_DIR" ] || _die "data_volume '$DATA_DIR' from $HARBOR_YML does not exist."

# ── 4. Verify Harbor is running from this instance ──────────────────────────
for c in harbor-db harbor-core; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = "true" ] \
    || _die "container $c is not running. Start Harbor first: (cd \"$HARBOR_DIR\" && sudo docker compose up -d)"
  owner="$(_container_dir "$c")"
  [ -n "$owner" ] && [ "$(realpath -m "$owner")" = "$(realpath -m "$HARBOR_DIR")" ] \
    || _die "container $c belongs to '${owner:-unknown}', not $HARBOR_DIR."
done

CORE_IMAGE="$(docker inspect -f '{{.Config.Image}}' harbor-core)"
DB_IMAGE="$(docker inspect -f '{{.Config.Image}}' harbor-db)"
HARBOR_VERSION="${CORE_IMAGE##*:}"
TRIVY="no"
docker inspect trivy-adapter >/dev/null 2>&1 && TRIVY="yes"

docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull -q "$HELPER_IMAGE" >/dev/null

# ── 5. Sizes, and whether to include the image storage ──────────────────────
DB_BYTES="$(docker exec harbor-db psql -U postgres -d registry -tAc "SELECT pg_database_size('registry')" | tr -d '[:space:]')"
[[ "$DB_BYTES" =~ ^[0-9]+$ ]] || _die "could not read the database size from harbor-db."
REG_KB="$(docker run --rm -v "$DATA_DIR/registry:/src:ro" "$HELPER_IMAGE" du -sk /src | awk '{print $1}')"

echo ""
echo "Database        : $(_human "$DB_BYTES") (on disk; the compressed dump is much smaller)"
echo "Image storage   : $(_human $((REG_KB * 1024))) ($DATA_DIR/registry)"
echo ""
echo "The image storage is needed to restore onto a new host. Skip it only when"
echo "it is backed up some other way, or for a quick database-and-keys snapshot."
read -rp "Include the image storage? [Y/n]: " ANS_REG
if [[ "$ANS_REG" =~ ^[Nn]$ ]]; then INCLUDE_REG=false; else INCLUDE_REG=true; fi

NEED_KB=$(( DB_BYTES / 1024 + 10240 ))
$INCLUDE_REG && NEED_KB=$(( NEED_KB + REG_KB ))
AVAIL_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
if [ "$NEED_KB" -gt "$AVAIL_KB" ]; then
  echo ""
  echo "WARNING: this backup needs up to $(_human $((NEED_KB * 1024))), but only"
  echo "         $(_human $((AVAIL_KB * 1024))) is free on $BACKUP_ROOT."
  read -rp "Continue anyway? [y/N]: " ANS_SPACE
  [[ "$ANS_SPACE" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── 6. Confirm ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DEST="$BACKUP_ROOT/harbor/$DOMAIN/$TIMESTAMP"

echo ""
echo "Instance        : $DOMAIN"
echo "Install dir     : $INSTANCE_DIR"
echo "Harbor version  : $HARBOR_VERSION"
echo "data_volume     : $DATA_DIR"
echo "Image storage   : $($INCLUDE_REG && echo "included" || echo "SKIPPED")"
echo "Backup folder   : $BACKUP_DEST"
echo ""
read -rp "Proceed with backup? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# On any failure below, remove the half-written backup so a partial snapshot
# is never mistaken for a good one later during a restore.
cleanup_on_error() {
  local code=$?
  echo ""
  echo "Backup failed (exit $code) - removing incomplete $BACKUP_DEST"
  rm -rf "$BACKUP_DEST"
  exit "$code"
}
trap cleanup_on_error ERR

mkdir -p "$BACKUP_DEST/postgres" "$BACKUP_DEST/secret" "$BACKUP_DEST/config"
chmod 700 "$BACKUP_DEST"   # database dump, encryption key and passwords

# ── 7. PostgreSQL dump ──────────────────────────────────────────────────────
echo ""
echo "=== Backing up PostgreSQL (database: registry) ==="
docker exec harbor-db pg_dump -U postgres --no-owner --no-privileges registry \
  | gzip > "$BACKUP_DEST/postgres/registry.sql.gz"
gzip -t "$BACKUP_DEST/postgres/registry.sql.gz"
echo "Saved: $BACKUP_DEST/postgres/registry.sql.gz ($(du -h "$BACKUP_DEST/postgres/registry.sql.gz" | cut -f1))"

# ── 8. Secret keys ──────────────────────────────────────────────────────────
echo ""
echo "=== Backing up secret keys (data/secret) ==="
docker run --rm -v "$DATA_DIR/secret:/src:ro" "$HELPER_IMAGE" tar -czf - -C /src . \
  > "$BACKUP_DEST/secret/secret.tar.gz"
SECRET_LIST="$(tar -tzf "$BACKUP_DEST/secret/secret.tar.gz")"
grep -qx './keys/secretkey' <<< "$SECRET_LIST" || { echo "Error: keys/secretkey is not in the archive."; false; }
echo "Saved: $BACKUP_DEST/secret/secret.tar.gz"

# ── 9. Image storage ────────────────────────────────────────────────────────
REG_SIZE=""
if $INCLUDE_REG; then
  echo ""
  echo "=== Backing up image storage (data/registry, $(_human $((REG_KB * 1024)))) ==="
  mkdir -p "$BACKUP_DEST/registry"
  docker run --rm -v "$DATA_DIR/registry:/src:ro" "$HELPER_IMAGE" \
    tar -cf - -C /src --exclude=_uploads . > "$BACKUP_DEST/registry/registry.tar"
  echo "Verifying archive..."
  tar -tf "$BACKUP_DEST/registry/registry.tar" > /dev/null
  REG_SIZE="$(du -h "$BACKUP_DEST/registry/registry.tar" | cut -f1)"
  echo "Saved: $BACKUP_DEST/registry/registry.tar ($REG_SIZE)"
fi

# ── 10. harbor.yml ──────────────────────────────────────────────────────────
echo ""
echo "=== Backing up harbor.yml ==="
cp "$HARBOR_YML" "$BACKUP_DEST/config/harbor.yml"
chmod 600 "$BACKUP_DEST/config/harbor.yml"
echo "Saved: $BACKUP_DEST/config/harbor.yml"

# ── 11. Manifest ────────────────────────────────────────────────────────────
{
  echo "Harbor backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Type            : backup"
  echo "Domain          : $DOMAIN"
  echo "Install dir     : $INSTANCE_DIR"
  echo "Harbor version  : $HARBOR_VERSION"
  echo "Core image      : $CORE_IMAGE"
  echo "Database image  : $DB_IMAGE"
  echo "Trivy           : $TRIVY"
  echo "Image storage   : $($INCLUDE_REG && echo "yes ($REG_SIZE)" || echo "no")"
  echo "postgres/       : registry.sql.gz (pg_dump of the registry database)"
  echo "secret/         : secret.tar.gz (data/secret - secretkey + token-signing keys)"
  $INCLUDE_REG && echo "registry/       : registry.tar (data/registry - layers and manifests)"
  echo "config/         : harbor.yml (reference copy, contains passwords - mode 600)"
} > "$BACKUP_DEST/manifest.txt"

# ── 12. Prune old snapshots for this domain ─────────────────────────────────
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/harbor/$DOMAIN"
mapfile -t OLD_SNAPSHOTS < <(find "$DOMAIN_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r | tail -n +$((RETAIN_COUNT+1)))
if [ ${#OLD_SNAPSHOTS[@]} -gt 0 ]; then
  echo ""
  echo "Pruning old snapshots (keeping last $RETAIN_COUNT)..."
  for OLD in "${OLD_SNAPSHOTS[@]}"; do
    echo "  Removing: $OLD"
    rm -rf "$OLD"
  done
fi

trap - ERR
echo ""
echo "Backup complete: $BACKUP_DEST"
echo ""
cat "$BACKUP_DEST/manifest.txt"
