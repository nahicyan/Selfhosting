#!/bin/bash
set -euo pipefail
# =============================================================================
# Cal.diy Docker Install Script
# =============================================================================
# Follows the official "Running Cal.diy with Docker Compose" steps from the
# cal.diy README (Deployment -> Docker), behind a host Nginx reverse proxy:
#
#   1. git clone https://github.com/calcom/cal.diy.git
#   2. cp .env.example .env, with NEXTAUTH_SECRET (openssl rand -base64 32)
#      and CALENDSO_ENCRYPTION_KEY (openssl rand -base64 24) generated
#   3. generate the VAPID keys web push needs
#   4. docker compose pull
#   5. docker compose up -d
#   6. open the site - the first-run setup wizard creates the first user
#
#   <install-dir>/              default /var/www/docker/cal/<domain>
#     |-- docker-compose.yml    from the clone, adjusted as listed below
#     `-- .env                  .env.example + the values above (mode 600)
#
# The cloned docker-compose.yml is used as-is except for these edits. Each one
# is an exact-line match and the script stops if upstream has changed a line,
# instead of guessing:
#
#   - The web app is published on 127.0.0.1:${CAL_PORT} instead of 0.0.0.0:3000.
#     Nginx is the only public entry point.
#   - The database service reads its user, password and name from .env. Upstream
#     hardcodes unicorn_user / magical_password, while the web app builds its
#     DATABASE_URL from POSTGRES_* in .env - and .env.example does not define
#     those, so they have to be written here and agree with the database.
#   - postgres is pinned to 18. The volume path (/var/lib/postgresql) is the
#     PostgreSQL 18+ layout, and the official update step is `docker compose
#     pull`, which would otherwise follow `latest` into a major version that
#     cannot open the existing data directory.
#   - redis, calcom-api and studio are removed. The guide supports running the
#     web app on its own (`docker compose up -d calcom`); calcom-api is the
#     optional API v2 (built from source, and it publishes host port 80, which
#     is Nginx's) and studio is Prisma Studio, which the compose file itself
#     says to remove in production because it exposes the database.
#   - The fixed container name and shared network name ("stack") are removed, so
#     every domain is its own Compose project. With them, two instances would
#     collide on the container name and share one network, where both
#     databases answer to the hostname "database".
#
# On ARM hosts the guide says to use the -arm image tag, so the script asks
# for it and points the web app at calcom/cal.diy:<tag>.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../cal-nginx.conf"

CAL_REPO="https://github.com/calcom/cal.diy.git"

DEFAULT_BASE="/var/www/docker/cal"
DEFAULT_PORT="3000"

STARTED=false   # true from the clone until the stack is up: a failure in between leaves a half-made install, and _on_exit says how to clear it

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$STARTED" == "true" ]]; then
    echo "" >&2
    echo "The install did not finish. $INSTALL_DIR is left as it is. To start over:" >&2
    echo "  (cd $INSTALL_DIR && docker compose down -v); sudo rm -rf $INSTALL_DIR" >&2
  fi
}
trap _on_exit EXIT

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

# A bare address: exactly what EMAIL_FROM expects (Cal.diy adds the display
# name itself from EMAIL_FROM_NAME).
_valid_email() {
  [[ "$1" =~ ^[^[:space:]\<\>@]+@[^[:space:]\<\>@]+\.[^[:space:]\<\>@]+$ ]]
}

_mask() { [[ -n "${1:-}" ]] && echo "(set, ${#1} chars)" || echo "(empty)"; }

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

# Set KEY='value' in an env file: replaces the line in place, or appends the
# key if it is not there. Done line by line instead of with sed so a value
# never needs escaping. Single quotes are how .env.example writes its values,
# and inside them neither Compose nor bash expands a $.
_env_set() {  # _env_set <file> <key> <value>
  local file="$1" key="$2" value="$3" line found=0 tmp
  [[ "$value" != *"'"* ]] || _die "the value for $key contains a single quote, which .env cannot hold."
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
      if [ "$found" -eq 0 ]; then
        printf "%s='%s'\n" "$key" "$value" >> "$tmp"
        found=1
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  if [ "$found" -eq 0 ]; then printf "%s='%s'\n" "$key" "$value" >> "$tmp"; fi
  cat "$tmp" > "$file"   # rewrite in place so the file keeps its 600 mode
  rm -f "$tmp"
}

