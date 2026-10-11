#!/bin/bash
set -euo pipefail
# =============================================================================
# Harbor Docker Restore Script
# =============================================================================
# Restores a snapshot made by harbor-docker-backup.sh into a running instance
# installed by harbor-docker-install.sh:
#   <backup-root>/harbor/<domain>/<date-n-time>/postgres/registry.sql.gz
#   <backup-root>/harbor/<domain>/<date-n-time>/secret/secret.tar.gz
#   <backup-root>/harbor/<domain>/<date-n-time>/registry/registry.tar   (optional)
#   <backup-root>/harbor/<domain>/<date-n-time>/config/harbor.yml
#
# Restore options:
#   1) Full restore - database + secret keys + image storage. Disaster recovery
#      (new host: install a fresh instance first, then restore into it) or a
#      full rollback.
#   2) Database + secret keys only - keeps the target's image storage. For a
#      rollback on the same host when the image storage is intact (no garbage
#      collection since the snapshot), or a snapshot taken without it.
# The database and the secret keys always travel together: secretkey decrypts
# the secrets stored in the database, so one without the other is useless.
#
# What happens, in order:
#   1. Optional safety snapshot of the target's current database, secret keys and
#      harbor.yml (not its image storage), in the normal snapshot format.
#   2. Every Harbor service is stopped except log, postgresql and redis.
#   3. The "registry" database is dropped, recreated and loaded from the dump.
#   4. data/secret is replaced from the snapshot.
#   5. Full restore only: data/registry is emptied and extracted from the tar.
#   6. Redis is flushed: the registry caches layer info there (cache.layerinfo),
#      and a stale entry would claim a layer exists that the restored storage
#      does not have. It also holds sessions (everyone logs in again) and the
#      job queue.
#   7. `docker compose up -d`, then wait for /api/v2.0/ping.
#
# The target's harbor.yml is NOT replaced - it decides the domain, port and
# paths, so a snapshot can be restored into an instance with another domain.
# Harbor's version must be the snapshot's or newer: harbor-core migrates an
# older schema on start, exactly as during an upgrade, but cannot go backwards.
#
# Stack commands use `sudo docker compose`, because ./prepare writes Harbor's
# env files readable by root only. Data is written through a busybox container.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_HARBOR_PATH="/var/www/docker/harbor"
HELPER_IMAGE="busybox"

_die() { echo "Error: $*" >&2; exit 1; }

_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

_manifest_get() {  # _manifest_get <snapshot-dir> <key>
  sed -n "s/^${2}[[:space:]]*:[[:space:]]*//p" "$1/manifest.txt" 2>/dev/null | head -n1 || true
}

_version_ge() {  # _version_ge <a> <b>  ->  true when a >= b
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

_container_dir() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2>/dev/null || true
}

_yml_value() {  # _yml_value <harbor.yml> <top-level key>
  grep "^[^#]*${2}:" "$1" | head -n1 | awk '{print $NF}' | tr -d "\"'"
}

echo ""
echo "=====> Harbor Restore"
echo "========================================"

for cmd in docker curl gzip tar sort find realpath; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"

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

HARBOR_BACKUPS_DIR="$BACKUP_ROOT/harbor"
[ -d "$HARBOR_BACKUPS_DIR" ] || _die "'$HARBOR_BACKUPS_DIR' not found."

