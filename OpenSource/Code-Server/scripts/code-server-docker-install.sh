#!/bin/bash
set -euo pipefail
# =============================================================================
# code-server Docker Install Script
# =============================================================================
# Deploys code-server (VS Code in the browser) from the docker-compose.yml next
# to this script, behind a host Nginx reverse proxy.
#
#   <install-dir>/
#     |-- docker-compose.yml   copied from this repo
#     |-- .env                 written here (mode 600) - holds the web password
#     |-- config/              -> /home/coder/.config   (config.yaml, settings)
#     |-- local/               -> /home/coder/.local    (extensions, server data)
#     `-- project/             -> /home/coder/project   (the workspace)
#
# The compose file is a translation of the official `docker run` command from
# https://coder.com/docs/code-server/latest/install#docker - this script only
# fills in .env and wires up Nginx. The container always listens on :8080; the
# host port you pick is published on 127.0.0.1 and proxied by Nginx.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../code-server-nginx.conf"
COMPOSE_SRC="$SCRIPT_DIR/../docker-compose.yml"

DEFAULT_BASE="/var/www/docker/code-server"
DEFAULT_PORT="8080"
DEFAULT_IMAGE_TAG="latest"

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_port_in_use() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

_mask() { [[ -n "${1:-}" ]] && echo "(set, ${#1} chars)" || echo "(empty)"; }

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in docker curl openssl sed awk; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
[ -f "$COMPOSE_SRC" ]    || _die "docker-compose.yml not found at $COMPOSE_SRC"
[ -f "$NGINX_CONF_SRC" ] || _die "code-server-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> code-server Install"
echo "========================================"
echo "Compose source: $COMPOSE_SRC"
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. code.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"   # hostnames are case-insensitive; compose project name must be lowercase

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
echo "code-server will be installed into a per-domain directory."
read -rp "Install directory [$DEFAULT_BASE/$domain]: " answer
INSTALL_DIR="${answer:-$DEFAULT_BASE/$domain}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
INSTALL_DIR="${INSTALL_DIR%/}"
[[ "$INSTALL_DIR" = /* ]] || _die "Install directory must be an absolute path."
if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  _die "$INSTALL_DIR already exists and is not empty - remove it first, or choose another path."
fi

# ── 3. Host port ──────────────────────────────────────────────────────────────
echo ""
echo "code-server is published on 127.0.0.1:<port> and proxied by Nginx."
read -rp "Host port [$DEFAULT_PORT]: " answer
port="${answer:-$DEFAULT_PORT}"
_valid_port "$port" || _die "Port must be a number between 1 and 65535."
if _port_in_use "$port"; then
  echo ""
  echo "WARNING: something is already listening on port $port:"
  ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  read -rp "Continue anyway? [y/N] " ans_port
  [[ "$ans_port" =~ ^[Yy]$ ]] || _die "Aborted - pick a free port."
fi

# ── Image tag ─────────────────────────────────────────────────────────────────
echo ""
read -rp "code-server image tag [$DEFAULT_IMAGE_TAG]: " image_tag
image_tag="${image_tag:-$DEFAULT_IMAGE_TAG}"

# ── Derived values ────────────────────────────────────────────────────────────
PROJECT_NAME="code-server-${domain//./-}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# The container runs as this uid/gid (see docker-compose.yml). Resolve it to the
# human running the install, even when that is via `sudo`, so the bind mounts
# and anything the editor writes are owned by a real user, not root.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  PUID="$(id -u "$SUDO_USER")"
  PGID="$(id -g "$SUDO_USER")"
  DOCKER_USER="$SUDO_USER"
else
  PUID="$(id -u)"
  PGID="$(id -g)"
  DOCKER_USER="$(id -un)"
fi
[ "$PUID" != "0" ] || echo "NOTE: running as root - code-server will run as root inside the container."

TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')"
web_password="$(openssl rand -hex 24)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "URL             : https://$domain"
echo "Install dir     : $INSTALL_DIR"
echo "Host port       : 127.0.0.1:$port  ->  container :8080"
echo "Image           : codercom/code-server:$image_tag"
echo "Compose project : $PROJECT_NAME"
echo "Run as (uid:gid): $PUID:$PGID ($DOCKER_USER)"
echo "Timezone        : $TZ_VALUE"
echo "Web password    : $(_mask "$web_password") (generated - stored in .env)"
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Create the install directory ─────────────────────────────────────────────
echo ""
echo "==> Creating $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"/{config,local,project}
sudo chown -R "$PUID:$PGID" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Copy the compose file ────────────────────────────────────────────────────
cp "$COMPOSE_SRC" "$COMPOSE_FILE"
echo "==> docker-compose.yml copied to $COMPOSE_FILE"

# ── Write .env ───────────────────────────────────────────────────────────────
echo "==> Writing .env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<ENV_EOF
# code-server instance configuration - generated by code-server-docker-install.sh
# Read by 'docker compose' from this directory. Keep this file safe: it holds
# the web login password. Back it up alongside ./config.

COMPOSE_PROJECT_NAME=$PROJECT_NAME
CONTAINER_NAME=$PROJECT_NAME
CODE_SERVER_VERSION=$image_tag

# Host UID/GID that owns ./config, ./local and ./project.
PUID=$PUID
PGID=$PGID
DOCKER_USER=$DOCKER_USER
TZ=$TZ_VALUE

# Loopback host port; the Nginx vhost proxies here. Container is always :8080.
CODE_SERVER_PORT=$port

# Web login password (auth: password).
PASSWORD=$web_password

# Optional argon2 hash - wins over PASSWORD when set. Because compose also
# interpolates this file, every '\$' in the hash must be written here as '\$\$'.
# Generate one with:
#   printf '%s' 'yourpassword' | docker run --rm -i codercom/code-server npx --yes argon2-cli -e
HASHED_PASSWORD=

# Optional absolute template for the ports panel / extension proxy links,
# e.g. https://{{port}}.$domain  (needs wildcard DNS + TLS for *.$domain).
VSCODE_PROXY_URI=
ENV_EOF
echo "==> .env written to $ENV_FILE (mode 600)"

# ── Validate the compose file against .env ───────────────────────────────────
echo "==> Validating docker-compose.yml..."
docker compose config >/dev/null || _die "docker-compose.yml did not validate with this .env."
echo "    OK"

# ── Review ──────────────────────────────────────────────────────────────────-
read -rp "Would you like to review/edit .env? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$ENV_FILE"

read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$COMPOSE_FILE"

# ── Start ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Pulling image..."
docker compose pull
echo "==> Starting code-server..."
docker compose up -d

# ── Wait for code-server to answer ──────────────────────────────────────────-
echo -n "==> Waiting for code-server to respond on 127.0.0.1:$port"
CS_UP=false
for _ in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${port}/healthz" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    CS_UP=true
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [[ "$CS_UP" == "true" ]]; then
  echo "==> code-server is up."
else
  echo "WARNING: code-server did not answer within ~2 minutes."
  echo "         Check the logs: (cd $INSTALL_DIR && docker compose logs -f)"
  read -rp "Continue with the Nginx setup anyway? [y/N] " ans_continue
  [[ "$ans_continue" =~ ^[Yy]$ ]] || exit 1
fi

# ── Let's Encrypt ───────────────────────────────────────────────────────────-
echo ""
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
fi

# ── Nginx reverse proxy ─────────────────────────────────────────────────────-
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$domain"

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|code\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:8080|127.0.0.1:$port|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL (domain + port substituted)"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$domain"
    echo "==> Symlink created."
  fi

  echo "==> Testing Nginx configuration..."
  sudo nginx -t
  echo "==> Reloading Nginx..."
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

# ── Done ────────────────────────────────────────────────────────────────────-
echo ""
echo "==> code-server installation complete."
echo "    URL          : https://$domain"
echo "    Login        : the password in $ENV_FILE (PASSWORD=...)"
echo "    Workspace    : $INSTALL_DIR/project  (mounted at /home/coder/project)"
echo "    Settings     : $INSTALL_DIR/config/code-server/config.yaml"
echo "    Secrets      : $ENV_FILE (mode 600 - back this up)"
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo "    Logs    : docker compose logs -f"
echo "    Status  : docker compose ps"
echo "    Update  : docker compose pull && docker compose up -d"
echo "    Shell   : docker compose exec code-server bash"
echo ""
