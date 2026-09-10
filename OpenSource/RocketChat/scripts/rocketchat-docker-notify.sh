#!/bin/bash
# ============================================================
# Rocket.Chat Notify (ntfy) Script v1.0
# ============================================================
# Adds the self-hosted ntfy server that the GraphenePush Rocket.Chat App publishes to, to an
# existing Rocket.Chat instance, and manages who receives notifications. Safe to re-run.
# Background: OpenSource/RocketChat/notification/README.md
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/nahicyan/Selfhosting/refs/heads/main/OpenSource/RocketChat/scripts/rocketchat-docker-notify.sh)"

set -euo pipefail

DEFAULT_RC_PATH="/var/www/docker/rocketchat"
RAW_BASE="https://raw.githubusercontent.com/nahicyan/Selfhosting/refs/heads/main/OpenSource/RocketChat/notification"
NOTIFY_COMPOSE="docker-compose-rc-notification.yml"
NGINX_TEMPLATE="ntfy-rocketchat-nginx.conf"
PUBLISHER="rocketchat"   # the one shared account the Rocket.Chat App publishes with

for cmd in docker curl; do
  command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is required."; exit 1; }
done

# ── Helpers ─────────────────────────────────────────────────

# The instance's own compose files plus ntfy's, so Compose sees one project and never reports the
# Rocket.Chat containers as orphans.
dc() {
  local args=() f
  for f in compose.database.yml compose.nats.yml compose.yml "$NOTIFY_COMPOSE"; do
    [ -f "$f" ] && args+=(-f "$f")
  done
  docker compose "${args[@]}" "$@"
}

ntfy_cli() { dc exec -T ntfy ntfy "$@"; }

user_exists() { ntfy_cli access "$1" >/dev/null 2>&1; }

ntfy_running() {
  [ -f "$NOTIFY_COMPOSE" ] || return 1
  grep -qx ntfy <<< "$(dc ps --status running --services 2>/dev/null || true)"
}

env_get() { grep -m1 "^$1=" .env | cut -d= -f2- | tr -d '"' || true; }

env_set() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    [ -z "$(tail -c1 .env)" ] || echo >> .env   # never glue onto a last line that lacks a newline
    echo "$1=$2" >> .env
  fi
}

publisher_token() {
  local out
  out="$(ntfy_cli token list "$PUBLISHER" 2>/dev/null || true)"
  if ! grep -m1 -o 'tk_[A-Za-z0-9]*' <<< "$out"; then
    out="$(ntfy_cli token add "$PUBLISHER")"
    grep -m1 -o 'tk_[A-Za-z0-9]*' <<< "$out"
  fi
}