# Edit docker-compose.yml by exact whole-line match: replace the line, or
# delete it when no replacement is given. Dies if the line is not there - that
# means upstream changed the file and this script needs a look.
_compose_edit() {  # _compose_edit <exact line> [<replacement line>]
  local old="$1" line found=0 tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$old" ]]; then
      found=1
      [[ $# -ge 2 ]] && printf '%s\n' "$2" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$COMPOSE_FILE"
  if [ "$found" -eq 0 ]; then
    rm -f "$tmp"
    _die "docker-compose.yml no longer contains the line '$old' - upstream has changed; update $(basename "$0")."
  fi
  cat "$tmp" > "$COMPOSE_FILE"
  rm -f "$tmp"
}

# Remove whole services (name line through the line before the next 2-space
# key or top-level line). The service list is checked afterwards, so a service
# that was renamed upstream shows up as an error, not as a silent leftover.
_compose_drop_services() {  # _compose_drop_services <name>...
  local names=" $* " tmp
  tmp="$(mktemp)"
  awk -v names="$names" '
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { key = $1; sub(/:$/, "", key); skip = (index(names, " " key " ") > 0) }
    /^[^[:space:]]/                    { skip = 0 }
    !skip                              { print }
  ' "$COMPOSE_FILE" > "$tmp"
  cat "$tmp" > "$COMPOSE_FILE"
  rm -f "$tmp"
}

_hex_to_b64url() {
  printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')" | base64 -w0 | tr '+/' '-_' | tr -d '='
}

# The P-256 pair `npx web-push generate-vapid-keys` produces, made with openssl
# so the host needs no Node. Sets VAPID_PUBLIC / VAPID_PRIVATE (base64url, no
# padding); fails unless they have the right lengths (87 and 43 characters).
# The SEC1 DER key holds the 32-byte private scalar from byte 7 on, and the
# SubjectPublicKeyInfo DER ends with the 65-byte uncompressed public point.
_gen_vapid() {
  local pem priv_hex pub_hex
  pem="$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)" || return 1
  priv_hex="$(printf '%s\n' "$pem" | openssl ec -outform DER 2>/dev/null | od -An -v -tx1 | tr -d ' \n')" || return 1
  pub_hex="$(printf '%s\n' "$pem" | openssl ec -pubout -outform DER 2>/dev/null | od -An -v -tx1 | tr -d ' \n')" || return 1
  VAPID_PRIVATE="$(_hex_to_b64url "${priv_hex:14:64}")"
  VAPID_PUBLIC="$(_hex_to_b64url "${pub_hex: -130}")"
  [[ ${#VAPID_PRIVATE} -eq 43 && ${#VAPID_PUBLIC} -eq 87 ]]
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in git docker curl openssl od base64 awk sed mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
[ -f "$NGINX_CONF_SRC" ] || _die "cal-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> Cal.diy Install"
echo "========================================"
echo "Source: $CAL_REPO"
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. cal.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"   # hostnames are case-insensitive; the compose project name must be lowercase

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
echo "Cal.diy will be installed into a per-domain directory."
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
echo "Cal.diy is published on 127.0.0.1:<port> and proxied by Nginx."
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

# ── 4. Image tag (ARM only) ───────────────────────────────────────────────────
image_tag=""
case "$(uname -m)" in
  aarch64|arm64|armv8*)
    echo ""
    echo "This is an ARM host. The Cal.diy guide says to pull the image with the"
    echo "-arm suffix, e.g. calcom/cal.diy:v5.6.19-arm (see hub.docker.com/r/calcom/cal.diy)."
    read -rp "Image tag: " image_tag
    [[ "$image_tag" =~ ^[A-Za-z0-9._-]+-arm$ ]] || _die "The tag must end in -arm (e.g. v5.6.19-arm)."
    ;;
esac

# ── 5. SMTP ───────────────────────────────────────────────────────────────────
configure_smtp=false
smtp_host=""; smtp_port=""; smtp_user=""; smtp_pass=""; smtp_from=""
echo ""
echo "Cal.diy sends booking confirmations and reminders by email, so it needs an"
echo "SMTP server. You can also set EMAIL_SERVER_* in .env later."
read -rp "Configure SMTP now? [y/N] " ans_smtp
if [[ "$ans_smtp" =~ ^[Yy]$ ]]; then
  configure_smtp=true
  _ask_required smtp_host "  SMTP host (e.g. mail.example.com): "
  read -rp "  SMTP port [587]: " smtp_port
  smtp_port="${smtp_port:-587}"
  _valid_port "$smtp_port" || _die "SMTP port must be a number between 1 and 65535."
  read -rp "  SMTP username (blank if the server does not require a login): " smtp_user
  if [[ -n "$smtp_user" ]]; then
    read -rsp "  SMTP password: " smtp_pass; echo
  fi
  _ask_required smtp_from "  From address (e.g. notifications@example.com): "
  _valid_email "$smtp_from" || _die "'$smtp_from' is not a valid address (use the bare address, without a display name)."
  for v in "$smtp_host" "$smtp_user" "$smtp_pass" "$smtp_from"; do
    [[ "$v" != *"'"* ]] || _die "SMTP values cannot contain a single quote."
  done
fi

# ── Derived values ────────────────────────────────────────────────────────────
PROJECT_NAME="cal-${domain//./-}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

nextauth_secret="$(openssl rand -base64 32)"
encryption_key="$(openssl rand -base64 24)"
postgres_user="calcom"
postgres_db="calendso"
postgres_password="$(openssl rand -hex 24)"
cron_api_key="$(openssl rand -hex 16)"
VAPID_PUBLIC=""; VAPID_PRIVATE=""
_gen_vapid || { VAPID_PUBLIC=""; VAPID_PRIVATE=""; }

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "URL             : https://$domain"
echo "Install dir     : $INSTALL_DIR"
echo "Host port       : 127.0.0.1:$port  ->  container :3000"
echo "Compose project : $PROJECT_NAME"
echo "Stack           : Cal.diy web app + PostgreSQL (docker volume database-data)"
if [[ -n "$image_tag" ]]; then
  echo "Image           : calcom/cal.diy:$image_tag"
else
  echo "Image           : calcom.docker.scarf.sh/calcom/cal.diy (as in the compose file)"
fi
if [[ "$configure_smtp" == "true" ]]; then
  echo "SMTP host       : $smtp_host:$smtp_port"
  echo "SMTP username   : ${smtp_user:-(none)}"
  echo "SMTP password   : $(_mask "$smtp_pass")"
  echo "SMTP from       : $smtp_from"
else
  echo "SMTP            : not configured - no booking emails until EMAIL_SERVER_* is set in .env"
fi
echo "Secrets         : NEXTAUTH_SECRET, CALENDSO_ENCRYPTION_KEY, POSTGRES_PASSWORD, CRON_API_KEY - generated"
if [[ -n "$VAPID_PUBLIC" ]]; then
  echo "Web push        : VAPID keys generated"
else
  echo "Web push        : WARNING - could not generate VAPID keys; web push stays disabled"
fi
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Clone ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Cloning $CAL_REPO"
sudo mkdir -p "$(dirname "$INSTALL_DIR")"
sudo git clone --depth 1 --recursive "$CAL_REPO" "$INSTALL_DIR" \
  || _die "clone failed - check network access to $CAL_REPO"
STARTED=true
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
cd "$INSTALL_DIR"
[ -f "$COMPOSE_FILE" ] || _die "docker-compose.yml is not in the cloned repo."
[ -f .env.example ]    || _die ".env.example is not in the cloned repo."
echo "==> Cloned to $INSTALL_DIR ($(git -C "$INSTALL_DIR" rev-parse --short HEAD))"

# ── Write .env ────────────────────────────────────────────────────────────────
echo "==> Writing .env"
cp .env.example .env
chmod 600 .env
printf '\n# ── Added by cal-docker-install.sh ──\n' >> .env

_env_set "$ENV_FILE" COMPOSE_PROJECT_NAME "$PROJECT_NAME"
# Loopback host port the compose file publishes and Nginx proxies to. The
# container always listens on 3000.
_env_set "$ENV_FILE" CAL_PORT "$port"

# The public URL. NEXTAUTH_URL is the documented default,
# ${NEXT_PUBLIC_WEBAPP_URL}/api/auth. Do not point it at localhost: sign-in and
# verification emails are built from it.
_env_set "$ENV_FILE" NEXT_PUBLIC_WEBAPP_URL   "https://$domain"
_env_set "$ENV_FILE" NEXT_PUBLIC_WEBSITE_URL  "https://$domain"
_env_set "$ENV_FILE" NEXT_PUBLIC_EMBED_LIB_URL "https://$domain/embed/embed.js"
_env_set "$ENV_FILE" NEXTAUTH_URL             "https://$domain/api/auth"

# Required secrets (official step), plus the cron key: .env.example ships a
# fixed value for it, which would leave /api/cron/* open to anyone who has read
# that file.
_env_set "$ENV_FILE" NEXTAUTH_SECRET          "$nextauth_secret"
_env_set "$ENV_FILE" CALENDSO_ENCRYPTION_KEY  "$encryption_key"
_env_set "$ENV_FILE" CRON_API_KEY             "$cron_api_key"

# The compose file builds DATABASE_URL from these and the database service
# reads them; DATABASE_HOST is what start.sh waits on before running migrations.
_env_set "$ENV_FILE" POSTGRES_USER     "$postgres_user"
_env_set "$ENV_FILE" POSTGRES_PASSWORD "$postgres_password"
_env_set "$ENV_FILE" POSTGRES_DB       "$postgres_db"
_env_set "$ENV_FILE" DATABASE_HOST     "database:5432"
_env_set "$ENV_FILE" DATABASE_URL         "postgresql://$postgres_user:$postgres_password@database:5432/$postgres_db"
_env_set "$ENV_FILE" DATABASE_DIRECT_URL  "postgresql://$postgres_user:$postgres_password@database:5432/$postgres_db"

# Still named in the compose file's build args; unused by the pre-built image.
_env_set "$ENV_FILE" NEXT_PUBLIC_LICENSE_CONSENT "true"
_env_set "$ENV_FILE" CALCOM_TELEMETRY_DISABLED   "1"

if [[ -n "$VAPID_PUBLIC" ]]; then
  _env_set "$ENV_FILE" NEXT_PUBLIC_VAPID_PUBLIC_KEY "$VAPID_PUBLIC"
  _env_set "$ENV_FILE" VAPID_PRIVATE_KEY            "$VAPID_PRIVATE"
fi

if [[ "$configure_smtp" == "true" ]]; then
  _env_set "$ENV_FILE" EMAIL_FROM            "$smtp_from"
  _env_set "$ENV_FILE" EMAIL_SERVER_HOST     "$smtp_host"
  _env_set "$ENV_FILE" EMAIL_SERVER_PORT     "$smtp_port"
  if [[ -n "$smtp_user" ]]; then
    _env_set "$ENV_FILE" EMAIL_SERVER_USER     "$smtp_user"
    _env_set "$ENV_FILE" EMAIL_SERVER_PASSWORD "$smtp_pass"
  fi
fi
echo "==> .env written to $ENV_FILE (mode 600)"

# ── Adjust docker-compose.yml ─────────────────────────────────────────────────
echo "==> Adjusting docker-compose.yml"
_compose_drop_services redis calcom-api studio
_compose_edit '    container_name: database'
_compose_edit '    name: stack'
_compose_edit '    image: postgres'                     '    image: postgres:18'
_compose_edit '      - POSTGRES_USER=unicorn_user'      '      - POSTGRES_USER=${POSTGRES_USER}'
_compose_edit '      - POSTGRES_PASSWORD=magical_password' '      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}'
_compose_edit '      - POSTGRES_DB=calendso'            '      - POSTGRES_DB=${POSTGRES_DB}'
_compose_edit '      - 3000:3000'                       '      - "127.0.0.1:${CAL_PORT:-3000}:3000"'
if [[ -n "$image_tag" ]]; then
  _compose_edit '    image: calcom.docker.scarf.sh/calcom/cal.diy' "    image: calcom/cal.diy:$image_tag"
fi

echo "==> Validating docker-compose.yml against .env..."
docker compose config --quiet || _die "docker-compose.yml did not validate with this .env."
services="$(docker compose config --services | sort | tr '\n' ' ')"
[[ "$services" == "calcom database " ]] \
  || _die "expected the services 'calcom database' after the edits, got: $services- upstream has changed; update $(basename "$0")."
echo "    OK"

# ── Review ────────────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit .env? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$ENV_FILE"

read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$COMPOSE_FILE"

# ── Start ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Pulling images (the Cal.diy image is large - this can take a while)..."
docker compose pull
echo "==> Starting Cal.diy and PostgreSQL..."
# --no-build: the compose file can also build the image from source, which takes
# far longer and needs a different setup. If the pull left no image, fail here.
docker compose up -d --no-build
STARTED=false   # the stack is running: a failure from here on leaves a working install to fix, not to delete

# ── Wait for Cal.diy to answer ────────────────────────────────────────────────
# The first start runs the database migrations and seeds the app store before
# the web server comes up, so give it a few minutes. Any HTTP status below 500
# counts: a fresh install redirects / to the setup wizard.
echo -n "==> Waiting for Cal.diy to respond on 127.0.0.1:$port (first start runs migrations)"
CAL_UP=false
for _ in $(seq 1 90); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null || true)"
  if [[ "$CODE" =~ ^[0-9]{3}$ && "$CODE" != "000" && "$CODE" -lt 500 ]]; then
    CAL_UP=true
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

if [[ "$CAL_UP" == "true" ]]; then
  echo "==> Cal.diy is up."
else
  echo "WARNING: Cal.diy did not answer within ~7 minutes."
  echo "         Check the logs before continuing:"
  echo "           cd $INSTALL_DIR && docker compose logs -f calcom"
  read -rp "Continue with the Nginx setup anyway? [y/N] " ans_continue
  [[ "$ans_continue" =~ ^[Yy]$ ]] || exit 1
fi

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
    [[ "$ans_over" =~ ^[Yy]$ ]] || _die "Aborted - left $NGINX_AVAIL untouched."
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|cal\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:3000|127.0.0.1:$port|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL (domain + port substituted)"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$domain"
    echo "==> Symlink created."
  fi

  echo "==> Testing Nginx configuration..."
  sudo nginx -t || _die "the Nginx configuration test failed. Cal.diy itself is running. If the certificate is missing, run 'sudo certbot certonly --nginx -d $domain', then 'sudo nginx -t && sudo systemctl reload nginx'."
  echo "==> Reloading Nginx..."
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Cal.diy installation complete."
echo "    URL          : https://$domain"
echo "    Next         : open the URL - the setup wizard creates your first user."
echo "                   If it insists on connecting a calendar, skip it by opening"
echo "                   https://$domain/event-types (add calendars later under"
echo "                   Settings -> Integrations)."
echo "    Install dir  : $INSTALL_DIR  (clone of $CAL_REPO)"
echo "    Database     : docker volume database-data (PostgreSQL)"
echo "    Secrets      : $ENV_FILE (mode 600 - back this up)"
if [[ "$configure_smtp" != "true" ]]; then
  echo "    SMTP         : not configured - set EMAIL_FROM and EMAIL_SERVER_* in .env, then"
  echo "                   run: docker compose up -d"
fi
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo "    Logs    : docker compose logs -f calcom"
echo "    Status  : docker compose ps"
echo "    Update  : docker compose down && docker compose pull && docker compose up -d"
echo ""
echo "    If sign-in fails with CLIENT_FETCH_ERROR in the logs, the container cannot"
echo "    reach https://$domain from inside Docker; the Cal.diy README (Troubleshooting)"
echo "    covers the NEXTAUTH_URL change for that."
echo ""
