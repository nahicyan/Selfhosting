#!/bin/bash
set -euo pipefail
# =============================================================================
# Plane MinIO migration - step 3 of 3: PIN THE MINIO IMAGE
# =============================================================================
# Points the compose file's plane-minio image at a source that still exists, so
# `docker compose pull`, rebuilds and new servers stop depending on the image
# MinIO removed from Docker Hub. Background and the full analysis: README.md in
# this folder.
#
# Two targets:
#   quay    quay.io/minio/minio:<pinned tag> - the reference Plane merged
#           upstream (makeplane/plane #9829). Offered ONLY when the running MinIO
#           is that exact release, so this changes where the image is pulled
#           from, not the software.
#   local   plane-minio-rollback:<version> - the copy step 2 saved of the image
#           that runs now. Used when the versions differ (an older MinIO opening
#           data written by a newer one can fail). It cannot be pulled: carry the
#           step-2 archive to any new server and `docker load` it there.
#
# What it does, in this order, and where it can stop safely:
#   1. checks (running MinIO, saved rollback image, fresh backup) .... changes nothing
#   2. records the bucket's object count and bytes ..................... changes nothing
#   3. copies the compose file, pulls the target image ................. changes nothing yet
#   4. edits exactly ONE line of the compose file (the plane-minio image)
#   5. recreates ONLY the plane-minio container (its data volume is untouched;
#      uploads fail for a few seconds)
#   6. waits for MinIO's health endpoint, then requires the same object count and
#      bytes as before, and the same MinIO version
# If step 4-6 fails in any way it restores the compose file and the old container
# by itself, and tells you what state it ended in.
#
# Testing/advanced: MINIO_TARGET_TAG=<tag> or MINIO_TARGET_IMAGE=<full ref>
# override the target (see lib.sh). With MINIO_TARGET_IMAGE the version check is
# skipped: you are on your own.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

echo ""
echo "=====> Plane MinIO migration - 3/3 pin the MinIO image"
echo "========================================"
require_docker

# ── 1. Select the instance ──────────────────────────────────────────────────
select_instance
echo ""
ask_backup_root

USE_MINIO="$(_env_get "$ENV_FILE" USE_MINIO)"
[ "${USE_MINIO:-1}" != "0" ] || _die "this instance uses external S3 (USE_MINIO=0); there is no bundled MinIO to pin."

# ── 2. Current state ────────────────────────────────────────────────────────
CID="$(minio_cid || true)"
[ -n "$CID" ] || _die "the plane-minio container is not running for project $PROJECT. Start the stack first."
VERSION="$(minio_version "$CID" || true)"
[ -n "$VERSION" ] || _die "could not read the MinIO version from the running container; refusing to guess."
ROLLBACK_TAG="$ROLLBACK_REPO:$(safe_tag "$VERSION")"

mapfile -t COMPOSE_IMAGES < <(compose_minio_images)
[ "${#COMPOSE_IMAGES[@]}" -eq 1 ] || _die "expected exactly one plane-minio image line in $COMPOSE_FILE, found ${#COMPOSE_IMAGES[@]}. It was edited by hand: see README.md ('Notes for LLMs') before changing it."
OLD_IMAGE="${COMPOSE_IMAGES[0]}"

if [ "$OLD_IMAGE" = "$TARGET_IMAGE" ] || [[ "$OLD_IMAGE" == "$ROLLBACK_REPO":* ]]; then
  echo ""
  echo "Already pinned: the compose file names $OLD_IMAGE. Nothing to do."
  exit 0
fi
if ! [[ "$OLD_IMAGE" == minio/minio* || "$OLD_IMAGE" == docker.io/minio/minio* ]]; then
  _die "the compose file names '$OLD_IMAGE', which this step does not recognise. See README.md before changing it."
fi
docker image inspect "$OLD_IMAGE" >/dev/null 2>&1 || _die "the image '$OLD_IMAGE' is not present locally (it could not be pulled again). Stop and read README.md."

# ── 3. The rollback image must exist (step 2) ───────────────────────────────
docker image inspect "$ROLLBACK_TAG" >/dev/null 2>&1 \
  || _die "no saved copy of the running image ($ROLLBACK_TAG). Run ./02-save-minio-image.sh first: it is this step's undo."

