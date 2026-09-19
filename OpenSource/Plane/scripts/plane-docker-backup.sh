#!/bin/bash
set -euo pipefail
# =============================================================================
# Plane Docker Backup Script v1.0
# =============================================================================
# Backs up an instance installed by plane-docker-install.sh into one timestamped
# snapshot:
#   <backup-root>/plane/<domain>/<date-n-time>/postgres/plane.sql.gz
#   <backup-root>/plane/<domain>/<date-n-time>/uploads/uploads.tar.gz
#   <backup-root>/plane/<domain>/<date-n-time>/config/plane.env
#   <backup-root>/plane/<domain>/<date-n-time>/config/docker-compose.yaml
#   <backup-root>/plane/<domain>/<date-n-time>/manifest.txt
#
# What Plane says needs backing up (docs: "Backup and restore data", "Other
# deployment methods"): the PostgreSQL database, the object storage, and the
# configuration. That is what this takes:
#
# postgres/   A plain-SQL pg_dump of the Plane database, run inside the plane-db
#             container. Workspaces, projects, work items, users, comments and the
#             settings saved in God Mode (SMTP, OAuth) all live here. pg_dump reads
#             a consistent snapshot, so Plane stays up. (Plane's own volume backup,
#             ./setup.sh backup, copies the live data directory instead - that is
#             only crash-consistent, and needs the volume's baked-in password.)
# uploads/    The plane-minio data volume (bucket "uploads": attachments, images,
#             covers), as one tar.gz. Skipped when USE_MINIO=0 (external S3 - back
#             that up with your S3 provider's tools).
# config/     plane.env holds SECRET_KEY and the generated database, RabbitMQ and
#             MinIO credentials. SECRET_KEY matters most: Plane encrypts the
#             settings saved in the database with a key derived from it, and a
#             database restored under another SECRET_KEY reads them as empty
#             (nothing fails visibly; Plane only logs an error).
#             docker-compose.yaml is saved as a reference copy: the
#             installer downloads it per release and patches the loopback port, and
#             any change you made by hand lives there. The restore puts back only
#             plane.env (see plane-docker-restore.sh for why).
#
# Not archived: Redis (only Django's cache), RabbitMQ (only the Celery broker -
# and RabbitMQ starts a fresh node in every new container anyway), the log and
# proxy volumes, Nginx and TLS certificates (the installer regenerates the vhost
# and certbot re-issues the certificate).
#
# Snapshots are NOT interchangeable with ./setup.sh backup / restore.sh: this
# install has no setup.sh and its Compose project is plane-<domain>, not plane-app.
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
# What this script does about it: nothing has to change while MinIO stays. The
# database dump (step 6) and the configuration copy (step 8) do not involve MinIO.
# The uploads step (step 7) reads the MinIO data VOLUME through a read-only busybox
# container, so it works whatever image MinIO runs from.
#
# What to know
#   - uploads/uploads.tar.gz is MinIO's ON-DISK format (an xl.meta per object plus
#     .minio.sys metadata). It can only be restored into a MinIO of the same or a
#     newer release, and into no other S3 server (their formats differ).
#   - The manifest records Plane's release but NOT MinIO's. Improvement, deliberately
#     not implemented (comments only were requested): add the output of
#     `docker compose ... exec -T plane-minio minio --version`, so that a restore can
#     refuse to load newer data into an older MinIO.
#   - Nothing but snapshot folders may live under <backup-root>/plane/<domain>/: step
#     10 prunes every folder there beyond RETAIN_COUNT and plane-docker-restore.sh
#     lists every folder there as a snapshot. That is why
#     ../migration/02-save-minio-image.sh keeps the saved MinIO image in
#     <backup-root>/plane-minio-image/<domain>/ instead.
#
# If the situation changes
#   - Uploads move to external S3 (USE_MINIO=0): this script already skips step 7 (see
#     the USE_MINIO check). The bucket must then be backed up with the provider's
#     tools, and new snapshots no longer contain uploads/.
#   - Plane replaces MinIO with another S3 server: step 7 (a tar of a MinIO volume) is
#     wrong for it. Replace it with an S3 sync (`mc mirror`, `aws s3 sync` or rclone)
#     into uploads/, change the restore's uploads step to match, and record the new
#     server's version in the manifest.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_PLANE_PATH="/var/www/docker/plane"
COMPOSE_FILENAME="docker-compose.yaml"
HELPER_IMAGE="busybox"
RETAIN_COUNT=7

echo ""
echo "=====> Plane Backup"
echo "========================================"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Error: the Docker Compose plugin ('docker compose') is required."; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "Error: gzip is required."; exit 1; }

