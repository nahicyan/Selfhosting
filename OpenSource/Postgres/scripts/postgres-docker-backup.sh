#!/bin/bash
set -euo pipefail
# =============================================================================
# PostgreSQL (shared) Docker Backup Script
# =============================================================================
# Snapshots an instance installed by postgres-docker-install.sh:
#   <backup-root>/postgres/<domain>/<date-n-time>/roles.sql.gz
#   <backup-root>/postgres/<domain>/<date-n-time>/databases/<db>.sql.gz
#   <backup-root>/postgres/<domain>/<date-n-time>/databases.tsv
#   <backup-root>/postgres/<domain>/<date-n-time>/config.tar.gz
#   <backup-root>/postgres/<domain>/<date-n-time>/manifest.txt
#   <backup-root>/postgres/<domain>/<date-n-time>/SHA256SUMS
#
# roles.sql.gz    pg_dumpall --roles-only: every role, its password hash and
#                 memberships. Databases are dumped with owners and grants, so
#                 the restore puts these back first.
# databases/      One plain-SQL pg_dump --create per database (all but postgres
#                 and the templates), so one app can be restored without
#                 touching the others. Run inside the container, so pg_dump
#                 always matches the server; it reads a consistent snapshot,
#                 so apps stay up.
# databases.tsv   name <tab> owner, read by the restore script.
# config.tar.gz   .env, docker-compose.yml, conf/, ca/ (including the CA key),
#                 clients/ and certs/ minus server.key. Install mode 2 rebuilds
#                 a server from this, and handed-out certificates keep working.
# SHA256SUMS      Checked by the restore before it touches anything.
#
# Unattended (cron) mode - set both to skip every prompt:
#   POSTGRES_BACKUP_ROOT    backup root, e.g. /home/backup
#   POSTGRES_INSTANCE_DIR   instance directory, e.g. /var/www/docker/postgres/db.example.com
#   POSTGRES_BACKUP_KEEP    snapshots to keep per domain (default 7; 0 = never prune)
# Example crontab line (postgres-docker-install.sh offers to add it):
#   30 2 * * * POSTGRES_BACKUP_ROOT=/home/backup POSTGRES_INSTANCE_DIR=/var/www/docker/postgres/db.example.com /path/to/postgres-docker-backup.sh >> $HOME/postgres-backup.log 2>&1
#
# A lock file in the instance directory stops two backups, or a backup and a
# restore, from running against the same instance at once.
# =============================================================================

DEFAULT_BACKUP_ROOT="/home/backup"
PG_BASE="/var/www/docker/postgres"
RETAIN_COUNT="${POSTGRES_BACKUP_KEEP:-7}"
# Internal: postgres-docker-restore.sh sets these for its pre-restore snapshot,
# which it takes while already holding the instance lock.
SNAPSHOT_TYPE="${POSTGRES_BACKUP_TYPE:-backup}"
LOCK_HELD="${POSTGRES_BACKUP_LOCK_HELD:-false}"

UNATTENDED=false
[[ -n "${POSTGRES_BACKUP_ROOT:-}" && -n "${POSTGRES_INSTANCE_DIR:-}" ]] && UNATTENDED=true

DEST=""
DONE=false
umask 077

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "Error: $*" >&2; exit 1; }