# ── 4. Choose the target ────────────────────────────────────────────────────
echo ""
echo "Compose names   : $OLD_IMAGE"
echo "Running MinIO   : $VERSION"
TARGET=""
if [ -n "${MINIO_TARGET_IMAGE:-}" ]; then
  echo "WARNING: MINIO_TARGET_IMAGE is set - the version check is skipped."
  TARGET="$TARGET_IMAGE"
elif [ "$VERSION" = "$PINNED_TAG" ]; then
  echo "Version check   : MATCH with the quay pin ($PINNED_TAG)."
  echo ""
  echo "Pin to:"
  echo "  1) $TARGET_IMAGE   (recommended: same software, a source that exists)"
  echo "  2) $ROLLBACK_TAG   (your saved copy; cannot be pulled on a new server)"
  read -rp "Select [1/2]: " CHOICE
  case "$CHOICE" in 1) TARGET="$TARGET_IMAGE" ;; 2) TARGET="$ROLLBACK_TAG" ;; *) _die "Invalid selection." ;; esac
else
  echo "Version check   : MISMATCH - the pin is $PINNED_TAG. Pinning to quay would change the MinIO"
  echo "                  version, and an older MinIO opening newer data can fail. Refusing that."
  echo ""
  echo "Pin to:"
  echo "  1) $ROLLBACK_TAG   (your saved copy of the image that runs now)"
  echo "  q) abort"
  read -rp "Select [1/q]: " CHOICE
  case "$CHOICE" in 1) TARGET="$ROLLBACK_TAG" ;; *) echo "Aborted."; exit 0 ;; esac
fi

# ── 5. Backup, baseline, confirmation ───────────────────────────────────────
AGE="$(newest_backup_age_hours "$BACKUP_ROOT" || true)"
echo ""
if [ -n "$AGE" ] && [ "$AGE" -lt "$FRESH_BACKUP_HOURS" ]; then
  echo "Backup          : newest snapshot is $AGE hour(s) old."
else
  echo "WARNING: no backup newer than $FRESH_BACKUP_HOURS hours under $BACKUP_ROOT/plane/$DOMAIN."
  echo "         Take one first:  ../scripts/plane-docker-backup.sh"
  read -rp "Continue WITHOUT a fresh backup? [y/N]: " ANS_NOBACKUP
  [[ "$ANS_NOBACKUP" =~ ^[Yy]$ ]] || { echo "Aborted - nothing was changed."; exit 1; }
fi

BEFORE="$(s3_stats || true)"
[ -n "$BEFORE" ] || _die "could not list Plane's bucket (is the api container running?): without a before/after comparison this step cannot verify itself."

echo ""
echo "==================== PIN SUMMARY ===================="
echo "Instance        : $DOMAIN ($PROJECT)"
echo "Compose file    : $COMPOSE_FILE"
echo "Change          : image: $OLD_IMAGE"
echo "              -> image: $TARGET"
echo "Recreated       : plane-minio only (its data volume is not touched)"
echo "Bucket now      : ${BEFORE%%:*} objects, ${BEFORE##*:} bytes (must be identical afterwards)"
echo "Downtime        : uploads and downloads of files fail for a few seconds"
echo "Undo            : automatic on failure; by hand: copy the saved compose file back"
echo "====================================================="
echo ""
read -rp "Type 'pin' to continue: " CONFIRM
[ "$CONFIRM" = "pin" ] || { echo "Aborted."; exit 0; }

# ── 6. Prepare: nothing in the instance has changed yet ─────────────────────
STAMP="$(date +"%Y%m%d-%H%M%S")"
COPY="$COMPOSE_FILE.pre-minio-pin-$STAMP"
cp -p "$COMPOSE_FILE" "$COPY"
echo ""
echo "=== Saved the compose file to $COPY ==="

if [ "$TARGET" != "$ROLLBACK_TAG" ]; then
  echo "=== Pulling $TARGET ==="
  docker pull "$TARGET"
fi

# ── 7. Change, with automatic rollback from here on ─────────────────────────
ARMED=false

fail() { echo "FAILED: $*" >&2; false; }