# README step 4: A (the login a person's phone app uses) + B (the App's write-only grant on that
# person's topic). Running it again for an existing person just adds another topic.
add_person() {
  local reader topic pw
  echo ""
  read -rp "ntfy username for this person (e.g. nathan): " reader
  [[ "$reader" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Username may only use letters, digits, '.', '_' and '-'."; exit 1; }
  [ "$reader" != "$PUBLISHER" ] || { echo "'$PUBLISHER' is reserved for the Rocket.Chat App."; exit 1; }

  read -rp "Topic for $reader [${reader//./-}-rc-alerts]: " topic
  topic="${topic:-${reader//./-}-rc-alerts}"
  [[ "$topic" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "Topic may only use letters, digits, '_' and '-' (max 64)."; exit 1; }

  if user_exists "$reader"; then
    echo "==> $reader already exists - keeping their password."
  else
    echo "==> Creating $reader - enter the password they will log in with on their phone:"
    dc exec ntfy ntfy user add --role=user "$reader"
  fi
  ntfy_cli access "$reader" "$topic" read-write >/dev/null

  # The App only ever authenticates with its token, so the publisher's password is random and discarded.
  if ! user_exists "$PUBLISHER"; then
    pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    dc exec -T -e "NTFY_PASSWORD=$pw" ntfy ntfy user add --role=user "$PUBLISHER" >/dev/null
  fi
  ntfy_cli access "$PUBLISHER" "$topic" write-only >/dev/null

  echo "==> $reader can read '$topic', and the Rocket.Chat App can publish to it."
}

add_people() {
  local ans
  add_person
  while read -rp "Add another person? [y/N] " ans && [[ "$ans" =~ ^[Yy]$ ]]; do
    add_person
  done
}

remove_person() {
  local readers topics reader t i num ans
  mapfile -t readers < <(ntfy_cli user list 2>/dev/null | awk -v p="$PUBLISHER" '/^user / && $2 != p && $2 != "*" {print $2}')

  if [ ${#readers[@]} -eq 0 ]; then
    echo "No people found for $INSTANCE_NAME."
    exit 0
  fi

  echo ""
  echo "People:"
  for i in "${!readers[@]}"; do
    echo "  $((i+1))) ${readers[$i]}"
  done
  echo ""
  read -rp "Select person number to remove: " num

  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#readers[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi

  reader="${readers[$((num-1))]}"
  mapfile -t topics < <(ntfy_cli access "$reader" | awk '/access to topic / {print $NF}')

  echo ""
  echo "This deletes the ntfy login '$reader' - their phone stops receiving notifications."
  echo "  Topics: ${topics[*]:-none}"
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

  ntfy_cli user del "$reader" >/dev/null

  for t in "${topics[@]}"; do
    # Revoke the App's write grant only once nobody else reads the topic.
    if ! ntfy_cli user list | awk -v p="$PUBLISHER" -v t="$t" \
      '/^user / {u = $2} u != p && /access to topic / && $NF == t {found = 1} END {exit !found}'; then
      ntfy_cli access --reset "$PUBLISHER" "$t" >/dev/null
    fi
  done

  echo ""
  echo "✅ Removed $reader."
  echo "   Also delete their line from the App's Notify_Targets setting in Rocket.Chat."
}

print_next_steps() {
  local domain pairs u t
  domain="$(env_get NTFY_DOMAIN)"
  pairs="$(ntfy_cli user list 2>/dev/null | awk -v p="$PUBLISHER" \
    '/^user / {u = $2} u != p && u != "*" && /access to topic / {print u, $NF}' || true)"

  echo ""
  echo "✅ ntfy is ready for $INSTANCE_NAME"
  echo ""
  echo "Continue with OpenSource/RocketChat/notification/README.md:"
  echo "  5. Phone: install the ntfy app, add server https://$domain, log in with the person's"
  echo "     ntfy username, subscribe to their topic, and enable Instant delivery."
  echo "  6. Build and upload the GraphenePush Rocket.Chat App."
  echo "  7. Configure the App (Marketplace → Private Apps → GraphenePush → Settings):"
  echo "       Ntfy_Base_Url   : https://$domain"
  if user_exists "$PUBLISHER"; then
    echo "       Ntfy_Auth_Token : $(publisher_token)"
  fi
  echo "       Root_Url        : $(env_get ROOT_URL)"
  echo "       Notify_Targets  : one <rocket.chat username>:<topic> per line, from:"
  while read -r u t; do
    if [ -n "$u" ]; then
      echo "                         <rocket.chat username>:$t   (ntfy login: $u)"
    fi
  done <<< "$pairs"
}

echo ""
echo "=====> Rocket.Chat Notify (ntfy)"
echo "========================================"

# ── 1. Choose an action ─────────────────────────────────────
echo "What would you like to do?"
echo "  1) Install / update ntfy for an instance"
echo "  2) Add a person (ntfy login + topic)"
echo "  3) Remove a person"
read -rp "Select [1/2/3]: " ACTION
[[ "$ACTION" =~ ^[123]$ ]] || { echo "Invalid selection."; exit 1; }

# ── 2. Ask for Rocket.Chat instances location ────────────────
echo ""
echo "Where are your Rocket.Chat instances located?"
echo "  1) Default: $DEFAULT_RC_PATH"
echo "  2) Custom path"
read -rp "Select [1/2]: " LOCATION_CHOICE

if [ "$LOCATION_CHOICE" = "2" ]; then
  read -rep "Enter custom Rocket.Chat base path: " RC_BASE_PATH
  RC_BASE_PATH="${RC_BASE_PATH/#\~/$HOME}"
else
  RC_BASE_PATH="$DEFAULT_RC_PATH"
fi

if [ ! -d "$RC_BASE_PATH" ]; then
  echo "Error: Directory '$RC_BASE_PATH' not found."
  exit 1
fi

# ── 3. Select the instance ───────────────────────────────────
echo ""
echo "Scanning for Rocket.Chat instances in: $RC_BASE_PATH"
echo "--------------------------------------------"

# An instance is a rocketchat-compose checkout: <base>/<domain>/compose.yml
mapfile -t INSTANCES < <(find "$RC_BASE_PATH" -mindepth 2 -maxdepth 2 -name compose.yml -exec dirname {} \; | sort)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "No Rocket.Chat instances found in '$RC_BASE_PATH'."
  exit 1
fi

echo "Found instances:"
for i in "${!INSTANCES[@]}"; do
  echo "  $((i+1))) $(basename "${INSTANCES[$i]}")  (${INSTANCES[$i]})"
done

echo ""
read -rp "Select instance number: " INST_NUM

if ! [[ "$INST_NUM" =~ ^[0-9]+$ ]] || [ "$INST_NUM" -lt 1 ] || [ "$INST_NUM" -gt "${#INSTANCES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

INSTANCE_DIR="${INSTANCES[$((INST_NUM-1))]}"
INSTANCE_NAME="$(basename "$INSTANCE_DIR")"
cd "$INSTANCE_DIR"
[ -f .env ] || { echo "Error: no .env found in $INSTANCE_DIR."; exit 1; }

if [ "$ACTION" != "1" ]; then
  ntfy_running || { echo "Error: ntfy isn't running for $INSTANCE_NAME - run option 1 first."; exit 1; }
  if [ "$ACTION" = "2" ]; then
    add_people
    print_next_steps
  else
    remove_person
  fi
  exit 0
fi

# ── 4. Download the ntfy compose file and nginx template ─────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo ""
echo "==> Downloading ntfy files from GitHub…"
for f in "$NOTIFY_COMPOSE" "$NGINX_TEMPLATE"; do
  curl -fsSL "$RAW_BASE/$f" -o "$TMP_DIR/$f" || { echo "ERROR: could not download $RAW_BASE/$f"; exit 1; }
done

# ── 5. Gather ntfy domain & port ─────────────────────────────
# Lower-case on purpose: an exported NTFY_* shell variable would override .env inside Compose.
current_domain="$(env_get NTFY_DOMAIN)"
current_port="$(env_get NTFY_HOST_PORT)"

echo ""
read -rp "Enter ntfy domain (e.g. ntfy.example.com)${current_domain:+ [$current_domain]}: " ntfy_domain
ntfy_domain="${ntfy_domain:-$current_domain}"
[[ "$ntfy_domain" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "Invalid domain."; exit 1; }

read -rp "Enter host port to bind ntfy to [${current_port:-8090}]: " ntfy_port
ntfy_port="${ntfy_port:-${current_port:-8090}}"
[[ "$ntfy_port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }
[ "$ntfy_port" != "$(env_get HOST_PORT)" ] || { echo "Port $ntfy_port is already Rocket.Chat's HOST_PORT."; exit 1; }

echo ""
echo "==> Instance : $INSTANCE_NAME"
echo "==> Domain   : $ntfy_domain"
echo "==> Port     : $ntfy_port"

# ── 6. Configure & start ntfy ────────────────────────────────
cp "$TMP_DIR/$NOTIFY_COMPOSE" "$NOTIFY_COMPOSE"
env_set NTFY_DOMAIN "$ntfy_domain"
env_set NTFY_HOST_PORT "$ntfy_port"
grep -q "^NTFY_VERSION=" .env || env_set NTFY_VERSION latest
# Bind to localhost only — Nginx is the only public entry point to ntfy
grep -q "^NTFY_BIND_IP=" .env || env_set NTFY_BIND_IP 127.0.0.1

echo ""
echo "==> Starting ntfy…"
dc pull ntfy
dc up -d ntfy

# ntfy's CLI refuses to manage users until the server has created its auth database.
echo "==> Waiting for ntfy to become healthy…"
for i in $(seq 1 30); do
  curl -fsS "http://$(env_get NTFY_BIND_IP):$ntfy_port/v1/health" >/dev/null 2>&1 && break
  [ "$i" -lt 30 ] || { echo "ERROR: ntfy did not come up. Check: docker compose ... logs ntfy"; exit 1; }
  sleep 2
done
echo "==> ntfy is up."

# ── 7. Let's Encrypt ─────────────────────────────────────────
CERT="/etc/letsencrypt/live/$ntfy_domain/fullchain.pem"

echo ""
if sudo test -f "$CERT"; then
  echo "==> Certificate for $ntfy_domain already exists."
else
  echo "Note: $ntfy_domain must already point at this server's IP for this step."
  read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
  if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
    sudo certbot certonly --nginx -d "$ntfy_domain" || echo "WARNING: certbot failed - fix DNS, then re-run option 1."
  fi
fi

# ── 8. Nginx reverse proxy ───────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then

  NGINX_AVAIL="/etc/nginx/sites-available/$ntfy_domain"
  NGINX_ENABLED="/etc/nginx/sites-enabled/$ntfy_domain"

  sudo cp "$TMP_DIR/$NGINX_TEMPLATE" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|ntfy\.your-domain\.com|$ntfy_domain|g" \
    -e "s|127\.0\.0\.1:8090|127.0.0.1:$ntfy_port|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    # The vhost references the certificate, so enabling it without one fails nginx -t.
    if sudo test -f "$CERT"; then
      sudo ln -sf "$NGINX_AVAIL" "$NGINX_ENABLED"
      echo "==> Symlink created."
    else
      echo "WARNING: no certificate for $ntfy_domain yet - not enabling the site. Re-run option 1 once you have one."
    fi
  fi

  echo "==> Testing Nginx configuration…"
  if sudo nginx -t; then
    echo "==> Reloading Nginx…"
    sudo systemctl reload nginx
    echo "==> Nginx reloaded."
  else
    # Leaving a broken site enabled would block every later reload, Rocket.Chat's included.
    sudo rm -f "$NGINX_ENABLED"
    echo "ERROR: nginx -t failed - disabled $NGINX_ENABLED so your other sites keep reloading."
    exit 1
  fi
fi

# ── 9. People who receive notifications ──────────────────────
echo ""
read -rp "Would you like to add a person who receives notifications now? [Y/n] " ans_add
if [[ ! "$ans_add" =~ ^[Nn]$ ]]; then
  add_people
fi

print_next_steps
echo ""
echo "    Useful commands (run from $INSTANCE_DIR):"
echo "    Logs          : docker compose -f compose.database.yml -f compose.nats.yml -f compose.yml -f $NOTIFY_COMPOSE logs -f ntfy"
echo "    Add / remove  : re-run this script, options 2 and 3"