# ── 2. Select the domain the backup came from ───────────────────────────────
echo ""
mapfile -t DOMAIN_DIRS < <(find "$HARBOR_BACKUPS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || _die "No domain backup folders found in '$HARBOR_BACKUPS_DIR'."

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
    _die "Invalid selection."
  fi
  DOMAIN_DIR="${DOMAIN_DIRS[$((DOM_NUM-1))]}"
fi

# ── 3. List snapshots ───────────────────────────────────────────────────────
mapfile -t SNAPSHOTS < <(find "$DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)
[ ${#SNAPSHOTS[@]} -gt 0 ] || _die "No backup snapshots found in '$(basename "$DOMAIN_DIR")'."

echo ""
printf "  %-4s %-28s %-9s %-9s %-8s %-10s %s\n" "#" "Date" "Version" "Database" "Secrets" "Images" "Note"
printf "  %-4s %-28s %-9s %-9s %-8s %-10s %s\n" "----" "----------------------------" "---------" "---------" "--------" "----------" "----"
for i in "${!SNAPSHOTS[@]}"; do
  S="${SNAPSHOTS[$i]}"
  NICE=$(_nice_date "$(basename "$S")")
  VER="$(_manifest_get "$S" "Harbor version")"
  PG_S=$([ -f "$S/postgres/registry.sql.gz" ] && echo "ok" || echo "--")
  SEC_S=$([ -f "$S/secret/secret.tar.gz" ] && echo "ok" || echo "--")
  REG_S="--"
  [ -f "$S/registry/registry.tar" ] && REG_S="$(du -h "$S/registry/registry.tar" | cut -f1)"
  NOTE=""
  [ "$(_manifest_get "$S" "Type")" = "pre-restore safety snapshot" ] && NOTE="pre-restore"
  printf "  %-4s %-28s %-9s %-9s %-8s %-10s %s\n" "$((i+1)))" "$NICE" "${VER:-?}" "$PG_S" "$SEC_S" "$REG_S" "$NOTE"
done

echo ""
read -rp "Select backup number to restore: " TS_NUM
if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
  _die "Invalid selection."
fi

SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"
SNAP_VERSION="$(_manifest_get "$SNAPSHOT_DIR" "Harbor version")"
SNAP_DOMAIN="$(_manifest_get "$SNAPSHOT_DIR" "Domain")"
SNAP_DUMP="$SNAPSHOT_DIR/postgres/registry.sql.gz"
SNAP_SECRET="$SNAPSHOT_DIR/secret/secret.tar.gz"
SNAP_REG="$SNAPSHOT_DIR/registry/registry.tar"

[ -f "$SNAP_DUMP" ]   || _die "this snapshot has no database dump."
[ -f "$SNAP_SECRET" ] || _die "this snapshot has no secret keys - the database cannot be used without them."
HAS_REG=false
[ -f "$SNAP_REG" ] && HAS_REG=true

# ── 4. Ask what to restore ──────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "About these options:"
echo ""
echo "  Full restore puts back the database, the secret keys and the image"
echo "  storage (layers and manifests). Use it for disaster recovery - on a new"
echo "  host, install a fresh instance first and restore into it - or to roll"
echo "  the whole registry back to the snapshot."
echo ""
echo "  Database + secret keys keeps the target's current image storage. Use it"
echo "  to roll back projects, users, robot accounts and settings on the same"
echo "  host, when the image storage is still intact. If garbage collection has"
echo "  run since the snapshot, layers it removed are gone and the artifacts"
echo "  that used them will fail to pull."
echo ""
echo "  The database and secret keys always go together: Harbor encrypts the"
echo "  credentials it stores (replication endpoints, OIDC, ...) with"
echo "  data/secret/keys/secretkey."
echo "------------------------------------------------------------"
echo ""
echo "What do you want to restore?"
if $HAS_REG; then
  echo "  1) Full restore (database + secret keys + image storage)"
else
  echo "  1) Full restore - not available, this snapshot has no image storage"
fi
echo "  2) Database + secret keys only"
read -rp "Select [1/2]: " ACTION

case "$ACTION" in
  1) $HAS_REG || _die "this snapshot has no image storage - choose option 2."
     DO_REG=true ;;
  2) DO_REG=false ;;
  *) _die "Invalid selection." ;;
esac

# ── 5. Choose the target instance ───────────────────────────────────────────
echo ""
echo "Where should this be restored TO?"
echo "  1) Default: $DEFAULT_HARBOR_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " TARGET_LOCATION_CHOICE

if [ "$TARGET_LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Harbor base path: " HARBOR_BASE_PATH
  HARBOR_BASE_PATH="${HARBOR_BASE_PATH/#\~/$HOME}"
else
  HARBOR_BASE_PATH="$DEFAULT_HARBOR_PATH"
fi
HARBOR_BASE_PATH="${HARBOR_BASE_PATH%/}"
[ -d "$HARBOR_BASE_PATH" ] || _die "'$HARBOR_BASE_PATH' not found."

mapfile -t TARGETS < <(find "$HARBOR_BASE_PATH" -mindepth 3 -maxdepth 3 \
  -path '*/harbor/harbor.yml' -printf '%h\n' | sed 's|/harbor$||' | sort -u)
[ ${#TARGETS[@]} -gt 0 ] || _die "No Harbor instances found in '$HARBOR_BASE_PATH' - install one first with harbor-docker-install.sh."

echo ""
if [ ${#TARGETS[@]} -eq 1 ]; then
  INSTANCE_DIR="${TARGETS[0]}"
  echo "Target instance: $(basename "$INSTANCE_DIR")  ($INSTANCE_DIR)"
else
  echo "Found instances:"
  for i in "${!TARGETS[@]}"; do
    echo "  $((i+1))) $(basename "${TARGETS[$i]}")  (${TARGETS[$i]})"
  done
  echo ""
  read -rp "Select instance number to restore INTO: " TGT_NUM
  if ! [[ "$TGT_NUM" =~ ^[0-9]+$ ]] || [ "$TGT_NUM" -lt 1 ] || [ "$TGT_NUM" -gt "${#TARGETS[@]}" ]; then
    _die "Invalid selection."
  fi
  INSTANCE_DIR="${TARGETS[$((TGT_NUM-1))]}"
fi

HARBOR_DIR="$INSTANCE_DIR/harbor"
HARBOR_YML="$HARBOR_DIR/harbor.yml"
COMPOSE_FILE="$HARBOR_DIR/docker-compose.yml"
[ -r "$HARBOR_YML" ]   || _die "cannot read $HARBOR_YML."
[ -f "$COMPOSE_FILE" ] || _die "$COMPOSE_FILE not found - has install.sh run for this instance?"

DOMAIN="$(_yml_value "$HARBOR_YML" hostname)"
DATA_DIR="$(_yml_value "$HARBOR_YML" data_volume)"
[ -n "$DOMAIN" ]   || _die "no hostname in $HARBOR_YML."
[ -d "$DATA_DIR" ] || _die "data_volume '$DATA_DIR' from $HARBOR_YML does not exist."

# The containers have to be this instance's, and running: the database is
# restored through harbor-db, and Redis is flushed through redis.
for c in harbor-log harbor-db harbor-core redis; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = "true" ] \
    || _die "container $c is not running. Start Harbor first: (cd \"$HARBOR_DIR\" && sudo docker compose up -d)"
  owner="$(_container_dir "$c")"
  [ -n "$owner" ] && [ "$(realpath -m "$owner")" = "$(realpath -m "$HARBOR_DIR")" ] \
    || _die "container $c belongs to '${owner:-unknown}', not $HARBOR_DIR."
done

CORE_IMAGE="$(docker inspect -f '{{.Config.Image}}' harbor-core)"
TARGET_VERSION="${CORE_IMAGE##*:}"

# ── 6. Version check ────────────────────────────────────────────────────────
if [ -z "$SNAP_VERSION" ]; then
  echo ""
  echo "WARNING: the snapshot's manifest does not say which Harbor version made it."
  read -rp "Restore it into $TARGET_VERSION anyway? [y/N]: " ANS_VER
  [[ "$ANS_VER" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; exit 0; }
elif [ "$SNAP_VERSION" != "$TARGET_VERSION" ]; then
  _version_ge "$TARGET_VERSION" "$SNAP_VERSION" || \
    _die "the snapshot is from Harbor $SNAP_VERSION but the target runs $TARGET_VERSION. A database cannot be migrated backwards - install $SNAP_VERSION or newer."
  echo ""
  echo "NOTE: the snapshot is from Harbor $SNAP_VERSION and the target runs $TARGET_VERSION."
  echo "      harbor-core migrates the database schema when it starts, the same as"
  echo "      during an upgrade."
  read -rp "Continue? [y/N]: " ANS_VER
  [[ "$ANS_VER" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; exit 0; }
fi

# ── 7. Safety snapshot ──────────────────────────────────────────────────────
echo ""
echo "A safety snapshot saves the target's CURRENT database, secret keys and"
echo "harbor.yml (not its image storage) before anything is replaced, so the"
echo "restore can be undone with option 2."
read -rp "Take a safety snapshot first? [Y/n]: " ANS_SAFETY
if [[ "$ANS_SAFETY" =~ ^[Nn]$ ]]; then DO_SAFETY=false; else DO_SAFETY=true; fi
SAFETY_DEST=""
$DO_SAFETY && SAFETY_DEST="$BACKUP_ROOT/harbor/$DOMAIN/$(date +"%Y-%m-%d-%H-%M-%S")"

# ── 8. Final confirmation ───────────────────────────────────────────────────
echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Backup snapshot : $SNAPSHOT_DIR"
echo "  from          : ${SNAP_DOMAIN:-?}, Harbor ${SNAP_VERSION:-?}"
echo "Target instance : $DOMAIN (Harbor $TARGET_VERSION)"
echo "Install dir     : $INSTANCE_DIR"
echo "Restoring       :"
echo "  - PostgreSQL database 'registry'"
echo "  - Secret keys (data/secret)"
$DO_REG && echo "  - Image storage (data/registry)"
$DO_SAFETY && echo "Safety snapshot : $SAFETY_DEST"
echo "========================================================="
echo ""
echo "WARNING: Harbor is unavailable while this runs."
echo "WARNING: this DROPS + REPLACES the target's 'registry' database and data/secret."
$DO_REG && echo "WARNING: this DELETES everything in $DATA_DIR/registry and replaces it from the snapshot."
$DO_SAFETY || echo "WARNING: no safety snapshot - the target's current data cannot be recovered afterwards."
if [ -n "$SNAP_DOMAIN" ] && [ "$SNAP_DOMAIN" != "$DOMAIN" ]; then
  echo "NOTE:    the snapshot comes from $SNAP_DOMAIN; it will be served as $DOMAIN."
fi
echo ""
read -rp "Type 'yes' to confirm and proceed: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Restore cancelled."
  exit 0
fi

sudo -v   # ask for the sudo password now, not halfway through
dc() { sudo docker compose -f "$COMPOSE_FILE" "$@"; }

docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull -q "$HELPER_IMAGE" >/dev/null

STOPPED=false
on_error() {
  local code=$?
  echo ""
  echo "Restore FAILED (exit $code)."
  if $STOPPED; then
    echo "Harbor is partly stopped. To start it again as it is now:"
    echo "  cd $HARBOR_DIR && sudo docker compose up -d"
  fi
  [ -n "$SAFETY_DEST" ] && [ -d "$SAFETY_DEST" ] && \
    echo "The target's previous database and keys are in: $SAFETY_DEST"
  exit "$code"
}
trap on_error ERR

# ── 9. Safety snapshot ──────────────────────────────────────────────────────
if $DO_SAFETY; then
  echo ""
  echo "=== Safety snapshot of the target ==="
  mkdir -p "$SAFETY_DEST/postgres" "$SAFETY_DEST/secret" "$SAFETY_DEST/config"
  chmod 700 "$SAFETY_DEST"
  docker exec harbor-db pg_dump -U postgres --no-owner --no-privileges registry \
    | gzip > "$SAFETY_DEST/postgres/registry.sql.gz"
  gzip -t "$SAFETY_DEST/postgres/registry.sql.gz"
  docker run --rm -v "$DATA_DIR/secret:/src:ro" "$HELPER_IMAGE" tar -czf - -C /src . \
    > "$SAFETY_DEST/secret/secret.tar.gz"
  cp "$HARBOR_YML" "$SAFETY_DEST/config/harbor.yml"
  chmod 600 "$SAFETY_DEST/config/harbor.yml"
  {
    echo "Harbor backup manifest"
    echo "Created         : $(date -Iseconds)"
    echo "Type            : pre-restore safety snapshot"
    echo "Domain          : $DOMAIN"
    echo "Install dir     : $INSTANCE_DIR"
    echo "Harbor version  : $TARGET_VERSION"
    echo "Core image      : $CORE_IMAGE"
    echo "Image storage   : no"
    echo "Taken before    : restore of $SNAPSHOT_DIR"
  } > "$SAFETY_DEST/manifest.txt"
  echo "Saved: $SAFETY_DEST"
fi

# ── 10. Stop everything except log, postgresql and redis ────────────────────
echo ""
echo "=== Stopping Harbor (keeping log, postgresql, redis) ==="
mapfile -t SERVICES < <(dc config --services)
TO_STOP=()
for s in "${SERVICES[@]}"; do
  case "$s" in
    log|postgresql|redis) ;;
    *) TO_STOP+=("$s") ;;
  esac
done
[ ${#TO_STOP[@]} -gt 0 ] || { echo "Error: could not list the services in $COMPOSE_FILE."; false; }
STOPPED=true
dc stop "${TO_STOP[@]}"

# ── 11. Restore PostgreSQL ──────────────────────────────────────────────────
echo ""
echo "=== Restoring PostgreSQL ==="
echo "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 30); do
  if docker exec harbor-db psql -U postgres -d postgres -tAc 'SELECT 1' &>/dev/null; then
    break
  fi
  [ "$i" -eq 30 ] && { echo "Error: harbor-db did not become ready in time."; false; }
  sleep 2
done

echo "Dropping and recreating database 'registry'..."
docker exec harbor-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
  -c "DROP DATABASE IF EXISTS registry WITH (FORCE);" \
  -c "CREATE DATABASE registry ENCODING 'UTF8';"

echo "Loading dump..."
gunzip -c "$SNAP_DUMP" \
  | docker exec -i harbor-db psql -U postgres -d registry -v ON_ERROR_STOP=1 --single-transaction -q >/dev/null
echo "Database restored."

# ── 12. Restore secret keys ─────────────────────────────────────────────────
# Extracted beside the live directory and swapped in only once complete. tar runs
# as root in the helper, so the files keep their owner (10000) and mode (600).
echo ""
echo "=== Restoring secret keys ==="
docker run --rm -i -v "$DATA_DIR:/data" "$HELPER_IMAGE" sh -c '
  set -e
  rm -rf /data/secret.restoring
  mkdir /data/secret.restoring
  tar -xzf - -C /data/secret.restoring
  test -s /data/secret.restoring/keys/secretkey
  rm -rf /data/secret
  mv /data/secret.restoring /data/secret
' < "$SNAP_SECRET"
echo "Restored: $DATA_DIR/secret"

# ── 13. Restore image storage ───────────────────────────────────────────────
if $DO_REG; then
  echo ""
  echo "=== Restoring image storage ($(du -h "$SNAP_REG" | cut -f1)) ==="
  docker run --rm -i -v "$DATA_DIR/registry:/registry" "$HELPER_IMAGE" sh -c '
    set -e
    find /registry -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar -xf - -C /registry
  ' < "$SNAP_REG"
  echo "Restored: $DATA_DIR/registry"
fi

# ── 14. Flush Redis ─────────────────────────────────────────────────────────
echo ""
echo "=== Flushing Redis (layer cache, sessions, job queue) ==="
docker exec redis redis-cli FLUSHALL

# ── 15. Start Harbor ────────────────────────────────────────────────────────
echo ""
echo "=== Starting Harbor ==="
dc up -d
STOPPED=false

PUBLISHED="$(docker port nginx 8080/tcp 2>/dev/null | head -n1 || true)"
echo -n "Waiting for Harbor to respond on ${PUBLISHED:-?}"
HARBOR_UP=false
if [ -n "$PUBLISHED" ]; then
  for _ in $(seq 1 60); do
    if [ "$(curl -fsS --max-time 5 "http://${PUBLISHED}/api/v2.0/ping" 2>/dev/null || true)" = "Pong" ]; then
      HARBOR_UP=true
      break
    fi
    echo -n "."
    sleep 5
  done
fi
echo ""
trap - ERR

echo ""
if $HARBOR_UP; then
  echo "Restore complete."
else
  echo "Restore finished, but Harbor did not answer within ~5 minutes. Check:"
  echo "  cd $HARBOR_DIR && sudo docker compose ps"
  echo "  sudo tail -n 50 $(_yml_value "$HARBOR_YML" location)/core.log"
fi
echo "Instance: https://$DOMAIN"
echo ""
echo "  - Logins are whatever the snapshot's database holds - including the admin"
echo "    password. harbor_admin_password in harbor.yml only applies on first start."
echo "  - Everyone has to log in again (sessions were in Redis)."
if [ -n "$SNAP_DOMAIN" ] && [ "$SNAP_DOMAIN" != "$DOMAIN" ]; then
  echo "  - Images are now at $DOMAIN/<project>/<repo> instead of $SNAP_DOMAIN/..."
  echo "    Update docker logins, CI and image references accordingly."
fi
[ -n "$SAFETY_DEST" ] && echo "  - The target's previous state is in: $SAFETY_DEST"
echo ""
