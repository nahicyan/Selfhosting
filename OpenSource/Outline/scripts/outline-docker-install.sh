#!/bin/bash
set -euo pipefail
# =============================================================================
# Outline Docker Install Script
# =============================================================================
# Deploys Outline (outline + postgres + redis) from the docker-compose.yml
# next to this script, behind a host Nginx reverse proxy.
#
#   <install-dir>/
#     |-- docker-compose.yml   copied from this repo
#     `-- .env                 written here (mode 600) - all app config
#
# Postgres and Redis data live in named Docker volumes (storage-data,
# database-data), not bind mounts, so there is no host UID/GID to reconcile.
#
# Authentication is email "magic link" only - no OAuth/OIDC provider is
# configured, so a working SMTP server is required and this script asks for
# one (custom mail server only, matching outline/temp/SMTP.txt). File
# attachments are stored on local disk (FILE_STORAGE=local), not S3.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../outline-nginx.conf"
COMPOSE_SRC="$SCRIPT_DIR/../docker-compose.yml"

DEFAULT_BASE="/var/www/docker/outline"
DEFAULT_PORT="3000"

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

# Deliberately permissive: accepts a bare address or "Name <address>", and
# only checks for an "@" and a "." - GNU regex treats \< \> as word-boundary
# anchors (not literal brackets), so a stricter ERE here would be a footgun.
_valid_email() {
  [[ "$1" == *@*.* ]]
}

_mask() { [[ -n "${1:-}" ]] && echo "(set, ${#1} chars)" || echo "(empty)"; }

_gen_secret() { openssl rand -hex 32; }

