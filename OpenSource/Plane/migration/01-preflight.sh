#!/bin/bash
set -euo pipefail
# =============================================================================
# Plane MinIO migration - step 1 of 3: PREFLIGHT (read-only)
# =============================================================================
# Changes nothing. Reports what this instance runs and whether it is safe to
# switch MinIO to the image Plane's current release names (lib.sh, TARGET_IMAGE).
# Run it first, on the server, and read the verdict before anything else. Why this
# exists, and the whole background: README.md in this folder.
#
# What it reads: the compose project's containers, the MinIO container's image
# and `minio --version` (or `silo --version`), the compose file, the registries
# (manifest lookups, no pull), which MinIO image Plane's latest release names (from
# GitHub, best effort), the newest backup snapshot, and an object count/size listing
# of Plane's bucket through Plane's own S3 client. It writes nothing and restarts
# nothing.
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
echo "Compose says     : ${COMPOSE_IMAGES[*]:-(no MinIO image line found)}"

# ── 3. Where can the image be pulled from? ──────────────────────────────────
echo ""
echo "================== REGISTRIES ===================="
GONE_ANSWERED=""
for ref in minio/minio:latest quay.io/minio/minio:latest; do
  if registry_pullable "$ref"; then
    GONE_ANSWERED="$GONE_ANSWERED $ref"
    printf '%-28s : pullable (restored, or this host has a mirror)\n' "$ref"
  else
    printf '%-28s : DENIED / unreachable  (expected: MinIO removed it)\n' "$ref"
  fi
done
if registry_pullable "$TARGET_IMAGE"; then
  TARGET_PULL="pullable"
  echo "Target  $TARGET_IMAGE : pullable"
else
  TARGET_PULL="NOT pullable"
  echo "Target  $TARGET_IMAGE : NOT pullable from this host"
fi

# What Plane's latest release names for plane-minio, so a newer choice than the
# target is visible (best effort: needs curl and GitHub).
PLANE_TAG=""; PLANE_IMAGE=""
if command -v curl >/dev/null 2>&1; then
  PLANE_TAG="$(curl -fsSL --max-time 15 "https://api.github.com/repos/makeplane/plane/releases/latest" 2>/dev/null \
    | grep -o '"tag_name": *"[^"]*"' | sed -n '1p' | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  if [ -n "$PLANE_TAG" ]; then
    PLANE_IMAGE="$(curl -fsSL --max-time 15 "https://github.com/makeplane/plane/releases/download/$PLANE_TAG/docker-compose.yml" 2>/dev/null \
      | awk '/^  plane-minio:/ { f = 1; next } f && /^[ \t]*image:/ { sub(/^[ \t]*image:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' || true)"
  fi
fi
echo "Plane ${PLANE_TAG:-release (unknown)} names : ${PLANE_IMAGE:-could not be read}"

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
KIND="none"
[ "${#COMPOSE_IMAGES[@]}" -eq 0 ] || KIND="$(image_kind "${COMPOSE_IMAGES[0]}")"

# Where the running release stands against the target's (its RELEASE tag).
ORDER="unknown"
if [ -n "$VERSION" ] && [[ "$PINNED_TAG" == RELEASE.* ]]; then
  if [ "$VERSION" = "$PINNED_TAG" ]; then ORDER="same"
  elif release_le "$VERSION" "$PINNED_TAG"; then ORDER="older"
  else ORDER="newer"; fi
fi

echo ""
echo "===================== VERDICT ===================="
case "$KIND" in
  target)
    echo "Already on $TARGET_IMAGE. Nothing to do."
    exit 0 ;;
  plane)
    echo "The compose file names ${COMPOSE_IMAGES[0]}, an image from Plane's releases."
    echo "Nothing to do here: Plane's upgrades change this line from now on (../README.md, 'Upgrading')."
    exit 0 ;;
  none)
    echo "The compose file has no MinIO image line this migration recognises. It was changed by"
    echo "hand: read README.md ('Notes for LLMs') before touching it."
    exit 0 ;;
  other)
    echo "The compose file names an image this migration does not recognise:"
    echo "  ${COMPOSE_IMAGES[*]}"
    echo "Do not run step 3; read README.md first."
    exit 0 ;;
  gone)
    echo "Compose names ${COMPOSE_IMAGES[0]}, which MinIO no longer serves. The running"
    echo "container is unaffected, but anything that pulls ('docker compose pull', an upgrade,"
    echo "a new server) will fail." ;;
  local)
    echo "Compose names ${COMPOSE_IMAGES[0]}, the copy step 2 saved (an earlier step 3 pinned"
    echo "it). It works here but cannot be pulled on any other host." ;;
esac
echo ""
case "$ORDER" in
  same)
    echo "MinIO version    : SAME. The running MinIO ($VERSION) is the release the target carries,"
    echo "                   so switching changes where the image comes from, not the software." ;;
  older)
    echo "MinIO version    : UPGRADE. Running $VERSION; the target is $PINNED_TAG, a newer release"
    echo "                   of the same server. That is the change Plane's own upgrade makes: the fork"
    echo "                   keeps MinIO's on-disk format (tested on a copy, see README.md). Safe to"
    echo "                   continue once a backup exists. Going back to the old image afterwards is"
    echo "                   not guaranteed; the backup and step 2's copy are the way back." ;;
  newer)
    echo "MinIO version    : NEWER THAN THE TARGET. Running $VERSION, but the target is $PINNED_TAG."
    echo "                   Do NOT switch to it: an older MinIO opening data written by a newer one"
    echo "                   can fail. Step 3 will offer only your own saved image; or choose a target"
    echo "                   at least as new with MINIO_TARGET_IMAGE (README.md)." ;;
  *)
    echo "MinIO version    : UNKNOWN (could not read 'minio --version' or 'silo --version' in the"
    echo "                   container, or the target's tag is not a RELEASE.<date>). Investigate"
    echo "                   before step 3." ;;
esac
[ -z "$GONE_ANSWERED" ] || echo "Note:$GONE_ANSWERED answered this time; recheck README.md, the situation may have changed."
[ "$TARGET_PULL" = "pullable" ] || echo "Warning: the target is not pullable from this host (network, proxy or a wrong tag)."
if [ -n "$PLANE_IMAGE" ] && [ "$PLANE_IMAGE" != "$TARGET_IMAGE" ]; then
  echo "Note: Plane's latest release ($PLANE_TAG) names $PLANE_IMAGE, not this target."
  echo "      To follow it instead: MINIO_TARGET_IMAGE=$PLANE_IMAGE before steps 1 and 3 (README.md)."
fi
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
