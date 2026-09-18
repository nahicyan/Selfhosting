#!/bin/bash
set -euo pipefail
# =============================================================================
# Bitwarden management script
# =============================================================================
# Installed next to ./bwdata by bitwarden-docker-install.sh (copied as
# <install-dir>/manage.sh). Mirrors what Bitwarden's own bitwarden.sh / run.sh
# do, using the same official images and the same `Setup` commands, minus the
# interactive installer:
#
#   rebuild   regenerate bwdata/docker, nginx, env from config.yml
#   updatedb  start mssql and run the database migrator
#   update    new versions -> rebuild -> pull -> migrate -> start
#   ...       see `./manage.sh help`
#
# State lives in <install-dir>/bitwarden.conf (versions + domain + port).
# =============================================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_die() { echo "ERROR: $*" >&2; exit 1; }

# Normally this file is the copy in <install-dir>/manage.sh. When run from the
# repo instead, use $BITWARDEN_DIR, or the single instance found under the
# default base path.
if [ ! -f "$DIR/bitwarden.conf" ]; then
  if [ -n "${BITWARDEN_DIR:-}" ]; then
    DIR="${BITWARDEN_DIR%/}"
  else
    mapfile -t _found < <(find /var/www/docker/bitwarden -maxdepth 2 -name bitwarden.conf -exec dirname {} \; 2>/dev/null | sort -u)
    [ "${#_found[@]}" -eq 1 ] || _die "bitwarden.conf not found next to this script. Run <install-dir>/manage.sh, or set BITWARDEN_DIR=<install-dir>."
    DIR="${_found[0]}"
  fi
fi
BWDATA="$DIR/bwdata"
CONF="$DIR/bitwarden.conf"
COMPOSE_FILE="$BWDATA/docker/docker-compose.yml"
REGISTRY="ghcr.io/bitwarden"
VERSIONS_URL="https://go.btwrdn.com/bw-sh-versions"

[ "$(id -u)" -ne 0 ] || _die "Do not run Bitwarden as root (see Bitwarden's install docs). Run as a user in the docker group."
command -v docker >/dev/null 2>&1 || _die "'docker' is required."
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
[ -f "$CONF" ] || _die "$CONF not found - run bitwarden-docker-install.sh first."
# shellcheck disable=SC1090
source "$CONF"

_save_conf() {
  cat > "$CONF" <<CONF_EOF
# Written by bitwarden-docker-install.sh / manage.sh update - do not edit by hand.
DOMAIN=$DOMAIN
PORT=$PORT
CORE_VERSION=$CORE_VERSION
WEB_VERSION=$WEB_VERSION
KEYCONNECTOR_VERSION=$KEYCONNECTOR_VERSION
CONF_EOF
}