# _ask_required <var-name> <prompt> - loop until a non-empty value is entered.
_ask_required() {
  local -n _ref="$1"
  local prompt="$2" value
  while :; do
    read -rp "$prompt" value
    if [[ -n "$value" ]]; then
      _ref="$value"
      return 0
    fi
    echo "    This value is required."
  done
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in docker curl openssl sed; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
[ -f "$COMPOSE_SRC" ]    || _die "docker-compose.yml not found at $COMPOSE_SRC"
[ -f "$NGINX_CONF_SRC" ] || _die "outline-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> Outline Install"
echo "========================================"
echo "Compose source: $COMPOSE_SRC"
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. outline.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"   # hostnames are case-insensitive; compose project name must be lowercase

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
echo "Outline will be installed into a per-domain directory."
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
echo "Outline is published on 127.0.0.1:<port> and proxied by Nginx."
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

# ── 4. SMTP (required - email magic-link is the only sign-in method) ─────────
echo ""
echo "Outline needs at least one working sign-in method. This install only"
echo "configures email 'magic link' sign-in (no Slack/Google/OIDC), so a"
echo "custom SMTP server is required - see outline/temp/SMTP.txt."
echo ""
_ask_required smtp_host     "  SMTP host (e.g. mail.example.com): "
read -rp     "  SMTP port [465]: " smtp_port
smtp_port="${smtp_port:-465}"
_valid_port "$smtp_port" || _die "SMTP port must be a number between 1 and 65535."
_ask_required smtp_username "  SMTP username: "
read -rsp    "  SMTP password (leave blank if the server does not require one): " smtp_password; echo
_ask_required smtp_from     "  SMTP from address (e.g. Outline <noreply@example.com>): "
_valid_email "$smtp_from" || _die "'$smtp_from' does not look like a valid from address."
read -rp     "  SMTP reply-to address (optional, blank = same as from): " smtp_reply

smtp_secure_default="Y"
smtp_secure_prompt="Y/n"
if [[ "$smtp_port" == "587" || "$smtp_port" == "25" ]]; then
  smtp_secure_default="N"
  smtp_secure_prompt="y/N"
fi
read -rp "  Connect with TLS (SMTP_SECURE)? [$smtp_secure_prompt]: " ans_smtp_secure
ans_smtp_secure="${ans_smtp_secure:-$smtp_secure_default}"
if [[ "$ans_smtp_secure" =~ ^[Yy]$ ]]; then smtp_secure="true"; else smtp_secure="false"; fi

# Compose interpolates $ inside .env, so a literal $ in any of these
# admin-supplied values (most likely the password) must be escaped as $$ to
# survive into the container unchanged - see docker-compose.yml's comment on
# env_file. Generated secrets (hex only) never need this.
smtp_host_env="${smtp_host//\$/\$\$}"
smtp_username_env="${smtp_username//\$/\$\$}"
smtp_password_env="${smtp_password//\$/\$\$}"
smtp_from_env="${smtp_from//\$/\$\$}"
smtp_reply_env="${smtp_reply//\$/\$\$}"

# ── Derived values ────────────────────────────────────────────────────────────
PROJECT_NAME="outline-${domain//./-}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

secret_key="$(_gen_secret)"
utils_secret="$(_gen_secret)"
postgres_password="$(_gen_secret)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "URL             : https://$domain"
echo "Install dir     : $INSTALL_DIR"
echo "Host port       : 127.0.0.1:$port  ->  container :3000"
echo "Compose project : $PROJECT_NAME"
echo "Auth method     : Email magic-link only"
echo "File storage    : local disk (docker volume, storage-data)"
echo "SMTP host       : $smtp_host:$smtp_port (TLS: $smtp_secure)"
echo "SMTP username   : $smtp_username"
echo "SMTP password   : $(_mask "$smtp_password")"
echo "SMTP from       : $smtp_from"
echo "SMTP reply-to   : ${smtp_reply:-(same as from)}"
echo "Secrets         : SECRET_KEY, UTILS_SECRET, POSTGRES_PASSWORD - generated"
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Create the install directory ─────────────────────────────────────────────
echo ""
echo "==> Creating $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
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
# Outline instance configuration - generated by outline-docker-install.sh
# Read by 'docker compose' from this directory (both for \${...} interpolation
# in docker-compose.yml and, via env_file, passed straight into the outline
# container using Outline's own variable names). Keep this file safe. Back it
# up alongside the storage-data and database-data docker volumes.

COMPOSE_PROJECT_NAME=$PROJECT_NAME
NODE_ENV=production

# ── Core ──
URL=https://$domain
PORT=3000
DEFAULT_LANGUAGE=en_US
WEB_CONCURRENCY=1
SECRET_KEY=$secret_key
UTILS_SECRET=$utils_secret

# Loopback host port; the Nginx vhost proxies here. Container is always :3000.
OUTLINE_PORT=$port

# Uncomment to pin the image instead of tracking :latest, e.g. OUTLINE_VERSION=1.2.0
# OUTLINE_VERSION=latest

# ── SSL / reverse proxy ──
# Nginx (outline-nginx.conf) terminates TLS and forwards X-Forwarded-Proto;
# Outline trusts that by default (PROXY_HEADERS_TRUSTED) so this does not
# cause a redirect loop.
FORCE_HTTPS=true

# ── Database ──
# Postgres and Outline only ever talk over the private compose network on
# this host, so PGSSLMODE=disable is correct here - without it Outline's
# production mode always attempts SSL (server/storage/database.ts) and a
# stock postgres image, which has no certificate configured, refuses it and
# the container fails to start.
DATABASE_URL=postgres://outline:${postgres_password}@postgres:5432/outline
PGSSLMODE=disable
POSTGRES_USER=outline
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DB=outline

# ── Redis ──
REDIS_URL=redis://redis:6379

# ── File storage (local disk, not S3) ──
FILE_STORAGE=local
FILE_STORAGE_LOCAL_ROOT_DIR=/var/lib/outline/data
FILE_STORAGE_UPLOAD_MAX_SIZE=262144000

# ── Email / SMTP (custom mail server - powers email magic-link sign-in) ──
SMTP_HOST=$smtp_host_env
SMTP_PORT=$smtp_port
SMTP_USERNAME=$smtp_username_env
SMTP_PASSWORD=$smtp_password_env
SMTP_FROM_EMAIL=$smtp_from_env
SMTP_REPLY_EMAIL=$smtp_reply_env
SMTP_SECURE=$smtp_secure

# ── Logging ──
ENABLE_UPDATES=true
DEBUG=http
LOG_LEVEL=info
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
echo "==> Pulling images..."
docker compose pull
echo "==> Starting Outline, Postgres and Redis..."
docker compose up -d

# ── Wait for Outline to answer ───────────────────────────────────────────────
# /_health checks the database and Redis connections, not just "process is up".
echo -n "==> Waiting for Outline to respond on 127.0.0.1:$port"
OUTLINE_UP=false
for _ in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${port}/_health" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    OUTLINE_UP=true
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [[ "$OUTLINE_UP" == "true" ]]; then
  echo "==> Outline is up."
else
  echo "WARNING: Outline did not answer within ~2 minutes."
  echo "         Check the logs: (cd $INSTALL_DIR && docker compose logs -f outline)"
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
    -e "s|outline\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:3000|127.0.0.1:$port|g" \
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
echo "==> Outline installation complete."
echo "    URL          : https://$domain"
echo "    Sign-in      : email magic-link - the first person to sign in creates"
echo "                   the workspace and becomes its admin."
echo "    Attachments  : docker volume storage-data (mounted at /var/lib/outline/data)"
echo "    Database     : docker volume database-data (Postgres)"
echo "    Secrets      : $ENV_FILE (mode 600 - back this up)"
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo "    Logs    : docker compose logs -f outline"
echo "    Status  : docker compose ps"
echo "    Update  : docker compose pull && docker compose up -d"
echo ""
