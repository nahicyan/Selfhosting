#!/bin/bash
set -euo pipefail
# =============================================================================
# Plane MinIO migration - step 1 of 3: PREFLIGHT (read-only)
# =============================================================================
# Changes nothing. Reports what this instance runs and whether it is safe to pin
# MinIO to the quay.io image Plane's upstream fix uses. Run it first, on the
# server, and read the verdict before anything else. Why this exists, and the
# whole background: README.md in this folder.
#
# What it reads: the compose project's containers, the MinIO container's image
# and `minio --version`, the compose file, the registries (manifest lookups, no
# pull), the newest backup snapshot, and an object count/size listing of Plane's
# bucket through Plane's own S3 client. It writes nothing and restarts nothing.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

echo ""
echo "=====> Plane MinIO migration - 1/3 preflight (read-only)"
echo "========================================"
require_docker

# ── 1. Select the instance ──────────────────────────────────────────────────
select_instance
echo ""
ask_backup_root

# ── 2. What is running ──────────────────────────────────────────────────────
USE_MINIO="$(_env_get "$ENV_FILE" USE_MINIO)"; USE_MINIO="${USE_MINIO:-1}"
TOTAL="$(dc ps -aq 2>/dev/null | grep -c . || true)"
RUNNING="$(dc ps -q 2>/dev/null | grep -c . || true)"

echo ""
echo "==================== INSTANCE ===================="
echo "Domain           : $DOMAIN"
echo "Install dir      : $PROJECT_DIR"
echo "Compose project  : $PROJECT"
echo "Plane release    : $(_env_get "$ENV_FILE" APP_RELEASE)"
echo "USE_MINIO        : $USE_MINIO"
echo "Containers       : $RUNNING running of $TOTAL  (the migrator is a one-shot container and exits by design)"

if [ "$USE_MINIO" = "0" ]; then
  echo ""
  echo "This instance uses external S3 (USE_MINIO=0): the bundled MinIO is not in use and"
  echo "nothing here applies. Nothing to do."
  exit 0
fi

CID="$(minio_cid || true)"
[ -n "$CID" ] || _die "the plane-minio container is not running for project $PROJECT. Start the stack first."

IMAGE_REF="$(minio_image_ref "$CID")"
IMAGE_ID="$(minio_image_id "$CID")"
VERSION="$(minio_version "$CID" || true)"
mapfile -t COMPOSE_IMAGES < <(compose_minio_images)

echo ""
echo "===================== MINIO ======================"
echo "Container        : $(docker inspect -f '{{.Name}}' "$CID" | sed 's#^/##')"
echo "Image reference  : $IMAGE_REF   (what the container was created from)"
echo "Image id         : ${IMAGE_ID#sha256:}" | cut -c1-60
echo "Running version  : ${VERSION:-unknown}"
echo "Compose says     : ${COMPOSE_IMAGES[*]:-(no minio/minio image line found)}"

# ── 3. Where can the image be pulled from? ──────────────────────────────────
echo ""
echo "================== REGISTRIES ===================="
if registry_pullable "minio/minio:latest"; then
  HUB="pullable"
  echo "Docker Hub  minio/minio:latest        : pullable (the org was restored, or this host has a mirror)"
else
  HUB="DENIED"
  echo "Docker Hub  minio/minio:latest        : DENIED / unreachable  (expected: MinIO removed it)"
fi
if registry_pullable "$TARGET_IMAGE"; then
  QUAY="pullable"
  echo "Target      $TARGET_IMAGE : pullable"
else
  QUAY="NOT pullable"
  echo "Target      $TARGET_IMAGE : NOT pullable from this host"
fi

# ── 4. Data and backup ──────────────────────────────────────────────────────
STATS="$(s3_stats || true)"
AGE="$(newest_backup_age_hours "$BACKUP_ROOT" || true)"
echo ""
echo "================= DATA AND BACKUP ================"
if [ -n "$STATS" ]; then
  echo "Bucket contents  : ${STATS%%:*} objects, ${STATS##*:} bytes (listed through Plane's S3 client)"
else
  echo "Bucket contents  : could not be listed (is the api container running?)"
fi
if [ -n "$AGE" ]; then
  echo "Newest backup    : $AGE hour(s) old  (under $BACKUP_ROOT/plane/$DOMAIN)"
else
  echo "Newest backup    : none found under $BACKUP_ROOT/plane/$DOMAIN"
fi

# ── 5. Verdict ──────────────────────────────────────────────────────────────
STATE="other"
if [ "${#COMPOSE_IMAGES[@]}" -eq 0 ]; then
  STATE="none"
elif [ "${COMPOSE_IMAGES[0]}" = "$TARGET_IMAGE" ]; then
  STATE="pinned"
elif [[ "${COMPOSE_IMAGES[0]}" == minio/minio* || "${COMPOSE_IMAGES[0]}" == docker.io/minio/minio* ]]; then
  STATE="dockerhub"
fi

MATCH="unknown"
if [ -n "$VERSION" ]; then
  if [ "$VERSION" = "$PINNED_TAG" ]; then MATCH="match"; else MATCH="mismatch"; fi
fi

echo ""
echo "===================== VERDICT ===================="
case "$STATE" in
  pinned)
    echo "Already pinned to $TARGET_IMAGE. Nothing to do."
    exit 0 ;;
  none)
    echo "The compose file has no minio/minio image line. It was changed by hand: read"
    echo "README.md ('Notes for LLMs') before touching it."
    exit 0 ;;
  other)
    echo "The compose file names an image this migration does not recognise:"
    echo "  ${COMPOSE_IMAGES[*]}"
    echo "Do not run step 3; read README.md first."
    exit 0 ;;
esac

echo "Compose still names Docker Hub's minio/minio. The running container is unaffected,"
echo "but anything that pulls ('docker compose pull', a rebuild, a new server) will fail."
echo ""
case "$MATCH" in
  match)
    echo "MinIO version    : MATCH. The running MinIO ($VERSION) is the release the pin points at,"
    echo "                   so switching the image reference changes where it is pulled from, not"
    echo "                   the software. Safe to continue." ;;
  mismatch)
    echo "MinIO version    : MISMATCH. Running $VERSION, but the pin is $PINNED_TAG."
    echo "                   Do NOT pin to the quay image: an older MinIO opening data written by a"
    echo "                   newer one can fail. Step 2 (save the image) is still worth doing; step 3"
    echo "                   will then offer to pin to your own saved image instead." ;;
  *)
    echo "MinIO version    : UNKNOWN (could not run 'minio --version' in the container). Investigate"
    echo "                   before step 3." ;;
esac
[ "$HUB" = "DENIED" ] || echo "Note: Docker Hub answered this time; recheck README.md, the situation may have changed."
[ "$QUAY" = "pullable" ] || echo "Warning: the quay target is not pullable from this host (network, proxy or a wrong tag)."
echo ""
echo "Next:"
if [ -z "$AGE" ] || [ "$AGE" -ge "$FRESH_BACKUP_HOURS" ]; then
  echo "  0. Take a fresh backup:  ../scripts/plane-docker-backup.sh   (none newer than $FRESH_BACKUP_HOURS h found)"
else
  echo "  0. Backup: a snapshot from $AGE hour(s) ago exists. Take another if data changed since."
fi
echo "  2. ./02-save-minio-image.sh    (keeps a copy of the image that works now)"
echo "  3. ./03-pin-minio-image.sh     (switches the compose file; rolls itself back on failure)"
echo ""
