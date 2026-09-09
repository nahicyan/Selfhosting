#!/bin/bash
set -euo pipefail
# =============================================================================
# Coder Docker Install Script
# =============================================================================
# Deploys Coder (self-hosted cloud development environments) for production from
# the official compose.yaml, behind a host Nginx reverse proxy.
#
#   <install-dir>/
#     |-- compose.yaml   downloaded from github.com/coder/coder (main)
#     `-- .env           written here (mode 600) - holds the Postgres password
#
# Named Docker volumes hold the state:
#   <project>_coder_data  ->  PostgreSQL 17 data
#   <project>_coder_home  ->  /home/coder in the Coder container
#
# The compose file is used as published; this script only patches three things
# into it - the published host port (bound to loopback), and the docker group
# so Coder can drive Docker-based templates - then fills in .env and wires up
# Nginx. See:
#   https://coder.com/docs/install/docker
#   https://coder.com/docs/admin/setup           (CODER_ACCESS_URL, Postgres)
#   https://coder.com/docs/tutorials/reverse-proxy-nginx
#
# The container listens on :7080; the host port you pick is published on
# 127.0.0.1 and proxied by Nginx, which terminates TLS.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../coder-nginx.conf"

COMPOSE_URL="https://raw.githubusercontent.com/coder/coder/refs/heads/main/compose.yaml"
COMPOSE_FILENAME="compose.yaml"

DEFAULT_BASE="/var/www/docker/coder"
DEFAULT_PORT="7080"          # the port the upstream compose.yaml publishes
CONTAINER_PORT="7080"        # CODER_HTTP_ADDRESS inside the container
DEFAULT_VERSION="latest"
DEFAULT_PG_USER="coder"
DEFAULT_PG_DB="coder"

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

# Hex only: URL-safe and .env-safe with nothing to escape.
_gen_secret() { openssl rand -hex 24; }

# The Postgres password lands in two places with different rules:
#   - .env, read by Compose's dotenv parser (so no '$')
#   - CODER_PG_CONNECTION_URL, which compose.yaml builds as
#       postgresql://<user>:<password>@database/<db>?sslmode=disable
# Restricting to RFC 3986 "unreserved" characters is safe in both: it needs no
# percent-encoding in the URL and no quoting in .env. A typed password with
# anything else is refused rather than risk reaching Postgres mangled.
_valid_secret() {
  [[ "$1" =~ ^[A-Za-z0-9._~-]{8,}$ ]]
}

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
      echo "    Rejected. Use 8+ characters from: A-Z a-z 0-9 . _ ~ -"
      echo "    (other characters would need escaping in .env or"
      echo "     percent-encoding inside CODER_PG_CONNECTION_URL.)"
      continue
    fi
    _ref="$first"
    return 0
  done
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in docker curl openssl sed awk grep; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot talk to the Docker daemon - is it running, and can this user reach it?"
[ -f "$NGINX_CONF_SRC" ] || _die "coder-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> Coder Install"
echo "========================================"
echo "Compose source: $COMPOSE_URL"
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. coder.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
# Lowercased: hostnames are case-insensitive, and the Compose project name
# derived from this has to be lowercase or Compose refuses it.
domain="${domain,,}"

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
echo "Coder will be installed into a per-domain directory (holds compose.yaml + .env)."
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
echo "Coder is published on 127.0.0.1:<port> and proxied by Nginx."
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

