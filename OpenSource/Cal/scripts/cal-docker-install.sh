#!/bin/bash
set -euo pipefail
# =============================================================================
# Cal.diy Docker Install Script
# =============================================================================
# Follows the cal.diy README's Docker instructions (Deployment -> Docker ->
# "Building from source with Docker"), behind a host Nginx reverse proxy:
#
#   1. git clone https://github.com/calcom/cal.diy.git
#   2. cp .env.example .env, with NEXTAUTH_SECRET (openssl rand -base64 32)
#      and CALENDSO_ENCRYPTION_KEY (openssl rand -base64 24) generated, plus
#      the VAPID keys web push needs
#   3. build the image (`docker compose build calcom`) against a database
#   4. docker compose up -d
#   5. open the site - the first-run setup wizard creates the first user
#
#   <install-dir>/              default /var/www/docker/cal/<domain>
#     |-- docker-compose.yml    from the clone, adjusted as listed below
#     `-- .env                  .env.example + the values above (mode 600)
#
# WHY THE IMAGE IS BUILT HERE. The README's `docker compose pull` route names
# calcom.docker.scarf.sh/calcom/cal.diy, and Cal.diy has never published an
# image under that name, on Docker Hub (calcom/cal.diy has no tags), on GHCR,
# or anywhere else - `pull` fails with "not found". The only official way to
# get an image is to build it, which is what upstream's own CI does.
#
# The build needs a reachable, empty PostgreSQL ("an available database is
# currently required during the build process" - README). This script starts a
# throwaway postgres container on Docker's default bridge, builds with the
# database's bridge IP as DATABASE_URL, and deletes the container afterwards.
# Nothing is published on the host and the build gets no network access to the
# host's own loopback services; --network host would give it both, and the
# README's DOCKER_BUILDKIT=0 route needs the deprecated legacy builder. The
# build compiles Cal.diy with a 6 GB Node heap, so the script checks memory and
# disk first (about 8 GiB of memory and 30 GiB of disk; the image is ~7 GiB and
# the build cache another ~19 GiB, which `docker builder prune` reclaims). It
# took under 8 minutes on a 32-core host and takes far longer on a small VPS.
#
# To skip the build - a small VPS, or an image built once elsewhere and pushed
# to a registry - set CAL_IMAGE and the script pulls that instead:
#     CAL_IMAGE=registry.example.com/cal-diy:v1 ./cal-docker-install.sh
#
# The cloned docker-compose.yml is used as-is except for these edits. Each one
# is an exact-line match and the script stops if upstream has changed a line,
# instead of guessing:
#
#   - The web app's image is a local name (cal-diy-<domain>:local), with
#     pull_policy: never so `docker compose pull` does not go looking for it in
#     a registry. With CAL_IMAGE it is that image, pulled normally.
#   - The web app is published on 127.0.0.1:${CAL_PORT} instead of 0.0.0.0:3000.
#     Nginx is the only public entry point.
#   - The database service reads its user, password and name from .env. Upstream
#     hardcodes unicorn_user / magical_password, while the web app builds its
#     DATABASE_URL from POSTGRES_* in .env - and .env.example does not define
#     those, so they have to be written here and agree with the database.
#   - postgres is pinned to 18. The volume path (/var/lib/postgresql) is the
#     PostgreSQL 18+ layout, and an unpinned `latest` would follow the next
#     major version into a data directory it cannot open.
#   - redis, calcom-api and studio are removed. The README supports running the
#     web app on its own (`docker compose up -d calcom`); calcom-api is the
#     optional API v2 (built from source, and it publishes host port 80, which
#     is Nginx's) and studio is Prisma Studio, which the compose file itself
#     says to remove in production because it exposes the database.
#   - The fixed container name and shared network name ("stack") are removed, so
#     every domain is its own Compose project. With them, two instances would
#     collide on the container name and share one network, where both
#     databases answer to the hostname "database".
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../cal-nginx.conf"

CAL_REPO="https://github.com/calcom/cal.diy.git"
DEFAULT_REF="main"
BUILD_DB_IMAGE="postgres:18"
CAL_IMAGE="${CAL_IMAGE:-}"   # optional pre-built image; empty = build from source

DEFAULT_BASE="/var/www/docker/cal"
DEFAULT_PORT="3000"

# What a build needs (see _preflight_build). Measured on a real build of main:
# about 8 GiB of memory at peak (on a 32-core host; fewer cores use less), and
# 26 GiB of disk at peak - the 7.4 GiB image plus 18.8 GiB of BuildKit cache -
# so 30 leaves a little room for the base images.
MIN_MEM_GIB=8
MIN_DISK_GIB=30

