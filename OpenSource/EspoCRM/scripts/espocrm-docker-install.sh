#!/bin/bash
set -euo pipefail
# =============================================================================
# EspoCRM Docker Install Script
# =============================================================================
# Deploys EspoCRM for production with the official image (espocrm/espocrm,
# Apache variant) and the Docker Compose setup EspoCRM documents for
# production, behind a host Nginx reverse proxy:
#   https://docs.espocrm.com/administration/docker/installation/#docker-compose
#
#   <install-dir>/                default /var/www/docker/espocrm/<domain>
#     |-- docker-compose.yml      copied from this repo (../docker-compose.yml)
#     `-- .env                    written here (mode 600) - every value the
#                                 compose file reads, passwords included
#
# Four containers: espocrm (Apache + PHP), espocrm-db (MariaDB), espocrm-daemon
# (scheduled jobs, which replaces cron) and espocrm-websocket (real-time
# updates). State lives in four named volumes:
#   <project>_espocrm-db             MariaDB data
#   <project>_espocrm-data           /var/www/html/data - config, uploads, logs
#   <project>_espocrm-custom         /var/www/html/custom - customizations
#   <project>_espocrm-custom-client  /var/www/html/client/custom
# That is the EspoCRM 10 layout. The espocrm-docker README still mounts all of
# /var/www/html, which the v10 entrypoint treats as legacy and stops upgrading.
#
# The app is published on 127.0.0.1:<port> and the WebSocket server on
# 127.0.0.1:<ws-port>. Nginx terminates TLS and proxies / and /wss to them.
#
# The first start installs EspoCRM from the ESPOCRM_* variables: database
# connection, admin account, site URL, time zone. The image's entrypoint does
# this once, when the database is empty, and afterwards only runs migrations.
# So this script installs into a fresh directory and fresh volumes only, and
# refuses to reuse volumes left over from an earlier install with the same
# domain. An old database volume would keep its old passwords, and the new
# .env could not log in.
#
# Three upstream behaviours the setup works around:
#   - The admin username is fixed to "admin". The v10 entrypoint runs
#     `create-admin-user $ESPOCRM_ADMIN_USERNAME` but then
#     `set-password admin`, so any other name fails the install, which
#     then crash-loops.
#   - Image tags are pinned (ESPOCRM_VERSION in .env). EspoCRM migrates its
#     database on every start, so the docs' :latest turns any `pull` into an
#     upgrade nobody chose.
#   - The docs' healthcheck (app-check) passes seconds into the first start,
#     while the install is still running. The daemon and websocket then start
#     mid-install and race it writing data/config.php. The compose file's
#     healthcheck also requires Apache to answer, and this script starts those
#     two only once the web port answers.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../espocrm-nginx.conf"
COMPOSE_SRC="$SCRIPT_DIR/../docker-compose.yml"

DEFAULT_BASE="/var/www/docker/espocrm"
DEFAULT_PORT="8100"           # placeholder port in espocrm-nginx.conf
NGINX_WS_PLACEHOLDER="8101"   # placeholder WebSocket port in espocrm-nginx.conf
MARIADB_VERSION="12.3"        # current MariaDB LTS (Docker Hub's mariadb:lts)
MIN_MAJOR=10                  # the v10 volume layout the compose file uses
HUB_TAGS="https://hub.docker.com/v2/repositories/espocrm/espocrm/tags"

STARTED=false   # true from creating the install dir until the stack is up
INSTALL_DIR=""

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

