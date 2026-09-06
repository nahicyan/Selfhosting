#!/bin/bash
set -euo pipefail
# =============================================================================
# Keycloak Docker Install Script v2.0
# =============================================================================
# Clones keycloak-production-docker-compose into an instance directory, writes
# its .env, and brings the stack up behind a host Nginx reverse proxy.
#
#   /var/www/docker/keycloak/<domain>/
#     |-- docker-compose.external-cert.yml   from the repo
#     |-- .env                               written here (mode 600)
#     `-- themes/                            mounted read-only; a subdirectory
#                                            per custom theme (see Theme.md)
#
# This script does NOT write compose files. Everything about the stack itself -
# images, volumes, ports, health, the Postgres data layout - lives in the repo.
# The only thing configured here is .env, which the compose files read.
#
# Two modes:
#   1) New instance  - prompts for every value and writes a fresh .env.
#   2) Restore .env  - reuses the .env from a keycloak-docker-backup.sh
#                      snapshot, so the instance comes up with the original
#                      admin and database credentials. Use this mode before
#                      restoring that snapshot's Postgres dump: the dump
#                      carries its own DB role, and Keycloak has to be
#                      configured with credentials that match it.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../keycloak-docker-nginx.conf"

COMPOSE_REPO="https://github.com/nahicyan/keycloak-production-docker-compose"
COMPOSE_FILENAME="docker-compose.external-cert.yml"

KEYCLOAK_BASE="/var/www/docker/keycloak"
DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_PORT="8090"

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_nice_date() {
  local stamp="$1"
  IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
}

_mask() { [[ -n "${1:-}" ]] && echo "(set, ${#1} chars)" || echo "(empty)"; }

_status() {  # _status <label> <value> [secret]
  local label="$1" value="${2:-}" secret="${3:-}"
  if [[ -n "$value" ]]; then
    if [[ -n "$secret" ]]; then
      printf "  [ok] %-18s %s\n" "$label" "$(_mask "$value")"
    else
      printf "  [ok] %-18s %s\n" "$label" "$value"
    fi
  else
    printf "  [--] %-18s (missing - will ask)\n" "$label"
  fi
}

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Secrets end up in three places that each have their own quoting rules:
#   - .env, read by `source` in the backup/restore scripts
#   - .env, read by Compose's dotenv parser for interpolation
#   - an application/x-www-form-urlencoded POST body, which is how
#     keycloak-docker-backup.sh logs in to the admin API to export realms
# This character set is safe in all three, so a password chosen here can never
# silently break a later backup.
_valid_secret() {
  [[ "$1" =~ ^[A-Za-z0-9._~@!?*:-]{8,}$ ]]
}

_gen_secret() { openssl rand -hex 24; }

_ask_secret() {  # _ask_secret <var-name> <label>
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
      echo "    Rejected. Use 8+ characters from: A-Z a-z 0-9 . _ ~ - @ ! ? * :"
      echo "    (anything else breaks either .env parsing or the admin-API login"
      echo "     that keycloak-docker-backup.sh uses to export realms.)"
      continue
    fi
    _ref="$first"
    return 0
  done
}

# Update a key in an env file in place, appending it if it isn't there.
# Done line-by-line rather than with sed so values never need escaping.
_env_set() {  # _env_set <file> <key> <value>
  local file="$1" key="$2" value="$3" line found=0 tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
      if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
        found=1
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  [ "$found" -eq 0 ] && printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$file"   # rewrite in place so the file keeps its 600 mode
  rm -f "$tmp"
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in git docker curl openssl sed find mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."

echo ""
echo "=====> Keycloak Install"
echo "========================================"
echo "Compose source: $COMPOSE_REPO"
echo ""

# ── Mode selection ────────────────────────────────────────────────────────────
echo "  1) New instance                (enter all values now)"
echo "  2) Restore .env from a backup  (reuse credentials from a snapshot)"
echo ""
read -rp "Select [1/2]: " MODE_CHOICE
echo ""

case "$MODE_CHOICE" in
  1) IS_NEW=true  ;;
  2) IS_NEW=false ;;
  *) _die "Invalid selection." ;;
esac

# ── Values this script needs, however they get filled ─────────────────────────
domain=""
port=""
kc_user=""
kc_password=""
pg_user=""
pg_password=""
RESTORED_ENV=""

