#!/bin/bash
set -euo pipefail
# =============================================================================
# Plane Docker Restore Script v1.0
# =============================================================================
# Restores from a snapshot created by plane-docker-backup.sh:
#   <backup-root>/plane/<domain>/<date-n-time>/postgres/plane.sql.gz
#   <backup-root>/plane/<domain>/<date-n-time>/uploads/uploads.tar.gz
#   <backup-root>/plane/<domain>/<date-n-time>/config/plane.env
#   <backup-root>/plane/<domain>/<date-n-time>/config/docker-compose.yaml
#
# Restore options:
#   1) Full recovery - configuration + database + uploads (new server, or rolling
#                      the whole instance back)
#   2) Database only - the Plane database, e.g. after a bad upgrade or deletion
#   3) Uploads only  - attachments and images (the MinIO data volume)
#   4) Configuration - plane.env only
#
# The database is restored the way Plane's docs describe for non-volume setups
# ("Other deployment methods"): the dump is loaded with psql into an empty
# database while Plane's API and workers are stopped. Uploads are unpacked into
# the MinIO volume while MinIO is stopped.
#
# docker-compose.yaml is deliberately NOT restored. In Plane it is a per-release
# file the installer downloads (plus the loopback-port patch) - all the state is in
# plane.env, which is what Plane's docs tell you to keep. Restoring an old compose
# file could bring back references that no longer work (e.g. the retired
# minio/minio Docker Hub image). The snapshot keeps a copy, and this script says
# so when it differs from the live one.
#
# To recover onto a NEW server: run plane-docker-install.sh first (so the
# instance directory, images and host Nginx exist) with the SAME domain, then
# choose "Full recovery" here.
# =============================================================================

# =============================================================================
# MINIO SITUATION - notes for maintainers and LLMs (written 2026-09-19)
# =============================================================================
# Full analysis, evidence and runbook: ../migration/README.md. For THIS script:
#
# Background. Plane's bundled object storage is MinIO. MinIO declared its repository
# unmaintained and removed its Docker Hub organisation (`docker pull minio/minio` is
# denied). Plane has published neither a replacement nor a migration for existing
# installs (issue makeplane/plane #8774: open, no reply from the Plane team; the image
# fix in #9829 is on the preview branch only, in no release). The owner decided
# (2026-09-19) to KEEP bundled MinIO for now, pinned to a source that still exists.
#
# What this script must keep doing
#   - It does NOT restore docker-compose.yaml (see the header). This matters for MinIO
#     too: an old snapshot's compose file names `minio/minio:latest`, which can no
#     longer be pulled. Restoring it over a working (pinned) one would break the next
#     pull or recreate. Keep it that way unless the owner decides otherwise.
#   - Step 11 empties the MinIO data volume and unpacks uploads.tar.gz into it. Only
#     restore into a MinIO of the same or a newer release than the one that wrote the
#     snapshot. The manifest does not record MinIO's release yet (see the backup
#     script's notes): judge by the snapshot's date and ../migration/README.md.
#   - NEW SERVER: Full recovery needs the instance installed first, and
#     plane-docker-install.sh currently stops at its image pull (see its MINIO
#     SITUATION note). A host with no working MinIO image needs
#     `gunzip -c <archive> | docker load` (the archive that
#     ../migration/02-save-minio-image.sh wrote to
#     <backup-root>/plane-minio-image/<domain>/) or the quay pin BEFORE restoring.
#   - Step 3 treats every folder under <backup-root>/plane/<domain>/ as a snapshot:
#     never keep other files or folders there.
#
# If the situation changes
#   - Uploads move to external S3 (USE_MINIO=0 in plane.env): new snapshots have no
#     uploads. Restoring an old snapshot's uploads would fill a MinIO that is no longer
#     used. Not checked today: add a refusal or a warning when the target has
#     USE_MINIO=0.
#   - Plane replaces MinIO with another S3 server: step 11 (empty the volume, untar)
#     must become an S3 sync that matches the backup script's replacement. Keep the
#     safety copy before it.
#   - Plane ships a release that fixes the image: nothing here changes; the restore
#     still must not overwrite the compose file.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_PLANE_PATH="/var/www/docker/plane"
COMPOSE_FILENAME="docker-compose.yaml"
HELPER_IMAGE="busybox"

