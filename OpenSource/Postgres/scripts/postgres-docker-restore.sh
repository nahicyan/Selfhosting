#!/bin/bash
set -euo pipefail
# =============================================================================
# PostgreSQL (shared) Docker Restore Script
# =============================================================================
# Restores a postgres-docker-backup.sh snapshot into a running instance:
#   1) One database  - drops and recreates that database only; every other app
#                      is left alone. Its owner role must exist on the target
#                      (it does on the server the backup came from).
#   2) Everything    - roles first (password hashes and memberships as they
#                      were), then every database in the snapshot. The
#                      disaster-recovery path after install mode 2.
#
# The superuser "postgres" is never touched: its password stays whatever the
# target's .env says.
#
# Before anything is dropped, a full pre-restore snapshot is taken with
# postgres-docker-backup.sh into the same backup root, so a restore can itself
# be undone from this menu.
#
# Stop the apps that use the databases first. DROP DATABASE ... WITH (FORCE)
# disconnects them, and an app that reconnects mid-restore can run its own
# migrations against the half-loaded database.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BACKUP_ROOT="/home/backup"
PG_BASE="/var/www/docker/postgres"

DONE=false
SAFETY=""
PICK=0

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "Error: $*" >&2; exit 1; }

_env_get() {  # _env_get <file> <key>
  local v
  v="$(sed -n "s/^${2}=//p" "$1" | tail -n1)"
  if [[ "$v" == \'*\' || "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

_nice_date() {
  local yr mo dy hr mn sc
  IFS='-' read -r yr mo dy hr mn sc <<< "$1"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$1"
}

_pick() {  # _pick <prompt> <count> - sets PICK to the chosen 0-based index
  local n
  read -rp "$1" n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$2" ] || _die "Invalid selection."
  PICK=$((n-1))
}

_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$DONE" != true && -n "$SAFETY" ]]; then
    echo "" >&2
    echo "Restore failed (exit $rc). The state from just before it is in:" >&2
    echo "  $SAFETY" >&2
    echo "Run this script again and pick that snapshot to go back." >&2
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=====> PostgreSQL Restore"
echo "========================================"

for cmd in docker gzip sed find sort sha256sum flock; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
[ -x "$SCRIPT_DIR/postgres-docker-backup.sh" ] || _die "postgres-docker-backup.sh not found next to this script."

# ── 1. Snapshot ───────────────────────────────────────────────────────────────
echo "Choose the directory where your backups are located:"
echo "  1) Default: $DEFAULT_BACKUP_ROOT"
echo "  2) Custom path"
read -rp "Select [1/2]: " ans
if [ "$ans" = "2" ]; then
  read -rep "Enter custom backup base path: " BACKUP_ROOT
  BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
else
  BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
fi
BACKUP_ROOT="${BACKUP_ROOT%/}"
[ -d "$BACKUP_ROOT/postgres" ] || _die "'$BACKUP_ROOT/postgres' not found."

mapfile -t DOMAIN_DIRS < <(find "$BACKUP_ROOT/postgres" -mindepth 1 -maxdepth 1 -type d | sort)
[ ${#DOMAIN_DIRS[@]} -gt 0 ] || _die "no backups found in '$BACKUP_ROOT/postgres'."
if [ ${#DOMAIN_DIRS[@]} -eq 1 ]; then
  DOMAIN_DIR="${DOMAIN_DIRS[0]}"
else
  echo ""
  for i in "${!DOMAIN_DIRS[@]}"; do echo "  $((i+1))) $(basename "${DOMAIN_DIRS[$i]}")"; done
  _pick "Select domain number: " ${#DOMAIN_DIRS[@]}
  DOMAIN_DIR="${DOMAIN_DIRS[$PICK]}"
fi

mapfile -t SNAPS < <(find "$DOMAIN_DIR" -mindepth 2 -maxdepth 2 -name SHA256SUMS -printf '%h\n' | sort -r)
[ ${#SNAPS[@]} -gt 0 ] || _die "no snapshots in '$DOMAIN_DIR'."
echo ""
echo "Snapshots for $(basename "$DOMAIN_DIR"):"
printf "  %-4s %-30s %-10s %-6s %s\n" "#" "Date" "Databases" "Roles" "Note"
for i in "${!SNAPS[@]}"; do
  S="${SNAPS[$i]}"
  dbs="$(wc -l < "$S/databases.tsv" 2>/dev/null || echo "?")"
  roles="$([ -f "$S/roles.sql.gz" ] && echo ok || echo --)"
  note="$(grep -q '^Type *: pre-restore' "$S/manifest.txt" 2>/dev/null && echo pre-restore || true)"
  printf "  %-4s %-30s %-10s %-6s %s\n" "$((i+1)))" "$(_nice_date "$(basename "$S")")" "$dbs" "$roles" "$note"
done
_pick "Select snapshot number: " ${#SNAPS[@]}
SNAP="${SNAPS[$PICK]}"

echo "Verifying checksums..."
(cd "$SNAP" && sha256sum --quiet -c SHA256SUMS) || _die "$SNAP failed its checksum test - pick another snapshot."

# ── 2. What to restore ────────────────────────────────────────────────────────
mapfile -t ROWS < "$SNAP/databases.tsv"
echo ""
echo "What do you want to restore?"
echo "  1) One database        (drops and recreates just that one)"
echo "  2) Everything          (roles, then all ${#ROWS[@]} database(s) - disaster recovery)"
read -rp "Select [1/2]: " ACTION
case "$ACTION" in
  1)
    [ ${#ROWS[@]} -gt 0 ] || _die "this snapshot has no databases."
    echo ""
    for i in "${!ROWS[@]}"; do echo "  $((i+1))) ${ROWS[$i]%%$'\t'*}  (owner ${ROWS[$i]#*$'\t'})"; done
    _pick "Select database number: " ${#ROWS[@]}
    ROWS=("${ROWS[$PICK]}")
    ;;
  2) [ -f "$SNAP/roles.sql.gz" ] || _die "this snapshot has no roles.sql.gz." ;;
  *) _die "Invalid selection." ;;
esac

# ── 3. Target instance ────────────────────────────────────────────────────────
mapfile -t INSTANCES < <(find "$PG_BASE" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' 2>/dev/null | sort)
[ ${#INSTANCES[@]} -gt 0 ] || _die "no instances found in $PG_BASE - install one first (postgres-docker-install.sh)."
if [ ${#INSTANCES[@]} -eq 1 ]; then
  INSTALL_DIR="${INSTANCES[0]}"
else
  echo ""
  for i in "${!INSTANCES[@]}"; do echo "  $((i+1))) $(basename "${INSTANCES[$i]}")"; done
  _pick "Select instance number to restore INTO: " ${#INSTANCES[@]}
  INSTALL_DIR="${INSTANCES[$PICK]}"
fi
ENV_FILE="$INSTALL_DIR/.env"
[ -f "$ENV_FILE" ] || _die "$ENV_FILE not found."
TARGET="$(_env_get "$ENV_FILE" PG_DOMAIN)"

dc() { docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
# psql and friends over the container's socket as the postgres OS user.
pg()   { dc exec -T -u postgres postgres "$@" </dev/null; }   # no input
pgin() { dc exec -T -u postgres postgres "$@"; }              # reads stdin
sql()  { pgin psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }

[ -n "$(dc ps -q --status running postgres 2>/dev/null)" ] || _die "the postgres service of $TARGET is not running."

if [[ "$ACTION" == 1 ]]; then
  owner="${ROWS[0]#*$'\t'}"
  found="$(echo "SELECT 1 FROM pg_roles WHERE rolname = :'r';" | sql -At -v r="$owner")"
  [[ "$found" == 1 ]] || _die "role '$owner' does not exist on $TARGET. Create it first, or restore option 2 (everything)."
fi

# ── 4. Confirm ────────────────────────────────────────────────────────────────
echo ""
echo "==================== RESTORE SUMMARY ===================="
echo "Snapshot        : $SNAP"
echo "Target instance : $TARGET ($INSTALL_DIR)"
echo "Restoring       :"
[[ "$ACTION" == 2 ]] && echo "  - roles (all but postgres), passwords as at backup time"
for row in "${ROWS[@]}"; do echo "  - database ${row%%$'\t'*} (owner ${row#*$'\t'})"; done
echo "========================================================="
echo ""
echo "WARNING: every database listed is DROPPED and replaced from the snapshot."
echo "         Stop the apps that use them first."
echo ""
read -rp "Type 'yes' to confirm and proceed: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Restore cancelled."; exit 0; }

exec 9>"$INSTALL_DIR/.lock"
flock -w 600 9 || _die "another backup or restore of $TARGET is still running."

# ── 5. Pre-restore snapshot ───────────────────────────────────────────────────
# KEEP=0: pruning here could delete the very snapshot being restored.
echo ""
echo "=== Pre-restore snapshot of $TARGET ==="
POSTGRES_BACKUP_ROOT="$BACKUP_ROOT" POSTGRES_INSTANCE_DIR="$INSTALL_DIR" POSTGRES_BACKUP_KEEP=0 \
POSTGRES_BACKUP_TYPE="pre-restore safety snapshot" POSTGRES_BACKUP_LOCK_HELD=true \
  "$SCRIPT_DIR/postgres-docker-backup.sh" </dev/null >/dev/null \
  || _die "the pre-restore snapshot failed - nothing was changed."
SAFETY="$(find "$BACKUP_ROOT/postgres/$TARGET" -mindepth 1 -maxdepth 1 -type d -name '????-??-??-??-??-??' | sort | tail -n1)"
echo "Saved: $SAFETY"

# ── 6. Roles ──────────────────────────────────────────────────────────────────
# CREATE ROLE fails on a role that already exists, so each one is wrapped to
# skip that case; the ALTER ROLE after it sets attributes and password either
# way. The superuser's lines are dropped so its password stays .env's.
if [[ "$ACTION" == 2 ]]; then
  echo ""
  echo "=== Roles ==="
  gzip -cd "$SNAP/roles.sql.gz" \
    | sed -e '/^\(CREATE\|ALTER\) ROLE postgres[ ;]/d' \
          -e 's/^CREATE ROLE \(.*\);$/DO $do$ BEGIN CREATE ROLE \1; EXCEPTION WHEN duplicate_object THEN NULL; END $do$;/' \
    | sql --single-transaction >/dev/null
  echo "Restored: roles"
fi

# ── 7. Databases ──────────────────────────────────────────────────────────────
# DROP DATABASE cannot run in a transaction, and each dump carries its own
# CREATE DATABASE (owner, encoding, grants) and \connect.
for row in "${ROWS[@]}"; do
  db="${row%%$'\t'*}"
  echo ""
  echo "=== Database $db ==="
  echo 'DROP DATABASE IF EXISTS :"db" WITH (FORCE);' | sql -v db="$db"
  gzip -cd "$SNAP/databases/$db.sql.gz" | sql >/dev/null
  pg vacuumdb --analyze-only --quiet -d "$db"
  echo "Restored: $db"
done

DONE=true
echo ""
echo "Restore complete. Start the apps again."
echo "Undo with the pre-restore snapshot: $SAFETY"