# ── Restore path: locate and load a backed-up .env ────────────────────────────
if [[ "$IS_NEW" == "false" ]]; then
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

  KEYCLOAK_BACKUPS_DIR="$BACKUP_ROOT/keycloak"
  [ -d "$KEYCLOAK_BACKUPS_DIR" ] || _die "'$KEYCLOAK_BACKUPS_DIR' not found."

  # ── Select the instance (domain) the backup came from ──────────────────────
  echo ""
  mapfile -t DOMAIN_DIRS < <(find "$KEYCLOAK_BACKUPS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
  [ ${#DOMAIN_DIRS[@]} -gt 0 ] || _die "No domain backup folders found in '$KEYCLOAK_BACKUPS_DIR'."

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

  # ── List snapshots ─────────────────────────────────────────────────────────
  mapfile -t SNAPSHOTS < <(find "$DOMAIN_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)
  [ ${#SNAPSHOTS[@]} -gt 0 ] || _die "No backup snapshots found in '$(basename "$DOMAIN_DIR")'."

  echo ""
  printf "  %-4s %-33s %-10s %-12s %-6s\n" "#" "Date" "Postgres" "Realms" ".env"
  printf "  %-4s %-33s %-10s %-12s %-6s\n" "----" "---------------------------------" "----------" "------------" "------"
  for i in "${!SNAPSHOTS[@]}"; do
    STAMP=$(basename "${SNAPSHOTS[$i]}")
    NICE=$(_nice_date "$STAMP")
    PG_S=$([ -f "${SNAPSHOTS[$i]}/postgres/keycloak.sql.gz" ] && echo "ok" || echo "--")
    # `|| true`: with pipefail, find failing on a snapshot that has no keycloak/
    # subdirectory would fail the assignment and abort the script.
    KC_N=$(find "${SNAPSHOTS[$i]}/keycloak" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ' || true)
    ENV_S=$([ -f "${SNAPSHOTS[$i]}/env/.env" ] && echo "ok" || echo "--")
    printf "  %-4s %-33s %-10s %-12s %-6s\n" "$((i+1)))" "$NICE" "$PG_S" "${KC_N} realm(s)" "$ENV_S"
  done

  echo ""
  read -rp "Select backup number to take the .env from: " TS_NUM
  if ! [[ "$TS_NUM" =~ ^[0-9]+$ ]] || [ "$TS_NUM" -lt 1 ] || [ "$TS_NUM" -gt "${#SNAPSHOTS[@]}" ]; then
    _die "Invalid selection."
  fi

  SNAPSHOT_DIR="${SNAPSHOTS[$((TS_NUM-1))]}"
  RESTORED_ENV="$SNAPSHOT_DIR/env/.env"
  [ -f "$RESTORED_ENV" ] || _die "This snapshot has no env/.env - pick another one, or install as a new instance."

  # Sourcing puts KEYCLOAK_* / POSTGRES_* into this shell, and Compose gives
  # the shell environment precedence over --env-file. If the domain or port is
  # changed at the prompts below, a leftover shell value would silently win
  # over the file, so every name is copied out and then unset.
  # shellcheck disable=SC1090
  source "$RESTORED_ENV"
  domain="${KEYCLOAK_URL:-}"
  port="${KEYCLOAK_PORT:-}"
  kc_user="${KEYCLOAK_USER:-}"
  kc_password="${KEYCLOAK_PASSWORD:-}"
  pg_user="${POSTGRES_USER:-}"
  pg_password="${POSTGRES_PASSWORD:-}"
  unset KEYCLOAK_URL KEYCLOAK_PORT KEYCLOAK_USER KEYCLOAK_PASSWORD \
        POSTGRES_USER POSTGRES_PASSWORD COMPOSE_PROJECT_NAME

  echo ""
  echo "==> Loaded: $RESTORED_ENV"
  _status "KEYCLOAK_URL"      "$domain"
  _status "KEYCLOAK_PORT"     "$port"
  _status "KEYCLOAK_USER"     "$kc_user"
  _status "KEYCLOAK_PASSWORD" "$kc_password" secret
  _status "POSTGRES_USER"     "$pg_user"
  _status "POSTGRES_PASSWORD" "$pg_password" secret
  echo ""
  echo "    Credentials from the snapshot are kept as-is. Anything missing is"
  echo "    asked for below."
  echo ""
fi

# ── Domain ────────────────────────────────────────────────────────────────────
if [[ -n "$domain" ]]; then
  read -rp "Domain [$domain]: " answer
  domain="${answer:-$domain}"
else
  read -rp "Enter domain name (e.g. auth.example.com): " domain
fi
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
# Lowercased before use: hostnames are case-insensitive, but the Compose
# project name derived from this one has to be lowercase or Compose refuses it.
domain="${domain,,}"

# ── Port ──────────────────────────────────────────────────────────────────────
# Written to .env as KEYCLOAK_PORT, which the compose file publishes on
# 127.0.0.1, and substituted into the Nginx vhost further down.
echo ""
echo "Keycloak is published on 127.0.0.1:<port> and proxied by Nginx."
read -rp "Enter host port for Keycloak [${port:-$DEFAULT_PORT}]: " answer
port="${answer:-${port:-$DEFAULT_PORT}}"
_valid_port "$port" || _die "Port must be a number between 1 and 65535."

if command -v ss >/dev/null 2>&1; then
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
    echo ""
    echo "WARNING: something is already listening on port $port:"
    ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
    read -rp "Continue anyway? [y/N] " ans_port
    [[ "$ans_port" =~ ^[Yy]$ ]] || _die "Aborted - pick a free port."
  fi
fi

# ── Credentials ───────────────────────────────────────────────────────────────
echo ""
if [[ "$IS_NEW" == "true" ]]; then
  echo "==> Credentials for the new instance:"
else
  echo "==> Filling in anything the snapshot's .env did not have:"
fi

if [[ -z "$kc_user" ]]; then
  read -rp "  Keycloak admin username [admin]: " kc_user
  kc_user="${kc_user:-admin}"
fi
[[ -z "$kc_password" ]] && _ask_secret kc_password "Keycloak admin password"

if [[ -z "$pg_user" ]]; then
  read -rp "  PostgreSQL username [postgres]: " pg_user
  pg_user="${pg_user:-postgres}"
fi
[[ -z "$pg_password" ]] && _ask_secret pg_password "PostgreSQL password"

# ── Paths and confirmation ────────────────────────────────────────────────────
INSTALL_DIR="$KEYCLOAK_BASE/$domain"
COMPOSE_FILE="$INSTALL_DIR/$COMPOSE_FILENAME"
ENV_FILE="$INSTALL_DIR/.env"
# Compose derives its project name from the directory otherwise, which would
# collide across instances after normalisation; pin it so container, volume and
# network names stay predictable and unique per domain. The repo's compose files
# name the network ${COMPOSE_PROJECT_NAME:-keycloak}-network from this.
PROJECT_NAME="keycloak-${domain//./-}"

if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  _die "$INSTALL_DIR already exists and is not empty - remove that instance first, or use another domain."
fi

echo ""
echo "==================== SUMMARY ===================="
echo "Mode            : $( [[ "$IS_NEW" == "true" ]] && echo "New instance" || echo "Restore .env from backup" )"
[[ -n "$RESTORED_ENV" ]] && echo "Source .env     : $RESTORED_ENV"
echo "Compose repo    : $COMPOSE_REPO"
echo "Compose file    : $COMPOSE_FILENAME"
echo "Domain          : $domain"
echo "URL             : https://$domain"
echo "Host port       : 127.0.0.1:$port"
echo "Install dir     : $INSTALL_DIR"
echo "Compose project : $PROJECT_NAME"
echo "Admin user      : $kc_user"
echo "Admin password  : $(_mask "$kc_password")"
echo "Postgres user   : $pg_user"
echo "Postgres passwd : $(_mask "$pg_password")"
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Clone the compose repo ────────────────────────────────────────────────────
echo ""
echo "==> Cloning $COMPOSE_REPO"
sudo mkdir -p "$KEYCLOAK_BASE"
sudo git clone --depth 1 "$COMPOSE_REPO" "$INSTALL_DIR" \
  || _die "clone failed - check network access to $COMPOSE_REPO"
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
cd "$INSTALL_DIR"

[ -f "$COMPOSE_FILE" ] || _die "$COMPOSE_FILENAME is not in the cloned repo."
echo "==> Cloned to $INSTALL_DIR ($(git -C "$INSTALL_DIR" rev-parse --short HEAD))"

# ── Write .env ────────────────────────────────────────────────────────────────
if [[ -n "$RESTORED_ENV" ]]; then
  # Copy the snapshot's file verbatim so any extra keys it carries survive,
  # then reconcile only the keys this install actually decides.
  echo "==> Restoring .env from backup"
  cp "$RESTORED_ENV" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  _env_set "$ENV_FILE" COMPOSE_PROJECT_NAME "$PROJECT_NAME"
  _env_set "$ENV_FILE" KEYCLOAK_URL         "$domain"
  _env_set "$ENV_FILE" KEYCLOAK_PORT        "$port"
  _env_set "$ENV_FILE" KEYCLOAK_USER        "$kc_user"
  _env_set "$ENV_FILE" POSTGRES_USER        "$pg_user"
  # Passwords are left exactly as the snapshot wrote them, quoting included.
  [[ -z "$(grep -E '^[[:space:]]*KEYCLOAK_PASSWORD=' "$ENV_FILE" || true)" ]] && \
    _env_set "$ENV_FILE" KEYCLOAK_PASSWORD "'$kc_password'"
  [[ -z "$(grep -E '^[[:space:]]*POSTGRES_PASSWORD=' "$ENV_FILE" || true)" ]] && \
    _env_set "$ENV_FILE" POSTGRES_PASSWORD "'$pg_password'"
else
  echo "==> Writing .env"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  cat > "$ENV_FILE" <<ENV_EOF
# Keycloak instance configuration - generated by keycloak-docker-install.sh
# Read by docker compose (--env-file) and sourced by the backup/restore scripts.
# Secrets are single-quoted: safe for both bash's \`source\` and Compose's parser.
COMPOSE_PROJECT_NAME=$PROJECT_NAME

# Bare hostname, no scheme. The backup/restore scripts build https://\$KEYCLOAK_URL
# from it, and Compose passes it to Keycloak as KC_HOSTNAME.
KEYCLOAK_URL=$domain
# Host port published on 127.0.0.1 and proxied by Nginx.
KEYCLOAK_PORT=$port

# Bootstrap admin. Only used while the database is still empty - after the
# first start the account lives in Postgres, and changing it here does nothing.
KEYCLOAK_USER=$kc_user
KEYCLOAK_PASSWORD='$kc_password'

POSTGRES_USER=$pg_user
POSTGRES_PASSWORD='$pg_password'
ENV_EOF
fi
echo "==> .env written to $ENV_FILE (mode 600)"

DC="docker compose --env-file $ENV_FILE -f $COMPOSE_FILE"
DC_SHORT="docker compose --env-file .env -f $COMPOSE_FILENAME"

# ── Validate before starting anything ─────────────────────────────────────────
echo "==> Validating $COMPOSE_FILENAME against .env..."
$DC config >/dev/null || _die "$COMPOSE_FILENAME did not validate with this .env."
echo "    OK"

# ── Create bind-mount sources the compose file expects ────────────────────────
# Docker creates a missing bind source itself, as a root-owned directory. Read
# the resolved paths back out of `config` so this works whatever the compose
# file names them - today that is ./themes, mounted read-only.
mapfile -t BIND_SOURCES < <($DC config 2>/dev/null | sed -n "s|^[[:space:]]*source: \($INSTALL_DIR/.*\)$|\1|p" | sort -u || true)
for d in "${BIND_SOURCES[@]}"; do
  if [ ! -e "$d" ]; then
    mkdir -p "$d"
    echo "==> Created bind-mount source: $d"
  fi
done

# ── Review ────────────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit .env? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$ENV_FILE"

read -rp "Would you like to review/edit $COMPOSE_FILENAME? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$COMPOSE_FILE"

# ── Start ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Pulling images..."
$DC pull
echo "==> Starting Keycloak and PostgreSQL..."
$DC up -d

# ── Wait for Keycloak to answer ───────────────────────────────────────────────
# First boot runs the full database migration, so give it a few minutes.
echo -n "==> Waiting for Keycloak to respond on 127.0.0.1:$port"
KC_UP=false
for _ in $(seq 1 90); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${port}/realms/master" 2>/dev/null || echo "000")
  if [ "$CODE" != "000" ] && [ "$CODE" -lt 500 ]; then
    KC_UP=true
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

if [[ "$KC_UP" == "true" ]]; then
  echo "==> Keycloak is up."
else
  echo "WARNING: Keycloak did not answer within ~7 minutes."
  echo "         Check the logs before continuing:"
  echo "           cd $INSTALL_DIR && $DC_SHORT logs -f keycloak"
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

  [[ -f "$NGINX_CONF_SRC" ]] || _die "nginx config template not found at $NGINX_CONF_SRC"

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|auth\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:8090|127.0.0.1:$port|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL"

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

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Keycloak installation complete."
echo "    URL           : https://$domain"
echo "    Admin console : https://$domain/admin"
echo "    Admin user    : $kc_user"
echo "    Install dir   : $INSTALL_DIR  (clone of $COMPOSE_REPO)"
echo "    Compose file  : $COMPOSE_FILENAME"
echo "    Secrets       : $ENV_FILE (mode 600 - back this up)"
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : $DC_SHORT up -d"
echo "    Stop    : $DC_SHORT down"
echo "    Restart : $DC_SHORT restart"
echo "    Logs    : $DC_SHORT logs -f keycloak"
echo "    Status  : $DC_SHORT ps"
echo "    Update  : git pull && $DC_SHORT up -d      # picks up compose repo changes"
echo ""
if [[ -n "$RESTORED_ENV" ]]; then
  echo "    This instance reuses the credentials from:"
  echo "      $RESTORED_ENV"
  echo "    The database is still empty. To bring the data back, run:"
  echo "      $SCRIPT_DIR/keycloak-docker-restore.sh   (option 2 - Postgres)"
  echo "    After that restore, the admin account is whatever the dump contains,"
  echo "    not the bootstrap values above."
  echo ""
fi
echo "    Custom themes: build one into $INSTALL_DIR/themes/<name> following"
echo "    Theme.md, restart, then select it under Realm settings -> Themes."
echo ""
echo "    Back up with : $SCRIPT_DIR/keycloak-docker-backup.sh"