# _env_get <file> <key> - last KEY=value in a dotenv file, surrounding quotes removed.
_env_get() {
  local v
  v="$(grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  v="${v#[\'\"]}"; v="${v%[\'\"]}"
  printf '%s' "$v"
}

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
[ -w "$BACKUP_ROOT" ] || { echo "Error: '$BACKUP_ROOT' is not writable by $(id -un)."; exit 1; }

# ── 2. Ask for Plane instances location ─────────────────────────────────────
echo ""
echo "Where are your Plane instances located?"
echo "  1) Default: $DEFAULT_PLANE_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Plane base path: " PLANE_BASE_PATH
  PLANE_BASE_PATH="${PLANE_BASE_PATH/#\~/$HOME}"
else
  PLANE_BASE_PATH="$DEFAULT_PLANE_PATH"
fi

[ -d "$PLANE_BASE_PATH" ] || { echo "Error: Directory '$PLANE_BASE_PATH' not found."; exit 1; }
PLANE_BASE_PATH="$(cd "$PLANE_BASE_PATH" && pwd)"

# ── 3. List installed instances ─────────────────────────────────────────────
echo ""
echo "Scanning for Plane instances in: $PLANE_BASE_PATH"
echo "--------------------------------------------"

# An instance is a directory holding Plane's docker-compose.yaml next to its plane.env.
INSTANCES=()
while IFS= read -r f; do
  if [ -f "$(dirname "$f")/plane.env" ] && grep -q 'makeplane/plane-backend' "$f"; then
    INSTANCES+=("$(dirname "$f")")
  fi
done < <(find "$PLANE_BASE_PATH" -maxdepth 2 -name "$COMPOSE_FILENAME" | sort -u)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Plane instances found in '$PLANE_BASE_PATH'."
  exit 1
fi

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
done

if [ ${#INSTANCES[@]} -eq 1 ]; then
  INST_NUM=1
else
  echo ""
  read -rp "Select instance number: " INST_NUM
fi
if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

PROJECT_DIR="${INSTANCES[$((INST_NUM-1))]}"
COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_FILENAME"
ENV_FILE="$PROJECT_DIR/plane.env"

DOMAIN="$(_env_get "$ENV_FILE" APP_DOMAIN)"
DOMAIN="${DOMAIN:-$(basename "$PROJECT_DIR")}"
# Same name plane-docker-install.sh gives the Compose project.
PROJECT="plane-${DOMAIN//./-}"

# Everything below runs from the instance directory with the same flags the
# installer prints, so Compose reads this instance's files and project.
cd "$PROJECT_DIR"
dc() { docker compose -f "$COMPOSE_FILENAME" --env-file=plane.env --project-name "$PROJECT" "$@"; }

# vol_of <name> - the real Docker volume for a Compose volume, found by the labels
# Compose puts on it (so this does not depend on how the project name is spelled).
vol_of() {
  docker volume ls -q \
    --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.volume=$1" | sed -n '1p'
}

# ── 4. Verify the database is running ───────────────────────────────────────
if [ -z "$(dc ps -q plane-db 2>/dev/null)" ]; then
  echo "Error: the 'plane-db' service is not running for $DOMAIN (project $PROJECT)."
  echo "Start it first: (cd \"$PROJECT_DIR\" && docker compose -f $COMPOSE_FILENAME --env-file=plane.env --project-name $PROJECT up -d)"
  exit 1
fi

USE_MINIO="$(_env_get "$ENV_FILE" USE_MINIO)"
UPLOADS_VOL=""
if [ "${USE_MINIO:-1}" != "0" ]; then
  UPLOADS_VOL="$(vol_of uploads)"
  [ -n "$UPLOADS_VOL" ] || { echo "Error: the Docker volume 'uploads' of project $PROJECT was not found (USE_MINIO=${USE_MINIO:-1})."; exit 1; }
  # Fetch the helper image now, so a missing image cannot fail the backup halfway.
  docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull "$HELPER_IMAGE" >/dev/null
fi

# ── 5. Confirm ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
BACKUP_DEST="$BACKUP_ROOT/plane/$DOMAIN/$TIMESTAMP"

echo ""
echo "Instance        : $DOMAIN"
echo "Install dir     : $PROJECT_DIR"
echo "Compose project : $PROJECT"
echo "Uploads volume  : ${UPLOADS_VOL:-(none - USE_MINIO=0, back up your S3 storage separately)}"
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

mkdir -p "$BACKUP_DEST/postgres" "$BACKUP_DEST/config"
chmod 700 "$BACKUP_DEST"   # contains the database dump and plane.env secrets

# ── 6. PostgreSQL dump ──────────────────────────────────────────────────────
# Run inside the plane-db container: its pg_dump always matches the server and it
# reads the database name and user the container was created with. -h 127.0.0.1
# is needed: Compose sets PGHOST=plane-db in that container, which would send
# pg_dump over the network, where a password is required; the loopback address
# is trusted inside the container. --no-owner and --no-privileges keep the dump
# loadable whatever the role is called.
echo ""
echo "=== Backing up the PostgreSQL database ==="
DUMP="$BACKUP_DEST/postgres/plane.sql.gz"
dc exec -T plane-db \
  sh -c 'pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' </dev/null \
  | gzip > "$DUMP"
chmod 600 "$DUMP"

# pg_dump ends every complete dump with this line, so it also catches truncation.
echo "Verifying the dump..."
if ! gunzip -c "$DUMP" | tail -n 20 | grep -q 'PostgreSQL database dump complete'; then
  echo "Error: $DUMP is incomplete or corrupt."
  exit 1
fi
echo "Saved: $DUMP ($(du -h "$DUMP" | cut -f1))"

# ── 7. Uploads (MinIO data) ─────────────────────────────────────────────────
HAS_UPLOADS=no
if [ -n "$UPLOADS_VOL" ]; then
  echo ""
  echo "=== Backing up the uploads volume ($UPLOADS_VOL) ==="
  mkdir -p "$BACKUP_DEST/uploads"
  UPFILE="$BACKUP_DEST/uploads/uploads.tar.gz"
  # Read-only mount: MinIO keeps running and nothing here can change its data.
  docker run --rm -v "$UPLOADS_VOL":/data:ro "$HELPER_IMAGE" tar -czf - -C /data . > "$UPFILE"
  chmod 600 "$UPFILE"
  echo "Verifying the archive..."
  tar tzf "$UPFILE" >/dev/null || { echo "Error: $UPFILE is corrupt."; exit 1; }
  HAS_UPLOADS=yes
  echo "Saved: $UPFILE ($(du -h "$UPFILE" | cut -f1))"
else
  echo ""
  echo "=== No uploads volume to back up (USE_MINIO=0) ==="
fi

# ── 8. Configuration ────────────────────────────────────────────────────────
echo ""
echo "=== Backing up configuration ==="
cp "$ENV_FILE" "$BACKUP_DEST/config/plane.env"
cp "$COMPOSE_FILE" "$BACKUP_DEST/config/docker-compose.yaml"
chmod 600 "$BACKUP_DEST/config/plane.env" "$BACKUP_DEST/config/docker-compose.yaml"
echo "Saved: $BACKUP_DEST/config/{plane.env,docker-compose.yaml}"

# ── 9. Manifest ─────────────────────────────────────────────────────────────
# Best-effort details; none of them can fail the backup. exec would otherwise
# attach this script's stdin, hence </dev/null.
PG_VERSION_LINE="$(dc exec -T plane-db sh -c 'postgres --version' </dev/null 2>/dev/null | tr -d '\r' || true)"
# Schema level: how many migrations are applied, and the newest of Plane's own
# "db" app (chr(100)||chr(98) is 'db', spelled that way to stay inside the quotes).
MIGRATIONS="$(dc exec -T plane-db sh -c 'psql -h 127.0.0.1 -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM django_migrations"' </dev/null 2>/dev/null | tr -d '\r' || true)"
LATEST_DB_MIGRATION="$(dc exec -T plane-db sh -c 'psql -h 127.0.0.1 -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT max(name) FROM django_migrations WHERE app = chr(100) || chr(98)"' </dev/null 2>/dev/null | tr -d '\r' || true)"
UPLOADS_SIZE=""
[ "$HAS_UPLOADS" = "yes" ] && UPLOADS_SIZE="$(du -h "$BACKUP_DEST/uploads/uploads.tar.gz" | cut -f1)"

{
  echo "Plane backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Domain          : $DOMAIN"
  echo "Source dir      : $PROJECT_DIR"
  echo "Compose project : $PROJECT"
  echo "Plane release   : $(_env_get "$ENV_FILE" APP_RELEASE)"
  echo "PostgreSQL      : ${PG_VERSION_LINE:-unknown}"
  echo "Migrations      : ${MIGRATIONS:-unknown} applied, newest in the db app: ${LATEST_DB_MIGRATION:-unknown}"
  echo "postgres/       : plane.sql.gz (full database, verified complete)"
  echo "uploads/        : ${HAS_UPLOADS} ${UPLOADS_SIZE:+(uploads.tar.gz, $UPLOADS_SIZE)}"
  echo "config/         : plane.env (secrets) and a reference copy of docker-compose.yaml - mode 600"
  echo "Note            : restore onto the same Plane release or newer: a database from a"
  echo "                  newer release than the running one may not work with it."
  echo "Note            : the database and uploads are captured while Plane runs; a file"
  echo "                  uploaded during the backup may be in one but not the other."
  echo "Note            : plane.env holds SECRET_KEY, which decrypts settings stored in the"
  echo "                  database (SMTP, OAuth). Keep this snapshot secret and complete."
} > "$BACKUP_DEST/manifest.txt"

# ── 10. Prune old snapshots for this domain ─────────────────────────────────
DOMAIN_BACKUP_DIR="$BACKUP_ROOT/plane/$DOMAIN"
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