# A failure between creating the install dir and a running stack leaves a
# half-made instance, which a re-run refuses (dir not empty, volumes exist).
_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$STARTED" == "true" ]]; then
    echo "" >&2
    echo "The install did not finish. $INSTALL_DIR is left as it is. To start over:" >&2
    echo "  (cd $INSTALL_DIR && docker compose down -v) && rm -rf $INSTALL_DIR" >&2
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT    # so Ctrl-C still runs _on_exit
trap 'exit 143' TERM

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_port_in_use() {
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

_check_port_free() {  # _check_port_free <port>
  if _port_in_use "$1"; then
    echo ""
    echo "WARNING: something is already listening on port $1:"
    ss -ltnp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" || true
    read -rp "Continue anyway? [y/N] " ans_port
    [[ "$ans_port" =~ ^[Yy]$ ]] || _die "Aborted - pick a free port."
  fi
}

_mask() { [[ -n "${1:-}" ]] && echo "(set, ${#1} chars)" || echo "(empty)"; }

# The admin password goes into .env single-quoted (Compose takes it literally),
# and the entrypoint pipes it to `bin/command set-password`. No quotes, $, #,
# backslashes or spaces, so the value never needs escaping and a future backup
# script can `source` .env safely.
_valid_secret() {
  [[ "$1" =~ ^[A-Za-z0-9._~@!?*:-]{8,128}$ ]]
}

_gen_secret() { openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

# _ask_secret <var-name> <label> - prompt silently: blank input generates a
# strong value, anything else must be confirmed and pass _valid_secret.
_ask_secret() {
  local -n _ref="$1"
  local label="$2" first second
  while :; do
    read -rsp "  ${label} (blank = generate a strong one): " first; echo
    if [[ -z "$first" ]]; then
      _ref="$(_gen_secret)"
      echo "    Generated: ${_ref}"
      return 0
    fi
    read -rsp "  Confirm ${label}: " second; echo
    if [[ "$first" != "$second" ]]; then
      echo "    Values do not match - try again."
      continue
    fi
    if ! _valid_secret "$first"; then
      echo "    Rejected. Use 8-128 characters from: A-Z a-z 0-9 . _ ~ - @ ! ? * :"
      continue
    fi
    _ref="$first"
    return 0
  done
}

# Newest X.Y.Z tag of espocrm/espocrm on Docker Hub, or nothing.
_latest_version() {
  curl -fsSL --max-time 15 "$HUB_TAGS?page_size=100&ordering=last_updated" 2>/dev/null \
    | grep -oE '"name":"[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V | tail -n1 || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
# Docker first: every step below runs through it.
command -v docker >/dev/null 2>&1 \
  || _die "Docker is not installed. Install Docker Engine (https://docs.docker.com/engine/install/), then run this script again."
docker compose version >/dev/null 2>&1 \
  || _die "the Docker Compose plugin ('docker compose') is not installed. Install it (https://docs.docker.com/compose/install/linux/), then run this script again."
docker info >/dev/null 2>&1 \
  || _die "cannot reach the Docker daemon - is it running, and is $(id -un) in the docker group?"
for cmd in curl openssl ss awk sed grep sort stat; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
[ -f "$COMPOSE_SRC" ]    || _die "docker-compose.yml not found at $COMPOSE_SRC"
[ -f "$NGINX_CONF_SRC" ] || _die "espocrm-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> EspoCRM Install"
echo "========================================"
echo "Compose source: $COMPOSE_SRC"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────
# Confirmed by the person running this: the Nginx site expects the certificate
# in /etc/letsencrypt/live/<domain>/, and certbot only issues it once the DNS
# record points here.
echo "Before you continue, make sure that:"
echo "  1. A DNS record for the EspoCRM domain points at this server."
echo "  2. A Let's Encrypt certificate for the EspoCRM domain exists in"
echo "     /etc/letsencrypt/live/<domain>/."
echo ""
read -rp "Type 'yes' to confirm both and continue: " ans_prereq
[[ "${ans_prereq,,}" == "yes" ]] || _die "Aborted - set these up first, then run this script again."
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
echo "EspoCRM builds every link it sends (emails, notifications, portals) from this"
echo "name, so it must be the public name users open."
read -rp "Enter domain name (e.g. crm.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"   # hostnames are case-insensitive; the compose project name must be lowercase

# Compose names every container and volume after this, so it is fixed per
# domain whatever the install directory is.
PROJECT_NAME="espocrm-${domain//./-}"

# ── Leftovers from an earlier install with this domain ────────────────────────
if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME")" ]; then
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '  {{.Names}}  ({{.Status}})'
  _die "containers of Compose project '$PROJECT_NAME' already exist (above). Remove that instance first."
fi
mapfile -t OLD_VOLUMES < <(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME")
if [ ${#OLD_VOLUMES[@]} -gt 0 ]; then
  printf '  %s\n' "${OLD_VOLUMES[@]}"
  echo "These volumes are left from an earlier install with this domain. EspoCRM would"
  echo "start on the old database, with its old passwords, and fail to connect."
  echo "If you no longer need that data:  docker volume rm ${OLD_VOLUMES[*]}"
  _die "volumes of Compose project '$PROJECT_NAME' already exist."
fi

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
echo "EspoCRM will be installed into a per-domain directory (docker-compose.yml + .env)."
read -rp "Install directory [$DEFAULT_BASE/$domain]: " answer
INSTALL_DIR="${answer:-$DEFAULT_BASE/$domain}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
INSTALL_DIR="${INSTALL_DIR%/}"
[[ "$INSTALL_DIR" = /* ]] || _die "Install directory must be an absolute path."
if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  _die "$INSTALL_DIR already exists and is not empty - remove it first, or choose another path."
fi

# ── 3. Host ports ─────────────────────────────────────────────────────────────
echo ""
echo "EspoCRM is published on 127.0.0.1:<port> and proxied by Nginx."
read -rp "Host port [$DEFAULT_PORT]: " answer
port="${answer:-$DEFAULT_PORT}"
_valid_port "$port" || _die "Port must be a number between 1 and 65535."
_check_port_free "$port"

echo ""
echo "The WebSocket server (real-time notifications) gets its own loopback port;"
echo "Nginx proxies https://<domain>/wss to it."
default_ws_port=$(( port < 65535 ? port + 1 : port - 1 ))
read -rp "WebSocket host port [$default_ws_port]: " answer
ws_port="${answer:-$default_ws_port}"
_valid_port "$ws_port" || _die "Port must be a number between 1 and 65535."
[ "$ws_port" != "$port" ] || _die "The WebSocket port must differ from the web port ($port)."
_check_port_free "$ws_port"

# ── 4. EspoCRM version ────────────────────────────────────────────────────────
# An exact version (10.0.9) is the production choice: upgrades happen when
# ESPOCRM_VERSION in .env is changed, not on whatever day an image is pulled.
# A major or minor tag (10, 10.0) is accepted too, for those who want
# `docker compose pull` to bring in patch releases.
echo ""
latest="$(_latest_version)"
if [[ -n "$latest" ]]; then
  read -rp "EspoCRM version [$latest]: " version
  version="${version:-$latest}"
else
  echo "Could not look up the latest version on Docker Hub."
  read -rp "EspoCRM version (e.g. 10.0.9): " version
fi
[[ -n "$version" ]] || _die "Version cannot be empty."
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}(-apache(-[a-z0-9]+)?)?$ ]] \
  || _die "'$version' is not an EspoCRM Apache image tag (e.g. 10.0.9, 10.0.9-apache). fpm variants need a separate web server and are not supported here."
major="${version%%[.-]*}"
(( major >= MIN_MAJOR )) || _die "EspoCRM $version is older than $MIN_MAJOR. This setup uses the EspoCRM $MIN_MAJOR+ volume layout."

tag_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$HUB_TAGS/$version" 2>/dev/null || true)"
case "$tag_code" in
  200) ;;
  404) _die "espocrm/espocrm:$version does not exist on Docker Hub." ;;
  *)   echo "WARNING: could not check espocrm/espocrm:$version on Docker Hub (HTTP ${tag_code:-000}); the pull will tell." ;;
esac

# ── 5. Time zone ──────────────────────────────────────────────────────────────
# Applied at install time only (Administration > Settings afterwards).
echo ""
default_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[[ -n "$default_tz" ]] || default_tz="$(cat /etc/timezone 2>/dev/null || true)"
[[ -n "$default_tz" ]] || default_tz="UTC"
read -rp "Time zone [$default_tz]: " answer
tz="${answer:-$default_tz}"
case "$tz" in Etc/UTC|Etc/Universal|Universal|Zulu) tz="UTC" ;; esac   # EspoCRM's list knows "UTC"
[[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ ]] || _die "'$tz' is not a valid time zone name."
if [ "$tz" != "UTC" ] && [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$tz" ]; then
  _die "'$tz' is not a known time zone (e.g. America/Chicago, Europe/Berlin, UTC)."
fi

# ── 6. Admin password ─────────────────────────────────────────────────────────
admin_password=""
echo ""
echo "==> Administrator account (username: admin)"
echo "    The password is only applied on the first start. After that it lives in"
echo "    the database and is changed in the UI."
_ask_secret admin_password "Admin password"

# ── Derived values ────────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
db_password="$(openssl rand -hex 24)"
db_root_password="$(openssl rand -hex 24)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "URL             : https://$domain"
echo "Install dir     : $INSTALL_DIR"
echo "Host port       : 127.0.0.1:$port  ->  espocrm :80"
echo "WebSocket port  : 127.0.0.1:$ws_port  ->  espocrm-websocket :8080  (https://$domain/wss)"
echo "Compose project : $PROJECT_NAME"
echo "EspoCRM image   : espocrm/espocrm:$version"
echo "MariaDB image   : mariadb:$MARIADB_VERSION"
echo "Time zone       : $tz"
echo "Admin user      : admin"
echo "Admin password  : $(_mask "$admin_password")"
echo "DB passwords    : generated (espocrm user + MariaDB root, stored in .env)"
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Create the install directory ──────────────────────────────────────────────
# sudo only when the parent is not writable (the default /var/www/docker is
# usually root's).
echo ""
echo "==> Creating $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
if [ "$(stat -c %u "$INSTALL_DIR")" != "$(id -u)" ]; then
  sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
fi
chmod 750 "$INSTALL_DIR"
STARTED=true
cd "$INSTALL_DIR"

cp "$COMPOSE_SRC" "$COMPOSE_FILE"
echo "==> docker-compose.yml copied to $COMPOSE_FILE"

# ── Write .env ────────────────────────────────────────────────────────────────
echo "==> Writing .env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<ENV_EOF
# EspoCRM instance configuration - generated by espocrm-docker-install.sh
# Read by 'docker compose' from this directory for interpolation into
# docker-compose.yml. Holds the database and admin passwords: keep it mode 600
# and back it up with the data.
# Secrets are single-quoted: literal for both Compose and bash's \`source\`.

COMPOSE_PROJECT_NAME=$PROJECT_NAME

# Public hostname, no scheme. docker-compose.yml builds the site URL
# (https://$domain) and the WebSocket URL (wss://$domain/wss) from it.
# siteUrl is re-applied on every start, so changing this works - also update
# the Nginx vhost and certificate.
ESPOCRM_DOMAIN=$domain

# Loopback host ports the Nginx vhost proxies to.
ESPOCRM_PORT=$port
ESPOCRM_WS_PORT=$ws_port

# Image tags. EspoCRM migrates the database on start, so upgrading is: back up,
# change ESPOCRM_VERSION, then  docker compose pull && docker compose up -d
# MariaDB: stay on an LTS line; MARIADB_AUTO_UPGRADE handles the data upgrade.
ESPOCRM_VERSION=$version
MARIADB_VERSION=$MARIADB_VERSION

# First start only (empty database). Changing these afterwards does nothing:
# the admin password lives in the database (change it in the UI), and the
# time zone is under Administration > Settings.
ESPOCRM_TIME_ZONE=$tz
ESPOCRM_ADMIN_PASSWORD='$admin_password'

# MariaDB. The espocrm user's password is also written into EspoCRM's
# data/config-internal.php on the first start; to change it later, change it
# in MariaDB, there, and here.
ESPOCRM_DATABASE_PASSWORD='$db_password'
MARIADB_ROOT_PASSWORD='$db_root_password'
ENV_EOF
echo "==> .env written to $ENV_FILE (mode 600)"

# ── Validate before starting anything ─────────────────────────────────────────
echo "==> Validating docker-compose.yml against .env..."
docker compose config --quiet || _die "docker-compose.yml did not validate with this .env."
echo "    OK"

# ── Review ────────────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit .env? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$ENV_FILE"

read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$COMPOSE_FILE"

# ── Pull ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Pulling images..."
docker compose pull

# ── First start: database + app ───────────────────────────────────────────────
# Started on their own first. The daemon and websocket containers wait for the
# app to be healthy, and a plain `docker compose up -d` would block on that
# with no way to notice a crash-looping install. Here the script watches it.
#
# Ready = Apache answers on the published port. The entrypoint runs the install
# and only then execs Apache, so that is the moment the install is done (and it
# proves the port mapping). The healthcheck alone can turn healthy earlier.
echo "==> Starting MariaDB and EspoCRM (the first start installs EspoCRM)..."
docker compose up -d espocrm
APP_CID="$(docker compose ps -aq espocrm)"
[[ -n "$APP_CID" ]] || _die "the espocrm container was not created."

echo -n "==> Waiting for the install to finish"
APP_STATE=""
app_status="" app_restarts=0 app_health=""
for _ in $(seq 1 120); do   # 10 minutes
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null || true)"
  if [[ "$CODE" =~ ^[0-9]{3}$ && "$CODE" != "000" && "$CODE" -lt 500 ]]; then
    APP_STATE="up"
    break
  fi
  read -r app_status app_restarts app_health <<< \
    "$(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$APP_CID" 2>/dev/null || echo "missing 0 none")"
  # The entrypoint's install cannot be re-run once it has created the admin
  # user, so repeated restarts mean it failed. Stop waiting.
  if [[ "$app_restarts" -ge 2 || "$app_health" == "unhealthy" || "$app_status" == "missing" ]]; then
    APP_STATE="failed"
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

if [[ "$APP_STATE" != "up" ]]; then
  echo ""
  echo "---- last 40 lines of the espocrm log ----"
  docker compose logs --no-color --tail 40 espocrm 2>&1 || true
  echo "------------------------------------------"
  if [[ "$APP_STATE" == "failed" ]]; then
    _die "EspoCRM failed to install (container: $app_status, restarts: $app_restarts, health: $app_health)."
  fi
  _die "EspoCRM did not become healthy within 10 minutes. Follow it with: cd $INSTALL_DIR && docker compose logs -f espocrm"
fi
echo "==> EspoCRM is installed - http://127.0.0.1:$port answers (HTTP $CODE)."

# ── Start the daemon and WebSocket server ─────────────────────────────────────
# `up` waits for the app's healthcheck (within a minute) before starting them.
echo "==> Starting espocrm-daemon and espocrm-websocket..."
docker compose up -d
STARTED=false   # the stack is running: a failure from here on leaves a working install to fix, not to delete

# ── Verify ────────────────────────────────────────────────────────────────────
# The WebSocket server answers a plain HTTP request with an HTTP error, which is
# enough to show it is listening.
WS_UP=false
for _ in $(seq 1 24); do   # 2 minutes
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${ws_port}/" 2>/dev/null || true)"
  if [[ "$CODE" =~ ^[0-9]{3}$ && "$CODE" != "000" ]]; then WS_UP=true; break; fi
  sleep 5
done
if $WS_UP; then
  echo "==> Socket  : 127.0.0.1:$ws_port is listening"
else
  echo "WARNING: nothing answers on 127.0.0.1:$ws_port yet. Check: docker compose logs espocrm-websocket"
fi

if [ -n "$(docker compose ps -q --status running espocrm-daemon)" ]; then
  echo "==> Daemon  : running (scheduled jobs)"
else
  echo "WARNING: espocrm-daemon is not running - scheduled jobs (email fetching, reminders) will not run."
  echo "         Check: docker compose logs espocrm-daemon"
fi

# Docker-published ports bypass ufw, so make sure nothing ended up on 0.0.0.0.
for pair in "espocrm 80 $port" "espocrm-websocket 8080 $ws_port"; do
  read -r svc cport hport <<< "$pair"
  published="$(docker compose port "$svc" "$cport" 2>/dev/null || true)"
  if [[ "$published" != "127.0.0.1:$hport" ]]; then
    echo "WARNING: $svc:$cport is published on '${published:-nothing}', expected 127.0.0.1:$hport."
  fi
done

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
echo ""
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
fi

# ── Nginx reverse proxy ───────────────────────────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$domain"

  if [ -e "$NGINX_AVAIL" ]; then
    read -rp "$NGINX_AVAIL already exists. Overwrite it? [y/N] " ans_over
    [[ "$ans_over" =~ ^[Yy]$ ]] || _die "Aborted - left $NGINX_AVAIL untouched. EspoCRM itself is running."
  fi

  # Ports go through tokens first: substituting 8100 -> 8101 directly would
  # have the WebSocket expression rewrite it a second time.
  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|crm\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:${DEFAULT_PORT}|127.0.0.1:__ESPOCRM_PORT__|g" \
    -e "s|127\.0\.0\.1:${NGINX_WS_PLACEHOLDER}|127.0.0.1:__ESPOCRM_WS_PORT__|g" \
    -e "s|__ESPOCRM_PORT__|$port|g" \
    -e "s|__ESPOCRM_WS_PORT__|$ws_port|g" \
    "$NGINX_AVAIL"
  if ! grep -q "proxy_pass http://127.0.0.1:$port;" "$NGINX_AVAIL" \
     || ! grep -q "proxy_pass http://127.0.0.1:$ws_port;" "$NGINX_AVAIL"; then
    _die "port substitution in $NGINX_AVAIL failed - check espocrm-nginx.conf's placeholders."
  fi
  echo "==> Nginx config written to $NGINX_AVAIL (domain + ports substituted)"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$domain"
    echo "==> Symlink created."
  fi

  echo "==> Testing Nginx configuration..."
  sudo nginx -t || _die "the Nginx configuration test failed. EspoCRM itself is running. If the certificate is missing, run 'sudo certbot certonly --nginx -d $domain', then 'sudo nginx -t && sudo systemctl reload nginx'."
  echo "==> Reloading Nginx..."
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> EspoCRM installation complete."
echo "    URL          : https://$domain"
echo "    Admin user   : admin  (password: ESPOCRM_ADMIN_PASSWORD in .env - first start"
echo "                   only; change it in the UI, top-right menu > Preferences)"
echo "    Next         : Administration > Outbound Emails - set up SMTP so EspoCRM can"
echo "                   send mail (notifications, password resets)."
echo "                   Administration > Settings - date/time format, currency, language."
echo ""
echo "    Install dir  : $INSTALL_DIR"
echo "    Compose file : $COMPOSE_FILE"
echo "    Secrets      : $ENV_FILE (mode 600 - back this up)"
echo "    Data volumes : ${PROJECT_NAME}_espocrm-db, ${PROJECT_NAME}_espocrm-data,"
echo "                   ${PROJECT_NAME}_espocrm-custom, ${PROJECT_NAME}_espocrm-custom-client"
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Status  : docker compose ps"
echo "    Logs    : docker compose logs -f espocrm"
echo "    Restart : docker compose restart"
echo "    Stop    : docker compose down          (keeps data; 'down -v' DELETES it)"
echo "    Start   : docker compose up -d"
echo "    CLI     : docker compose exec -u www-data espocrm bin/command <command>"
echo "    Upgrade : back up, set ESPOCRM_VERSION in .env, then"
echo "              docker compose pull && docker compose up -d"
echo ""
echo "    Back up with : $SCRIPT_DIR/espocrm-docker-backup.sh"
echo "    Restore with : $SCRIPT_DIR/espocrm-docker-restore.sh"
echo ""