echo ""
echo "=====> Plane Restore"
echo "========================================"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Error: the Docker Compose plugin ('docker compose') is required."; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "Error: gzip is required."; exit 1; }

_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

# _env_get <file> <key> - last KEY=value in a dotenv file, surrounding quotes removed.
_env_get() {
  local v
  v="$(grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  v="${v#[\'\"]}"; v="${v%[\'\"]}"
  printf '%s' "$v"
}

# ── 1. Choose backup base directory ─────────────────────────────────────────
echo "Choose the directory where your backups are located:"
echo "  1) Default: $DEFAULT_BACKUP_ROOT"
echo "  2) Custom path"
read -rp "Select [1/2]: " BACKUP_BASE_CHOICE

if [ "$BACKUP_BASE_CHOICE" = "2" ]; then
  read -rep "Enter custom backup base path: " BACKUP_ROOT
  BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
else
  BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
fi
BACKUP_ROOT="${BACKUP_ROOT%/}"

PLANE_BACKUPS_DIR="$BACKUP_ROOT/plane"
[ -d "$PLANE_BACKUPS_DIR" ] || { echo "Error: '$PLANE_BACKUPS_DIR' not found."; exit 1; }

# ── 2. Select backup domain ─────────────────────────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$PLANE_BACKUPS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || { echo "No domain backup folders found in '$PLANE_BACKUPS_DIR'."; exit 1; }

if [ ${#DOMAIN_DIRS[@]} -eq 1 ]; then
  DOMAIN_DIR="${DOMAIN_DIRS[0]}"
  echo "Using backup folder: $(basename "$DOMAIN_DIR")"
else
  echo "Found backup folders:"
  for i in "${!DOMAIN_DIRS[@]}"; do
    echo "  $((i+1))) $(basename "${DOMAIN_DIRS[$i]}")"
  done
  echo ""
  read -rp "Select domain number: " DOM_NUM
  if ! [[ "$DOM_NUM" =~ ^[0-9]+$ ]] || [ "$DOM_NUM" -lt 1 ] || [ "$DOM_NUM" -gt "${#DOMAIN_DIRS[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi
  DOMAIN_DIR="${DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

# ── 3. List available snapshots ─────────────────────────────────────────────
mapfile -t SNAPSHOTS < <(find "$DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)
[ ${#SNAPSHOTS[@]} -gt 0 ] || { echo "No backup snapshots found in '$(basename "$DOMAIN_DIR")'."; exit 1; }

echo ""
printf "  %-4s %-33s %-10s %-10s %-8s\n" "#" "Date" "Database" "Uploads" "Config"
printf "  %-4s %-33s %-10s %-10s %-8s\n" "----" "---------------------------------" "----------" "----------" "--------"
for i in "${!SNAPSHOTS[@]}"; do
  S="${SNAPSHOTS[$i]}"
  DB_S=$([ -f "$S/postgres/plane.sql.gz" ] && du -h "$S/postgres/plane.sql.gz" | cut -f1 || echo "--")
  UP_S=$([ -f "$S/uploads/uploads.tar.gz" ] && du -h "$S/uploads/uploads.tar.gz" | cut -f1 || echo "--")
  CF_S=$([ -f "$S/config/plane.env" ] && echo "ok" || echo "--")
  printf "  %-4s %-33s %-10s %-10s %-8s\n" "$((i+1)))" "$(_nice_date "$(basename "$S")")" "$DB_S" "$UP_S" "$CF_S"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM
if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi
SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"
SNAP_DUMP="$SNAPSHOT_DIR/postgres/plane.sql.gz"
SNAP_UPLOADS="$SNAPSHOT_DIR/uploads/uploads.tar.gz"
SNAP_ENV="$SNAPSHOT_DIR/config/plane.env"
SNAP_COMPOSE="$SNAPSHOT_DIR/config/docker-compose.yaml"

HAS_DB=false;  [ -f "$SNAP_DUMP" ] && HAS_DB=true
HAS_UP=false;  [ -f "$SNAP_UPLOADS" ] && HAS_UP=true
HAS_CFG=false; [ -f "$SNAP_ENV" ] && HAS_CFG=true

# ── 4. Select the target instance ───────────────────────────────────────────
echo ""
read -rep "Plane instances base path [$DEFAULT_PLANE_PATH]: " PLANE_BASE_PATH
PLANE_BASE_PATH="${PLANE_BASE_PATH:-$DEFAULT_PLANE_PATH}"
PLANE_BASE_PATH="${PLANE_BASE_PATH/#\~/$HOME}"
[ -d "$PLANE_BASE_PATH" ] || { echo "Error: Directory '$PLANE_BASE_PATH' not found."; exit 1; }
PLANE_BASE_PATH="$(cd "$PLANE_BASE_PATH" && pwd)"

INSTANCES=()
while IFS= read -r f; do
  if [ -f "$(dirname "$f")/plane.env" ] && grep -q 'makeplane/plane-backend' "$f"; then
    INSTANCES+=("$(dirname "$f")")
  fi
done < <(find "$PLANE_BASE_PATH" -maxdepth 2 -name "$COMPOSE_FILENAME" | sort -u)
[ ${#INSTANCES[@]} -gt 0 ] || { echo "No Plane instances found in '$PLANE_BASE_PATH'. Run plane-docker-install.sh first."; exit 1; }

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
done
if [ ${#INSTANCES[@]} -eq 1 ]; then
  INST_NUM=1
else
  echo ""
  read -rp "Select instance number to restore INTO: " INST_NUM
fi
if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi
INSTALL_DIR="${INSTANCES[$((INST_NUM-1))]}"
COMPOSE_FILE="$INSTALL_DIR/$COMPOSE_FILENAME"
ENV_FILE="$INSTALL_DIR/plane.env"

DOMAIN="$(_env_get "$ENV_FILE" APP_DOMAIN)"
DOMAIN="${DOMAIN:-$(basename "$INSTALL_DIR")}"
# Same name plane-docker-install.sh gives the Compose project.
PROJECT="plane-${DOMAIN//./-}"

# Everything below runs from the instance directory, exactly like the commands
# the installer prints. Compose re-reads plane.env on every call, so a restored
# configuration is picked up by the very next command.
cd "$INSTALL_DIR"
dc() { docker compose -f "$COMPOSE_FILENAME" --env-file=plane.env --project-name "$PROJECT" "$@"; }

# vol_of <name> - the real Docker volume for a Compose volume, found by the labels
# Compose puts on it (so this does not depend on how the project name is spelled).
vol_of() {
  docker volume ls -q \
    --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.volume=$1" | sed -n '1p'
}

# ── 5. Ask what to restore ──────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "About these options:"
echo ""
echo "  Full recovery restores the configuration (plane.env with SECRET_KEY and the"
echo "  database, RabbitMQ and MinIO passwords), the database and the uploads. Use it"
echo "  on a new server or to roll the whole instance back. The configuration goes"
echo "  first, and the database volume is REMOVED and re-created, because PostgreSQL"
echo "  only reads its password when its volume is first created - a volume made by"
echo "  the installer would otherwise reject the restored password. (RabbitMQ needs no"
echo "  reset: every new container starts a fresh node with the password from"
echo "  plane.env.) The current database is dumped to a safety copy first."
echo ""
echo "  Database only replaces the Plane database with the backup. It keeps the"
echo "  instance's CURRENT configuration and password, so it suits the same install,"
echo "  not a different one. A safety copy is taken first."
echo ""
echo "  Uploads only unpacks the attachments and images into the MinIO volume,"
echo "  replacing what is there. A safety copy is taken first."
echo ""
echo "  Configuration alone restores plane.env. If the database volume was created"
echo "  with different passwords than the backup's, Plane will not be able to log in"
echo "  to it - use Full recovery instead."
echo "------------------------------------------------------------"
echo ""
echo "What do you want to restore?"
echo "  1) Full recovery (configuration + database + uploads)"
echo "  2) Database only"
echo "  3) Uploads only"
echo "  4) Configuration only"
read -rp "Select [1-4]: " ACTION

DO_DB=false; DO_UP=false; DO_CFG=false; RESET_VOLUMES=false
case "$ACTION" in
  1) DO_DB=true; DO_CFG=true; RESET_VOLUMES=true; DO_UP=$HAS_UP ;;
  2) DO_DB=true ;;
  3) DO_UP=true ;;
  4) DO_CFG=true ;;
  *) echo "Invalid selection."; exit 1 ;;
esac
if $DO_DB  && ! $HAS_DB;  then echo "Error: this snapshot has no database dump."; exit 1; fi
if $DO_UP  && ! $HAS_UP;  then echo "Error: this snapshot has no uploads archive."; exit 1; fi
if $DO_CFG && ! $HAS_CFG; then echo "Error: this snapshot has no configuration (plane.env)."; exit 1; fi

# ── Checks: nothing is stopped or changed until these pass ──────────────────
# pg_dump ends every complete dump with this line, so it also catches truncation.
if $DO_DB; then
  echo ""
  echo "Verifying the dump..."
  if ! gunzip -c "$SNAP_DUMP" | tail -n 20 | grep -q 'PostgreSQL database dump complete'; then
    echo "Error: $SNAP_DUMP is incomplete or corrupt. Nothing was changed."
    exit 1
  fi
fi
if $DO_UP; then
  echo "Verifying the uploads archive..."
  tar tzf "$SNAP_UPLOADS" >/dev/null 2>&1 || { echo "Error: $SNAP_UPLOADS is corrupt. Nothing was changed."; exit 1; }
  # Fetch the helper image now, so a missing image cannot stop the restore halfway.
  docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull "$HELPER_IMAGE" >/dev/null
fi

# The configuration carries APP_DOMAIN, WEB_URL and CORS_ALLOWED_ORIGINS. Restored
# onto another domain it would point this instance at the wrong URL.
if $DO_CFG; then
  SNAP_DOMAIN="$(_env_get "$SNAP_ENV" APP_DOMAIN)"
  if [ "$SNAP_DOMAIN" != "$DOMAIN" ]; then
    echo ""
    echo "Error: this snapshot belongs to '${SNAP_DOMAIN:-?}' but the target instance is '$DOMAIN'."
    echo "Restoring its configuration would point this instance at the wrong URL. Install with"
    echo "the snapshot's domain, or choose 'Database only' / 'Uploads only'."
    exit 1
  fi
fi

# ── 6. Summary and confirmation ─────────────────────────────────────────────
SNAP_REL="$(_env_get "$SNAP_ENV" APP_RELEASE)"
CUR_REL="$(_env_get "$ENV_FILE" APP_RELEASE)"
echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Snapshot        : $(basename "$SNAPSHOT_DIR")  (Plane ${SNAP_REL:-release unknown})"
echo "Target instance : $DOMAIN ($INSTALL_DIR)"
echo "Restoring       :"
$DO_CFG && echo "  - plane.env (restored first)"
$DO_DB  && echo "  - PostgreSQL database (dropped and re-created from the dump)"
$DO_UP  && echo "  - uploads (the MinIO volume is emptied, then filled from the archive)"
[ "$ACTION" = "1" ] && ! $HAS_UP && echo "  (this snapshot has no uploads - the current uploads stay as they are)"
echo "========================================================="
echo ""
$DO_DB  && echo "WARNING: Plane's API and workers are stopped and the current database is REPLACED. Anything created after this snapshot is lost."
$RESET_VOLUMES && echo "WARNING: the database volume is removed and re-created (a safety dump is taken first)."
$DO_UP  && echo "WARNING: MinIO is stopped and the current uploads are REPLACED by the snapshot's."
if $DO_DB && ! $DO_CFG && [ -n "$SNAP_REL" ] && [ -n "$CUR_REL" ] && [ "$SNAP_REL" != "$CUR_REL" ]; then
  if [ "$(printf '%s\n%s\n' "$SNAP_REL" "$CUR_REL" | sort -V | tail -n1)" = "$SNAP_REL" ]; then
    echo "WARNING: the snapshot is from Plane $SNAP_REL, NEWER than the $CUR_REL this instance runs. A database from a"
    echo "         newer release may not work with older Plane containers: upgrade first, or use Full recovery."
  else
    echo "NOTE: the snapshot is from Plane $SNAP_REL, older than the $CUR_REL this instance runs; the migrator brings the schema forward on start."
  fi
fi
echo ""
read -rp "Type 'restore' to continue: " CONFIRM
[ "$CONFIRM" = "restore" ] || { echo "Aborted."; exit 0; }

# ── helpers ─────────────────────────────────────────────────────────────────
# -T: no TTY, so stdin can carry the dump. exec also attaches the script's own
# stdin, which would swallow the operator's answers, so callers that pass no
# input redirect from /dev/null. -h 127.0.0.1 in every client call: Compose sets
# PGHOST=plane-db in the container, which would send psql over the network,
# where a password is required; the loopback address is trusted inside it.
db_sh() { dc exec -T plane-db sh -c "$1"; }

# PostgreSQL's official image runs a temporary socket-only server while it
# initialises a new volume, then restarts. Probing over TCP only succeeds once
# the final server is up.
db_ready() { db_sh 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' </dev/null >/dev/null 2>&1; }

wait_db() {
  echo -n "Waiting for PostgreSQL"
  for _ in $(seq 1 60); do
    if db_ready; then
      echo ""
      return 0
    fi
    echo -n "."
    sleep 2
  done
  echo ""
  echo "Error: PostgreSQL did not become ready (docker compose logs plane-db)."
  exit 1
}

STAMP=$(date +"%Y%m%d-%H%M%S")

# ── 7. Safety copy of what is about to be replaced ──────────────────────────
echo ""
echo "=== Safety copy of the current state ==="
SAFETY_DIR="$INSTALL_DIR/pre-restore-$STAMP"
mkdir -p "$SAFETY_DIR"
chmod 700 "$SAFETY_DIR"
cp "$ENV_FILE" "$SAFETY_DIR/plane.env"
cp "$COMPOSE_FILE" "$SAFETY_DIR/docker-compose.yaml"
chmod 600 "$SAFETY_DIR/plane.env" "$SAFETY_DIR/docker-compose.yaml"
echo "Current plane.env and docker-compose.yaml saved to $SAFETY_DIR"

if $DO_DB; then
  # A stopped or removed stack can still hold data in its volume, and the steps
  # below delete it, so bring the current database up (a no-op when it already
  # is) and save it. If that cannot be done, the operator decides.
  dc up -d plane-db >/dev/null 2>&1 || true
  SAFETY_OK=false
  for _ in $(seq 1 15); do
    if db_ready; then SAFETY_OK=true; break; fi
    sleep 2
  done
  if $SAFETY_OK \
    && db_sh 'pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' </dev/null \
      | gzip > "$SAFETY_DIR/plane.sql.gz"; then
    chmod 600 "$SAFETY_DIR/plane.sql.gz"
    echo "Current database saved to $SAFETY_DIR/plane.sql.gz"
  else
    rm -f "$SAFETY_DIR/plane.sql.gz"
    echo "WARNING: the current database could not be dumped (not running, or a broken volume)."
    read -rp "Continue WITHOUT a safety dump of it? [y/N]: " ANS_NODUMP
    [[ "$ANS_NODUMP" =~ ^[Yy]$ ]] || { echo "Aborted - nothing was changed."; exit 1; }
  fi
fi

if $DO_UP; then
  CUR_UPLOADS_VOL="$(vol_of uploads)"
  if [ -n "$CUR_UPLOADS_VOL" ]; then
    if docker run --rm -v "$CUR_UPLOADS_VOL":/data:ro "$HELPER_IMAGE" tar -czf - -C /data . > "$SAFETY_DIR/uploads.tar.gz"; then
      chmod 600 "$SAFETY_DIR/uploads.tar.gz"
      echo "Current uploads saved to $SAFETY_DIR/uploads.tar.gz ($(du -h "$SAFETY_DIR/uploads.tar.gz" | cut -f1))"
    else
      rm -f "$SAFETY_DIR/uploads.tar.gz"
      echo "WARNING: the current uploads could not be archived (out of disk space?)."
      read -rp "Continue WITHOUT a safety copy of them? [y/N]: " ANS_NOUP
      [[ "$ANS_NOUP" =~ ^[Yy]$ ]] || { echo "Aborted - nothing was changed."; exit 1; }
    fi
  fi
fi

# From here on the instance is being changed. If a step fails, say where things
# stand instead of leaving a bare error with Plane possibly stopped.
on_error() {
  local code=$?
  echo ""
  echo "Restore FAILED (exit $code) part-way through - Plane may be stopped."
  echo "  Safety copies : $SAFETY_DIR"
  echo "  Logs          : (cd $INSTALL_DIR && docker compose -f $COMPOSE_FILENAME --env-file=plane.env --project-name $PROJECT logs)"
  echo "  The snapshot itself is untouched: fix the cause and run this script again."
  exit "$code"
}
set -o errtrace   # also fire the trap for failures inside helper functions
trap on_error ERR

# ── 8. Stop Plane ───────────────────────────────────────────────────────────
echo ""
echo "=== Stopping Plane ==="
if $RESET_VOLUMES; then
  # down removes the containers but keeps the volumes; the database volume, which
  # carries the password, is then removed by hand so it is re-created with the
  # restored one. The uploads volume is not touched here.
  dc down
  PGDATA_VOL="$(vol_of pgdata)"
  if [ -n "$PGDATA_VOL" ]; then docker volume rm "$PGDATA_VOL" >/dev/null; echo "Removed volume $PGDATA_VOL"; fi
else
  $DO_DB && dc stop api worker beat-worker
  $DO_UP && dc stop plane-minio
fi

# ── 9. Configuration ────────────────────────────────────────────────────────
if $DO_CFG; then
  echo ""
  echo "=== Restoring configuration ==="
  cp "$SNAP_ENV" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Restored: $ENV_FILE"
fi

# ── 10. Database ────────────────────────────────────────────────────────────
if $DO_DB; then
  echo ""
  echo "=== Restoring the database ==="
  dc up -d plane-db
  wait_db

  # DROP DATABASE cannot run inside a transaction and cannot target the database
  # it is connected to, so work from the maintenance database. WITH (FORCE)
  # ends any lingering connection (PostgreSQL 13+; Plane ships 15).
  echo "Re-creating the database..."
  db_sh 'psql -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -v db="$POSTGRES_DB"' <<'SQL'
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db";
SQL

  # One transaction: a failure part-way leaves the empty database, not a
  # half-loaded one.
  echo "Loading the dump..."
  gunzip -c "$SNAP_DUMP" \
    | db_sh 'psql -q -v ON_ERROR_STOP=1 --single-transaction -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
  echo "Database restored."
fi

# ── 11. Uploads ─────────────────────────────────────────────────────────────
if $DO_UP; then
  echo ""
  echo "=== Restoring uploads ==="
  UPLOADS_VOL="$(vol_of uploads)"
  if [ -z "$UPLOADS_VOL" ]; then
    # No volume yet: let Compose create it (with its labels), without starting MinIO.
    dc up --no-start plane-minio >/dev/null
    UPLOADS_VOL="$(vol_of uploads)"
  fi
  [ -n "$UPLOADS_VOL" ] || { echo "Error: the 'uploads' volume of project $PROJECT could not be found or created."; exit 1; }
  # The volume is emptied in place (dotfiles included, so MinIO's .minio.sys goes
  # too) and the archive unpacked as root, which keeps the stored owners.
  docker run --rm -i -v "$UPLOADS_VOL":/data "$HELPER_IMAGE" \
    sh -euc 'find /data -mindepth 1 -delete; tar -xzf - -C /data' < "$SNAP_UPLOADS"
  echo "Uploads restored into $UPLOADS_VOL."
fi

# ── 12. Start Plane ─────────────────────────────────────────────────────────
echo ""
echo "=== Starting Plane ==="
# The migrator is a one-shot container that has already exited. Removing it makes
# `up` run it again, so a database restored from an older release is migrated
# forward before the API starts (the API waits for the migrations).
$DO_DB && dc rm -sf migrator >/dev/null 2>&1 || true
dc up -d

MIGRATOR_ID="$(dc ps -aq migrator 2>/dev/null | sed -n '1p' || true)"
if [ -n "$MIGRATOR_ID" ]; then
  echo -n "Waiting for the database migrations"
  while docker inspect --format='{{.State.Status}}' "$MIGRATOR_ID" 2>/dev/null | grep -q running; do
    echo -n "."
    sleep 2
  done
  echo ""
  MIGRATOR_EXIT="$(docker inspect --format='{{.State.ExitCode}}' "$MIGRATOR_ID")"
  if [ "$MIGRATOR_EXIT" != "0" ]; then
    echo "Error: the migrations failed (exit code $MIGRATOR_EXIT) - see: (cd $INSTALL_DIR && docker compose -f $COMPOSE_FILENAME --env-file=plane.env --project-name $PROJECT logs migrator)"
    exit 1
  fi
fi

# /api/instances/ goes proxy -> API -> database, so a 200 covers all three.
PORT="$(_env_get "$ENV_FILE" LISTEN_HTTP_PORT)"
UP=false
if [ -n "$PORT" ] && command -v curl >/dev/null 2>&1; then
  echo -n "Waiting for Plane on 127.0.0.1:$PORT"
  for _ in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${PORT}/api/instances/" 2>/dev/null || echo 000)
    [ "$CODE" = "200" ] && { UP=true; break; }
    echo -n "."
    sleep 3
  done
  echo ""
  if $UP; then
    echo "Plane is up."
  else
    echo "Warning: no answer yet - check: (cd $INSTALL_DIR && docker compose -f $COMPOSE_FILENAME --env-file=plane.env --project-name $PROJECT logs -f api)"
  fi
fi

trap - ERR

# ── 13. Things a restore cannot check for you ───────────────────────────────
if $DO_DB && ! $DO_CFG && [ "$(_env_get "$SNAP_ENV" SECRET_KEY)" != "$(_env_get "$ENV_FILE" SECRET_KEY)" ]; then
  echo ""
  echo "WARNING: SECRET_KEY differs between the snapshot and this instance. Settings saved in the database"
  echo "         (SMTP, OAuth secrets) are encrypted with it and will read as empty until you restore the"
  echo "         snapshot's plane.env (Full recovery or Configuration only)."
fi

if $DO_CFG && [ -f "$SNAP_COMPOSE" ] && ! diff -q "$SNAP_COMPOSE" "$COMPOSE_FILE" >/dev/null 2>&1; then
  echo ""
  echo "NOTE: the snapshot's docker-compose.yaml differs from this instance's, which was kept. If you had"
  echo "      edited it by hand, the old copy is at: $SNAP_COMPOSE"
fi

NGINX_SITE="/etc/nginx/sites-enabled/$DOMAIN"
if [ -n "$PORT" ] && [ -r "$NGINX_SITE" ] && ! grep -q "127.0.0.1:$PORT" "$NGINX_SITE"; then
  echo ""
  echo "WARNING: $NGINX_SITE does not proxy to 127.0.0.1:$PORT, where Plane is published now."
  echo "         Update the upstream/proxy_pass there and reload Nginx."
fi

echo ""
echo "Restore complete."
echo "Instance      : https://$DOMAIN"
echo "Safety copies : $SAFETY_DIR (delete once you have verified the restore)"
echo "Verify by logging in, opening a project and an attachment, and (if you use it) sending a test email."
echo ""
