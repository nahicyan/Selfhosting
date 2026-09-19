#!/bin/bash
set -euo pipefail
# =============================================================================
# Plane MinIO migration - step 2 of 3: SAVE THE WORKING IMAGE
# =============================================================================
# The MinIO image this server runs is no longer available from Docker Hub, and
# MinIO's repository is archived. If it is ever lost (a server rebuild, `docker
# image prune -a` while the container is down) it cannot be pulled again. This
# saves the exact image the running container uses:
#
#   1. a local tag  plane-minio-rollback:<version>  on the same image, so nothing
#      that re-points minio/minio:latest can take it away, and
#   2. a gzip'd `docker save` of it, kept OUTSIDE the backup snapshots:
#        <backup-root>/plane-minio-image/<domain>/minio-<version>-<time>.tar.gz
#      (not under <backup-root>/plane/<domain>/: plane-docker-backup.sh prunes and
#      plane-docker-restore.sh lists every folder there as a snapshot.)
#
# Restore it on any host with:   gunzip -c <file> | docker load
# Changes nothing about the running stack. Step 3 uses the rollback tag as its
# undo. Background: README.md in this folder.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

echo ""
echo "=====> Plane MinIO migration - 2/3 save the working image"
echo "========================================"
require_docker
command -v gzip >/dev/null 2>&1 || _die "gzip is required."

# ── 1. Select the instance and the destination ──────────────────────────────
select_instance
echo ""
ask_backup_root
[ -d "$BACKUP_ROOT" ] || _die "'$BACKUP_ROOT' not found."
[ -w "$BACKUP_ROOT" ] || _die "'$BACKUP_ROOT' is not writable by $(id -un)."

# ── 2. Identify the running image ───────────────────────────────────────────
CID="$(minio_cid || true)"
[ -n "$CID" ] || _die "the plane-minio container is not running for project $PROJECT."
IMAGE_REF="$(minio_image_ref "$CID")"
IMAGE_ID="$(minio_image_id "$CID")"
VERSION="$(minio_version "$CID" || true)"
[ -n "$VERSION" ] || _die "could not read the MinIO version from the running container; refusing to guess."
TAG="$ROLLBACK_REPO:$(safe_tag "$VERSION")"

DEST_DIR="$BACKUP_ROOT/plane-minio-image/$DOMAIN"
STAMP="$(date +"%Y%m%d-%H%M%S")"
OUT="$DEST_DIR/minio-$(safe_tag "$VERSION")-$STAMP.tar.gz"

echo ""
echo "Instance        : $DOMAIN ($PROJECT)"
echo "Running image   : $IMAGE_REF"
echo "Image id        : ${IMAGE_ID#sha256:}" | cut -c1-58
echo "MinIO version   : $VERSION"
echo "Rollback tag    : $TAG"
echo "Archive         : $OUT"

# Already saved? An .info file next to an archive records the image id it holds.
if [ -d "$DEST_DIR" ] && grep -qsl "^Image id *: ${IMAGE_ID#sha256:}" "$DEST_DIR"/*.info 2>/dev/null; then
  echo ""
  echo "This exact image is already saved in $DEST_DIR:"
  grep -l "^Image id *: ${IMAGE_ID#sha256:}" "$DEST_DIR"/*.info | sed 's/\.info$/.tar.gz/' | sed 's/^/  /'
  docker tag "$IMAGE_ID" "$TAG"
  echo "Rollback tag $TAG is in place. Nothing more to do."
  exit 0
fi

echo ""
read -rp "Save it now? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── 3. Tag and save ─────────────────────────────────────────────────────────
mkdir -p "$DEST_DIR"
chmod 700 "$BACKUP_ROOT/plane-minio-image" "$DEST_DIR"

echo ""
echo "=== Tagging the running image as $TAG ==="
docker tag "$IMAGE_ID" "$TAG"

echo "=== Saving (this can take a minute) ==="
TMP="$OUT.partial"
trap 'rm -f "$TMP"' EXIT
docker save "$TAG" | gzip > "$TMP"

echo "=== Verifying the archive ==="
gzip -t "$TMP" || _die "the archive failed its integrity check; nothing was kept."
gunzip -c "$TMP" | tar tf - | grep -q 'manifest.json' || _die "the archive has no image manifest; nothing was kept."
mv "$TMP" "$OUT"
trap - EXIT
chmod 600 "$OUT"

{
  echo "Plane MinIO image, saved by migration/02-save-minio-image.sh"
  echo "Created         : $(date -Iseconds)"
  echo "Domain          : $DOMAIN"
  echo "Image reference : $IMAGE_REF"
  echo "Image id        : ${IMAGE_ID#sha256:}"
  echo "MinIO version   : $VERSION"
  echo "Rollback tag    : $TAG"
  echo "Restore with    : gunzip -c $(basename "$OUT") | docker load"
} > "${OUT%.tar.gz}.info"
chmod 600 "${OUT%.tar.gz}.info"

echo ""
echo "Saved: $OUT ($(du -h "$OUT" | cut -f1))"
echo ""
echo "Copy $BACKUP_ROOT/plane-minio-image/ off the server with your backups."
echo "Next: ./03-pin-minio-image.sh"
echo ""