rollback() {
  echo ""
  echo "=== ROLLING BACK to the previous compose file and MinIO container ==="
  set +e
  cp -p "$COPY" "$COMPOSE_FILE"
  dc up -d --no-deps plane-minio
  local ok=false now="" i
  for i in $(seq 1 45); do
    if minio_healthy; then ok=true; break; fi
    sleep 2
  done
  now="$(s3_stats)"
  if $ok && [ "$now" = "$BEFORE" ]; then
    echo "Rolled back: MinIO is healthy again and the bucket is as before ($now = objects:bytes)."
    echo "The compose file is byte-identical to the one saved at $COPY."
  else
    echo "ROLLBACK INCOMPLETE - MinIO healthy: $ok, bucket now: ${now:-unreadable}, before: $BEFORE."
    echo "Restore by hand:  cp -p $COPY $COMPOSE_FILE  &&  docker compose -f $COMPOSE_FILENAME --env-file=plane.env --project-name $PROJECT up -d --no-deps plane-minio"
    echo "The image that worked is saved as $ROLLBACK_TAG (and by step 2 as an archive)."
  fi
  set -e
}

on_error() {
  local code=$?
  trap - ERR
  echo ""
  echo "Step failed (exit $code)."
  if $ARMED; then rollback; else echo "Nothing in the instance was changed."; fi
  exit "$code"
}
set -o errtrace
trap on_error ERR

echo "=== Editing the plane-minio image line ==="
# Replace only a line whose image value is exactly the old one, and demand
# exactly one such line: written to a temp file first so a failure leaves the
# original untouched.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
OLD="$OLD_IMAGE" NEW="$TARGET" awk '
  match($0, /^[ \t]*image:[ \t]*/) {
    pre = substr($0, 1, RLENGTH); v = substr($0, RLENGTH + 1); sub(/[ \t]+$/, "", v)
    if (v == ENVIRON["OLD"]) { print pre ENVIRON["NEW"]; n++; next }
  }
  { print }
  END { if (n != 1) exit 3 }' "$COMPOSE_FILE" > "$TMP" || fail "expected to change exactly one image line"
ARMED=true   # from the moment the compose file is rewritten, a failure rolls back
cat "$TMP" > "$COMPOSE_FILE"
CHANGED="$(diff "$COPY" "$COMPOSE_FILE" | grep -c '^>' || true)"
[ "$CHANGED" = "1" ] || fail "the compose file changed $CHANGED lines instead of 1"
dc config -q || fail "the edited compose file is not valid"

echo "=== Recreating plane-minio ==="
dc up -d --no-deps plane-minio

echo -n "=== Waiting for MinIO"
HEALTHY=false
for _ in $(seq 1 45); do
  if minio_healthy; then HEALTHY=true; break; fi
  echo -n "."
  sleep 2
done
echo ""
$HEALTHY || fail "MinIO did not become healthy within 90 seconds"

echo "=== Verifying ==="
NEW_CID="$(minio_cid || true)"
[ -n "$NEW_CID" ] || fail "the plane-minio container is missing after the change"
NEW_VERSION="$(minio_version "$NEW_CID" || true)"
[ "$NEW_VERSION" = "$VERSION" ] || fail "MinIO reports '${NEW_VERSION:-nothing}', expected $VERSION"
AFTER="$(s3_stats || true)"
[ "$AFTER" = "$BEFORE" ] || fail "bucket contents changed: before $BEFORE, after ${AFTER:-unreadable} (objects:bytes)"
echo "MinIO           : $NEW_VERSION, healthy, image $(minio_image_ref "$NEW_CID")"
echo "Bucket          : ${AFTER%%:*} objects, ${AFTER##*:} bytes - identical to before"

PORT="$(_env_get "$ENV_FILE" LISTEN_HTTP_PORT)"
if [ -n "$PORT" ] && command -v curl >/dev/null 2>&1; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/api/instances/" 2>/dev/null || echo 000)"
  echo "Plane API       : HTTP $CODE through the proxy on 127.0.0.1:$PORT"
fi

ARMED=false
trap - ERR
rm -f "$TMP"; trap - EXIT

echo ""
echo "Done. The compose file now names $TARGET."
if [ "$TARGET" != "$ROLLBACK_TAG" ]; then
  echo "'docker compose pull' no longer depends on Docker Hub for MinIO."
else
  echo "MinIO is pinned to your own saved image, which no registry has: 'docker compose pull' now"
  echo "fails for that one service (denied). Use 'docker compose pull --ignore-pull-failures' or name"
  echo "the other services. On a new server run 'gunzip -c <the step-2 archive> | docker load' first."
fi
echo "Kept for undo: $COPY  and the image tag $ROLLBACK_TAG (delete once you are confident)."
echo ""