# ── 4. PostgreSQL credentials ────────────────────────────────────────────────
echo ""
echo "Coder stores everything in the bundled PostgreSQL container (service 'database')."
read -rp "PostgreSQL username [$DEFAULT_PG_USER]: " pg_user
pg_user="${pg_user:-$DEFAULT_PG_USER}"
[[ "$pg_user" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || _die "'$pg_user' is not a valid PostgreSQL role name."
_ask_secret pg_password "PostgreSQL password"

# ── 5. Wildcard access URL (optional) ────────────────────────────────────────
echo ""
echo "A wildcard access URL lets the dashboard forward workspace ports and serve"
echo "coder_apps on subpaths. It needs wildcard DNS (*.$domain) and a matching"
echo "TLS certificate (DNS-01 challenge). Skip it for a standard path-based setup."
read -rp "Enable wildcard access URL (*.$domain)? [y/N] " ans_wild
if [[ "$ans_wild" =~ ^[Yy]$ ]]; then
  wildcard="*.$domain"
else
  wildcard=""
fi

# ── 6. Image tag ─────────────────────────────────────────────────────────────
echo ""
read -rp "Coder version / image tag [$DEFAULT_VERSION]: " image_tag
image_tag="${image_tag:-$DEFAULT_VERSION}"

# ── Docker group (so Coder can drive Docker-based templates) ─────────────────
# Coder runs as a non-root user inside the container and talks to the host's
# /var/run/docker.sock. compose.yaml ships a commented group_add: block for
# exactly this - fill it with the host's docker gid.
#   https://coder.com/docs/install/docker  ("I cannot add Docker templates")
docker_gid=""
if command -v getent >/dev/null 2>&1; then
  docker_gid="$(getent group docker | cut -d: -f3 || true)"
elif [ -S /var/run/docker.sock ]; then
  docker_gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
fi

# ── Derived values ───────────────────────────────────────────────────────────
PROJECT_NAME="coder-${domain//./-}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/$COMPOSE_FILENAME"
ACCESS_URL="https://$domain"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "Access URL      : $ACCESS_URL"
echo "Wildcard URL    : ${wildcard:-(disabled)}"
echo "Install dir     : $INSTALL_DIR"
echo "Host port       : 127.0.0.1:$port  ->  container :$CONTAINER_PORT"
echo "Image           : ghcr.io/coder/coder:$image_tag"
echo "Compose project : $PROJECT_NAME"
echo "Postgres user   : $pg_user"
echo "Postgres db     : $DEFAULT_PG_DB"
echo "Postgres passwd : $(_mask "$pg_password") (stored in .env)"
if [ -n "$docker_gid" ]; then
  echo "Docker group    : gid $docker_gid (group_add in compose.yaml)"
else
  echo "Docker group    : not found - Docker-based templates will need manual setup"
fi
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Create the install directory ────────────────────────────────────────────
# Resolve the real user even under sudo so compose.yaml/.env aren't root-owned.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  OWNER_UID="$(id -u "$SUDO_USER")"; OWNER_GID="$(id -g "$SUDO_USER")"
else
  OWNER_UID="$(id -u)"; OWNER_GID="$(id -g)"
fi

echo ""
echo "==> Creating $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$OWNER_UID:$OWNER_GID" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Download compose.yaml ───────────────────────────────────────────────────
echo "==> Downloading compose.yaml"
curl -fsSL -o "$COMPOSE_FILE" "$COMPOSE_URL" \
  || _die "download failed - check network access to $COMPOSE_URL"
grep -q '^services:' "$COMPOSE_FILE" \
  && grep -q 'ghcr.io/coder/coder' "$COMPOSE_FILE" \
  || _die "$COMPOSE_FILE does not look like Coder's compose file - aborting."
echo "    saved to $COMPOSE_FILE"

# ── Patch the published port onto loopback ──────────────────────────────────
# Upstream publishes "7080:7080" on 0.0.0.0. Nginx is the only public
# entrypoint, so bind the chosen host port to 127.0.0.1 and leave the
# container port (7080) alone.
if ! grep -qE '^\s*-\s*"7080:7080"\s*$' "$COMPOSE_FILE"; then
  _die "expected '- \"7080:7080\"' in $COMPOSE_FILE was not found - upstream compose.yaml changed; patch the port by hand."
fi
sed -i -E "s|^(\s*)-\s*\"7080:7080\"\s*$|\1- \"127.0.0.1:${port}:${CONTAINER_PORT}\"|" "$COMPOSE_FILE"
echo "==> compose.yaml: port published on 127.0.0.1:$port -> $CONTAINER_PORT"

# ── Patch group_add with the host docker gid ────────────────────────────────
if [ -n "$docker_gid" ]; then
  if grep -q '^\s*#group_add:' "$COMPOSE_FILE"; then
    sed -i -E \
      -e 's|^(\s*)#group_add:.*$|\1group_add:|' \
      -e "s|^(\s*)#\s*-\s*\"998\".*$|\1  - \"${docker_gid}\"|" \
      "$COMPOSE_FILE"
    grep -q '^\s*group_add:' "$COMPOSE_FILE" \
      || _die "failed to enable group_add in $COMPOSE_FILE - upstream layout changed; edit it by hand."
    echo "==> compose.yaml: group_add set to docker gid $docker_gid"
  else
    echo "NOTE: no commented group_add: block in compose.yaml - add the docker"
    echo "      gid ($docker_gid) to the coder service by hand if you use"
    echo "      Docker-based templates."
  fi
else
  echo "NOTE: no 'docker' group found on this host. Coder will still start, but"
  echo "      Docker-based templates need the container in a group that can"
  echo "      write /var/run/docker.sock. See:"
  echo "      https://coder.com/docs/install/docker"
fi

# ── Write .env ──────────────────────────────────────────────────────────────
echo "==> Writing .env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<ENV_EOF
# Coder instance configuration - generated by coder-docker-install.sh
# Read by 'docker compose' from this directory. Keep this file safe: it holds
# the PostgreSQL password. Back it up.

COMPOSE_PROJECT_NAME=$PROJECT_NAME

# Container image tag. CODER_REPO defaults to ghcr.io/coder/coder.
CODER_VERSION=$image_tag

# External URL users and workspaces connect to. Must be the https:// address
# that terminates at the Nginx vhost - never localhost.
# https://coder.com/docs/admin/setup#access-url
CODER_ACCESS_URL=$ACCESS_URL

# Wildcard for dashboard port-forwarding and coder_apps on subpaths. Needs
# wildcard DNS and a *.$domain TLS certificate. Leave unset to disable.
$( [ -n "$wildcard" ] && echo "CODER_WILDCARD_ACCESS_URL=$wildcard" || echo "#CODER_WILDCARD_ACCESS_URL=*.$domain" )

# Bundled PostgreSQL (service "database"). compose.yaml builds
# CODER_PG_CONNECTION_URL from these three values.
POSTGRES_USER=$pg_user
POSTGRES_PASSWORD=$pg_password
POSTGRES_DB=$DEFAULT_PG_DB
ENV_EOF
echo "==> .env written to $ENV_FILE (mode 600)"

# ── Validate the compose file against .env ──────────────────────────────────
echo "==> Validating compose.yaml..."
docker compose config >/dev/null || _die "compose.yaml did not validate with this .env."
echo "    OK"

# ── Review ─────────────────────────────────────────────────────────────────-
read -rp "Would you like to review/edit .env? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$ENV_FILE"

read -rp "Would you like to review/edit compose.yaml? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$COMPOSE_FILE"

# ── Start ──────────────────────────────────────────────────────────────────-
echo ""
echo "==> Pulling images..."
docker compose pull
echo "==> Starting Coder and PostgreSQL..."
docker compose up -d

# ── Wait for Coder to answer ───────────────────────────────────────────────-
# First boot runs the database migration, so give it a few minutes.
echo -n "==> Waiting for Coder to respond on 127.0.0.1:$port"
CODER_UP=false
for _ in $(seq 1 90); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${port}/healthz" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    CODER_UP=true
    break
  fi
  echo -n "."
  sleep 3
done
echo ""

if [[ "$CODER_UP" == "true" ]]; then
  echo "==> Coder is up."
else
  echo "WARNING: Coder did not answer within ~4.5 minutes."
  echo "         Check the logs: (cd $INSTALL_DIR && docker compose logs -f coder)"
  read -rp "Continue with the Nginx setup anyway? [y/N] " ans_continue
  [[ "$ans_continue" =~ ^[Yy]$ ]] || exit 1
fi

# ── Let's Encrypt ─────────────────────────────────────────────────────────--
echo ""
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
  [ -n "$wildcard" ] && echo "NOTE: this certificate does not cover $wildcard - reissue with a DNS-01 wildcard challenge for workspace apps to work."
fi

# ── Nginx reverse proxy ───────────────────────────────────────────────────--
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$domain"

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|coder\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:7080|127.0.0.1:$port|g" \
    "$NGINX_AVAIL"
  if [ -n "$wildcard" ]; then
    sudo sed -i "s|server_name $domain;|server_name $domain *.$domain;|" "$NGINX_AVAIL"
    echo "==> Nginx config written to $NGINX_AVAIL (domain + wildcard + port substituted)"
  else
    echo "==> Nginx config written to $NGINX_AVAIL (domain + port substituted)"
  fi

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

# ── Done ──────────────────────────────────────────────────────────────────--
echo ""
echo "==> Coder installation complete."
echo "    URL          : $ACCESS_URL"
echo "    First run    : open the URL and create the first (owner) account."
[ -n "$wildcard" ] && echo "    Wildcard     : $wildcard  (needs matching DNS + TLS)"
echo "    Install dir  : $INSTALL_DIR"
echo "    Compose file : $COMPOSE_FILE  (downloaded from coder/coder@main)"
echo "    Secrets      : $ENV_FILE (mode 600 - back this up)"
echo "    Data         : Docker volumes ${PROJECT_NAME}_coder_data (Postgres) and ${PROJECT_NAME}_coder_home"
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo "    Logs    : docker compose logs -f coder"
echo "    Status  : docker compose ps"
echo "    Update  : docker compose pull && docker compose up -d"
echo "    CLI     : docker compose exec coder coder --help"
echo ""