_env_get() {  # _env_get <file> <key>
  local v
  v="$(sed -n "s/^${2}=//p" "$1" | tail -n1)"
  if [[ "$v" == \'*\' || "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# pg_dump and pg_dumpall end every complete dump with this line, so it also
# catches truncation.
_check() {  # _check <file.gz> <closing text>
  [[ "$(gzip -cd "$1" | tail -n 5)" == *"$2"* ]] || _die "$1 is incomplete or corrupt."
}

# A failure after the snapshot directory exists removes it, so a partial
# snapshot is never mistaken for a good one during a restore.
_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$DONE" != true && -n "$DEST" && -d "$DEST" ]]; then
    echo "Backup failed (exit $rc) - removing incomplete $DEST" >&2
    rm -rf "$DEST"
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=====> PostgreSQL Backup"
echo "========================================"
$UNATTENDED && echo "Unattended mode ($(date -Iseconds))"

for cmd in docker gzip tar sed find sort sha256sum flock; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
[[ "$RETAIN_COUNT" =~ ^[0-9]+$ ]] || _die "POSTGRES_BACKUP_KEEP must be a number (0 = never prune)."

# ── 1. Where to save the backup ───────────────────────────────────────────────
if [[ -n "${POSTGRES_BACKUP_ROOT:-}" ]]; then
  BACKUP_ROOT="$POSTGRES_BACKUP_ROOT"
else
  echo "Choose the directory where you want to save the backup:"
  echo "  1) Default: $DEFAULT_BACKUP_ROOT"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " ans
  if [ "$ans" = "2" ]; then
    read -rep "Enter custom backup directory: " BACKUP_ROOT
    BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
  else
    BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
  fi
fi
BACKUP_ROOT="${BACKUP_ROOT%/}"
[[ "$BACKUP_ROOT" = /* ]] || _die "the backup directory must be an absolute path."
mkdir -p "$BACKUP_ROOT" || _die "cannot create $BACKUP_ROOT."

# ── 2. Which instance ─────────────────────────────────────────────────────────
if [[ -n "${POSTGRES_INSTANCE_DIR:-}" ]]; then
  INSTALL_DIR="${POSTGRES_INSTANCE_DIR%/}"
else
  mapfile -t INSTANCES < <(find "$PG_BASE" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' 2>/dev/null | sort)
  [ ${#INSTANCES[@]} -gt 0 ] || _die "no instances found in $PG_BASE."
  if [ ${#INSTANCES[@]} -eq 1 ]; then
    INSTALL_DIR="${INSTANCES[0]}"
  else
    echo ""
    for i in "${!INSTANCES[@]}"; do echo "  $((i+1))) $(basename "${INSTANCES[$i]}")"; done
    read -rp "Select instance number: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#INSTANCES[@]} ] || _die "Invalid selection."
    INSTALL_DIR="${INSTANCES[$((n-1))]}"
  fi
fi
ENV_FILE="$INSTALL_DIR/.env"
[ -f "$ENV_FILE" ] || _die "$ENV_FILE not found."
DOMAIN="$(_env_get "$ENV_FILE" PG_DOMAIN)"
[[ -n "$DOMAIN" ]] || _die "PG_DOMAIN is not set in $ENV_FILE."

dc() { docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
# Over the container's socket as the postgres OS user (pg_hba: local peer), so
# no password is involved. </dev/null keeps it off this script's stdin.
pg() { dc exec -T -u postgres postgres "$@" </dev/null; }

[ -n "$(dc ps -q --status running postgres 2>/dev/null)" ] || _die "the postgres service of $DOMAIN is not running."

if [[ "$LOCK_HELD" != true ]]; then
  exec 9>"$INSTALL_DIR/.lock"
  flock -w 600 9 || _die "another backup or restore of $DOMAIN is still running."
fi

STAMP="$(date +%Y-%m-%d-%H-%M-%S)"
DEST="$BACKUP_ROOT/postgres/$DOMAIN/$STAMP"
[ -e "$DEST" ] && _die "$DEST already exists."

if ! $UNATTENDED; then
  echo ""
  echo "Instance      : $DOMAIN ($INSTALL_DIR)"
  echo "Backup folder : $DEST"
  read -rp "Proceed with backup? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "$DEST/databases"

# ── 3. Roles ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Roles ==="
pg pg_dumpall --roles-only | gzip > "$DEST/roles.sql.gz"
_check "$DEST/roles.sql.gz" 'PostgreSQL database cluster dump complete'
echo "Saved: roles.sql.gz"

# ── 4. Databases ──────────────────────────────────────────────────────────────
echo ""
echo "=== Databases ==="
# Captured first rather than read through < <(...): a failed query has to stop
# the backup, not look like a server with no databases.
LIST="$(pg psql -X -At -F $'\t' -d postgres -c \
  "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1")"
ROWS=()
[[ -n "$LIST" ]] && mapfile -t ROWS <<< "$LIST"
: > "$DEST/databases.tsv"
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r db owner <<< "$row"
  [[ "$db" =~ ^[A-Za-z0-9_.-]+$ ]] || _die "database '$db' has a name this script cannot use as a file name - back it up by hand."
  pg pg_dump --create -d "$db" | gzip > "$DEST/databases/$db.sql.gz"
  _check "$DEST/databases/$db.sql.gz" 'PostgreSQL database dump complete'
  printf '%s\t%s\n' "$db" "$owner" >> "$DEST/databases.tsv"
  echo "Saved: databases/$db.sql.gz ($(du -h "$DEST/databases/$db.sql.gz" | cut -f1), owner $owner)"
done
[ ${#ROWS[@]} -gt 0 ] || echo "No app databases yet."

# ── 5. Config and certificates ────────────────────────────────────────────────
# server.key is readable by root and the container only, and the installer
# issues a new one from the CA anyway.
echo ""
echo "=== Config and certificates ==="
tar czf "$DEST/config.tar.gz" -C "$INSTALL_DIR" --exclude=certs/server.key \
  .env docker-compose.yml conf certs ca clients
echo "Saved: config.tar.gz"

# ── 6. Manifest and checksums ─────────────────────────────────────────────────
{
  echo "PostgreSQL backup manifest"
  echo "Created         : $(date -Iseconds)"
  echo "Type            : $SNAPSHOT_TYPE"
  echo "Domain          : $DOMAIN"
  echo "Instance        : $INSTALL_DIR"
  echo "Image           : $(docker inspect -f '{{.Config.Image}}' "$(dc ps -q postgres)")"
  echo "Server version  : $(pg psql -X -At -d postgres -c 'SHOW server_version')"
  echo "Databases       : ${#ROWS[@]}"
  for row in "${ROWS[@]}"; do printf '  %s (owner %s)\n' "${row%%$'\t'*}" "${row#*$'\t'}"; done
} > "$DEST/manifest.txt"
(cd "$DEST" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS)

# ── 7. Prune ──────────────────────────────────────────────────────────────────
if [ "$RETAIN_COUNT" -gt 0 ]; then
  mapfile -t OLD < <(find "$BACKUP_ROOT/postgres/$DOMAIN" -mindepth 1 -maxdepth 1 -type d \
    -name '????-??-??-??-??-??' | sort -r | tail -n +$((RETAIN_COUNT+1)))
  for o in "${OLD[@]}"; do
    echo "Pruning: $o"
    rm -rf "$o"
  done
fi

DONE=true
echo ""
echo "Backup complete: $DEST ($(du -sh "$DEST" | cut -f1))"