# Reads the current release versions from Bitwarden's version endpoint (the
# same one bitwarden.sh uses). Sets CORE_VERSION / WEB_VERSION /
# KEYCONNECTOR_VERSION; returns 1 if it can't be read.
fetch_versions() {
  local json core web kc
  json="$(curl -fsS --max-time 20 "$VERSIONS_URL" 2>/dev/null | tr -d '\n')" || return 1
  _field() { printf '%s' "$json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
  core="$(_field coreVersion)"; web="$(_field webVersion)"; kc="$(_field keyConnectorVersion)"
  [[ -n "$core" && -n "$web" && -n "$kc" ]] || return 1
  CORE_VERSION="$core"; WEB_VERSION="$web"; KEYCONNECTOR_VERSION="$kc"
}

# Runs the official Setup tool (ghcr.io/bitwarden/setup) against ./bwdata.
# Extra docker options come first, then the /app/Setup arguments after "--".
setup_run() {
  local docker_opts=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do docker_opts+=("$1"); shift; done
  shift
  docker run --rm --name bitwarden-setup \
    -v "$BWDATA:/bitwarden" --env-file "$BWDATA/env/uid.env" \
    "${docker_opts[@]}" \
    "$REGISTRY/setup:$CORE_VERSION" /app/Setup "$@"
}

# Like run.sh: an optional docker-compose.override.yml next to the generated
# file is merged in (with -f, Compose does not pick it up on its own).
dc() {
  local files=(-f "$COMPOSE_FILE")
  [ -f "$BWDATA/docker/docker-compose.override.yml" ] && files+=(-f "$BWDATA/docker/docker-compose.override.yml")
  docker compose "${files[@]}" "$@"
}

cmd_rebuild() {
  docker pull "$REGISTRY/setup:$CORE_VERSION" >/dev/null
  setup_run --network host -- -update 1 -os lin \
    -corev "$CORE_VERSION" -webv "$WEB_VERSION" -keyconnectorv "$KEYCONNECTOR_VERSION"
}

cmd_updatedb() {
  echo "==> Starting mssql..."
  dc up -d mssql
  echo -n "==> Waiting for mssql to become healthy"
  local status
  for _ in $(seq 1 90); do
    status="$(docker inspect -f '{{.State.Health.Status}}' bitwarden-mssql 2>/dev/null || echo starting)"
    [ "$status" = "healthy" ] && break
    echo -n "."
    sleep 2
  done
  echo ""
  [ "$status" = "healthy" ] || _die "bitwarden-mssql did not become healthy - check: docker logs bitwarden-mssql"
  echo "==> Running database migrations..."
  setup_run --network container:bitwarden-mssql -- -update 1 -db 1 -os lin \
    -corev "$CORE_VERSION" -webv "$WEB_VERSION" -keyconnectorv "$KEYCONNECTOR_VERSION"
}

cmd_backup() {
  docker ps --format '{{.Names}}' | grep -qx bitwarden-mssql \
    || _die "bitwarden-mssql is not running - start Bitwarden first."
  docker exec bitwarden-mssql /backup-db.sh
  echo "==> Backup written to $BWDATA/mssql/backups"
}

cmd_update() {
  if fetch_versions; then
    echo "==> Versions: core $CORE_VERSION, web $WEB_VERSION, key-connector $KEYCONNECTOR_VERSION"
  else
    _die "Could not read $VERSIONS_URL - nothing changed."
  fi
  if docker ps --format '{{.Names}}' | grep -qx bitwarden-mssql; then
    echo "==> Backing up the database first..."
    cmd_backup
  fi
  echo "==> Stopping Bitwarden..."
  dc down || true
  cmd_rebuild
  _save_conf
  dc pull
  cmd_updatedb
  dc up -d
  echo "==> Updated to core $CORE_VERSION / web $WEB_VERSION."
}

cmd_status() {
  dc ps
  echo ""
  curl -s -o /dev/null -w "http://127.0.0.1:$PORT/alive -> %{http_code}\n" --max-time 5 \
    "http://127.0.0.1:$PORT/alive" || true
}

cmd_help() {
  cat <<HELP_EOF
Usage: ./manage.sh <command>

  start      Start all containers
  stop       Stop all containers
  restart    Stop, then start all containers
  status     Container state and local health probe
  logs [svc] Follow logs (optionally one service, e.g. api, identity, mssql)
  update     Fetch latest versions, back up, rebuild, pull, migrate, start
  rebuild    Regenerate bwdata assets from bwdata/config.yml (then restart)
  updatedb   Start mssql and run the database migrator
  backup     Create a database backup in bwdata/mssql/backups
  help       This text
HELP_EOF
}

case "${1:-help}" in
  start)    dc up -d ;;
  stop)     dc down ;;
  restart)  dc down; dc up -d ;;
  status)   cmd_status ;;
  logs)     shift; dc logs -f --tail=100 "$@" ;;
  update)   cmd_update ;;
  rebuild)  cmd_rebuild; echo "==> Done. Apply with: ./manage.sh restart" ;;
  updatedb) cmd_updatedb ;;
  backup)   cmd_backup ;;
  help|-h|--help) cmd_help ;;
  *) cmd_help; exit 1 ;;
esac