STARTED=false   # true from the clone until the stack is up: a failure in between leaves a half-made install, and _on_exit says how to clear it
BUILD_DB=""     # name of the throwaway build database while it exists

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_on_exit() {
  local rc=$?
  if [[ -n "$BUILD_DB" ]]; then
    docker rm -f -v "$BUILD_DB" >/dev/null 2>&1 || true   # -v: also its anonymous data volume, which plain `rm -f` leaves behind
  fi
  if [[ $rc -ne 0 && "$STARTED" == "true" ]]; then
    echo "" >&2
    echo "The install did not finish. $INSTALL_DIR is left as it is. To start over:" >&2
    echo "  (cd $INSTALL_DIR && docker compose down -v); sudo rm -rf $INSTALL_DIR" >&2
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT    # so Ctrl-C still runs _on_exit and removes the build database
trap 'exit 143' TERM

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

# A build that runs out of memory dies half an hour in with a bare "Killed", so
# say so up front. RAM plus swap counts: swap is the usual fix on a small VPS.
_preflight_build() {
  local mem_kib docker_root free_kib low=false
  mem_kib="$(awk '/^(MemTotal|SwapTotal):/ { s += $2 } END { print s + 0 }' /proc/meminfo)"
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  free_kib="$(df -Pk "${docker_root:-/var/lib/docker}" 2>/dev/null | awk 'NR==2 { print $4 }')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] || free_kib="$(df -Pk / | awk 'NR==2 { print $4 }')"

  if (( mem_kib < MIN_MEM_GIB * 1024 * 1024 )); then
    low=true
    echo ""
    echo "WARNING: this host has $(( mem_kib / 1024 / 1024 )) GiB of memory (RAM + swap). Building Cal.diy needs about"
    echo "         $MIN_MEM_GIB GiB, and a build that runs out of memory is killed part-way through."
    echo "         Add swap (fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile"
    echo "         && swapon /swapfile), or build the image elsewhere and re-run with CAL_IMAGE=..."
  fi
  if (( free_kib < MIN_DISK_GIB * 1024 * 1024 )); then
    low=true
    echo ""
    echo "WARNING: only $(( free_kib / 1024 / 1024 )) GiB is free where Docker stores its data (${docker_root:-/var/lib/docker});"
    echo "         a build needs about $MIN_DISK_GIB GiB at its peak (a ~7 GiB image plus ~19 GiB of build cache,"
    echo "         which you can reclaim afterwards). Free up space, or build elsewhere and use CAL_IMAGE=..."
  fi
  if [[ "$low" == "true" ]]; then
    read -rp "Continue anyway? [y/N] " ans_low
    [[ "$ans_low" =~ ^[Yy]$ ]] || _die "Aborted - free up memory/disk, or use CAL_IMAGE."
  fi
}

# Build the web app's image the way the README describes, with the empty
# database it needs (see the header).
_build_image() {
  local pw ip i last
  pw="$(openssl rand -hex 16)"
  echo "==> Starting a throwaway PostgreSQL ($BUILD_DB_IMAGE) for the build"
  BUILD_DB="cal-build-db-$$"
  docker run -d --rm --name "$BUILD_DB" \
    -e POSTGRES_USER=build -e POSTGRES_PASSWORD="$pw" -e POSTGRES_DB=calendso \
    "$BUILD_DB_IMAGE" >/dev/null || _die "could not start the throwaway build database."
  # Docker 29 dropped the top-level .NetworkSettings.IPAddress; read the per-network one.
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BUILD_DB")"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || _die "could not read the build database's IP address (got '$ip')."

  # Wait until it accepts connections over the network, from a container on the
  # same bridge the build steps use. That is both the readiness check (an
  # in-container check can pass during postgres's init phase, before TCP is up)
  # and the reachability check, so a bridge that cannot carry it fails here and
  # not half an hour into the build.
  echo -n "==> Waiting for it to accept connections at $ip:5432"
  for i in $(seq 1 60); do
    if last="$(docker run --rm "$BUILD_DB_IMAGE" pg_isready -h "$ip" -p 5432 -U build -d calendso 2>&1)"; then
      break
    fi
    if [[ $i -eq 60 ]]; then
      echo ""
      _die "the build database did not become reachable at $ip:5432 from the default Docker bridge. Last answer: ${last:-(none)}. If that is a Docker error (image pull, daemon), fix it first; otherwise check whether inter-container communication is disabled (icc=false)."
    fi
    echo -n "."
    sleep 2
  done
  echo ""

  echo "==> Building the Cal.diy image (compiles the app; several minutes on a big host, far longer on a small VPS)"
  DATABASE_URL="postgresql://build:$pw@$ip:5432/calendso" docker compose build calcom \
    || _die "the Cal.diy build failed - see the output above. If it ended in 'Killed' or exit code 137 the host ran out of memory: add swap, or build the image elsewhere and re-run with CAL_IMAGE=... (see the top of this script)."

  docker rm -f -v "$BUILD_DB" >/dev/null 2>&1 || true
  BUILD_DB=""
  docker image inspect "$IMAGE_REF" >/dev/null 2>&1 || _die "the build finished but the image $IMAGE_REF is not there."
  echo "==> Built $IMAGE_REF"
  echo "    The build left about 19 GiB of BuildKit cache behind. It only speeds up a rebuild, and"
  echo "    'docker builder prune' reclaims it (it clears every unused build cache on this host)."
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in git docker curl openssl od base64 awk sed mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot reach the Docker daemon - is it running, and is this user allowed to use it?"
[ -f "$NGINX_CONF_SRC" ] || _die "cal-nginx.conf not found at $NGINX_CONF_SRC"
if [[ -n "$CAL_IMAGE" ]]; then
  [[ "$CAL_IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] || _die "CAL_IMAGE '$CAL_IMAGE' is not a valid image reference."
fi

echo ""
echo "=====> Cal.diy Install"
echo "========================================"
echo "Source: $CAL_REPO"
if [[ -n "$CAL_IMAGE" ]]; then
  echo "Image : $CAL_IMAGE (pre-built, from CAL_IMAGE)"
else
  echo "Image : built from source on this host"
fi
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

# ── 4. Version ────────────────────────────────────────────────────────────────
# `main` is what the README's `git clone` gives you. A release tag (e.g. v6.2.0)
# pins the version instead. It is checked against the repo now, so a typo fails
# here and not after the prompts.
echo ""
read -rp "Branch or tag to install [$DEFAULT_REF]: " answer
ref="${answer:-$DEFAULT_REF}"
[[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || _die "'$ref' is not a valid branch or tag name."
git ls-remote --exit-code "$CAL_REPO" "refs/heads/$ref" "refs/tags/$ref" >/dev/null 2>&1 \
  || _die "'$ref' is not a branch or tag of $CAL_REPO (or the repository could not be reached)."

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

# ── Build requirements ────────────────────────────────────────────────────────
[[ -n "$CAL_IMAGE" ]] || _preflight_build

# ── Derived values ────────────────────────────────────────────────────────────
PROJECT_NAME="cal-${domain//./-}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
IMAGE_REF="${CAL_IMAGE:-cal-diy-${domain//./-}:local}"

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
echo "Version         : $ref"
echo "Stack           : Cal.diy web app + PostgreSQL (docker volume database-data)"
if [[ -n "$CAL_IMAGE" ]]; then
  echo "Image           : $CAL_IMAGE (pulled)"
else
  echo "Image           : $IMAGE_REF (built from source - needs ~8 GiB memory, ~30 GiB disk, and time)"
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
echo "==> Cloning $CAL_REPO ($ref)"
sudo mkdir -p "$(dirname "$INSTALL_DIR")"
sudo git clone --depth 1 --branch "$ref" --recursive "$CAL_REPO" "$INSTALL_DIR" \
  || _die "clone failed - check network access to $CAL_REPO"
STARTED=true
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
cd "$INSTALL_DIR"
[ -f "$COMPOSE_FILE" ] || _die "docker-compose.yml is not in the cloned repo."
[ -f .env.example ]    || _die ".env.example is not in the cloned repo."
built_from="$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
echo "==> Cloned to $INSTALL_DIR ($ref @ $built_from)"

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

# Still named in the compose file's build args, so it must be defined.
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

# The web app's image line names calcom/cal.diy at the scarf gateway on main
# and calcom/cal.com in the v6.2.0 release; either way that image is not one we
# can use, so it is replaced.
image_edited=false
for old in '    image: calcom.docker.scarf.sh/calcom/cal.diy' '    image: calcom.docker.scarf.sh/calcom/cal.com'; do
  if grep -qxF "$old" "$COMPOSE_FILE"; then
    if [[ -n "$CAL_IMAGE" ]]; then
      _compose_edit "$old" "    image: $IMAGE_REF"
    else
      _compose_edit "$old" "    image: $IMAGE_REF"$'\n'"    pull_policy: never"
    fi
    image_edited=true
    break
  fi
done
[[ "$image_edited" == "true" ]] || _die "docker-compose.yml no longer has the calcom image line - upstream has changed; update $(basename "$0")."

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

# ── Get the image ─────────────────────────────────────────────────────────────
echo ""
echo "==> Pulling PostgreSQL..."
docker compose pull database
if [[ -n "$CAL_IMAGE" ]]; then
  if docker image inspect "$CAL_IMAGE" >/dev/null 2>&1; then
    echo "==> $CAL_IMAGE is already on this host."
  else
    echo "==> Pulling $CAL_IMAGE..."
    docker compose pull calcom || _die "could not pull $CAL_IMAGE - check the name, and 'docker login' if it is private."
  fi
else
  _build_image
fi

# ── Start ─────────────────────────────────────────────────────────────────────
echo "==> Starting Cal.diy and PostgreSQL..."
# --no-build: the image is already there, and a stray rebuild here would fail
# without the build database.
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
echo "    Install dir  : $INSTALL_DIR  (clone of $CAL_REPO, $ref @ $built_from)"
echo "    Image        : $IMAGE_REF"
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
if [[ -n "$CAL_IMAGE" ]]; then
  echo "    Update  : docker compose down && docker compose pull && docker compose up -d"
fi
echo ""
echo "    If sign-in fails with CLIENT_FETCH_ERROR in the logs, the container cannot"
echo "    reach https://$domain from inside Docker; the Cal.diy README (Troubleshooting)"
echo "    covers the NEXTAUTH_URL change for that."
echo ""
