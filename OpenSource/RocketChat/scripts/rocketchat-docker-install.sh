#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../rocketchat-nginx.conf"

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. chat.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

read -rp "Enter host port to bind RocketChat to (e.g. 3000): " port
[[ -z "$port" ]] && { echo "Port cannot be empty."; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }

echo
echo "==> Domain : $domain"
echo "==> Port   : $port"
echo

# ── Clone & configure ─────────────────────────────────────────────────────────
INSTALL_DIR="/var/www/docker/rocketchat/$domain"

sudo mkdir -p /var/www/docker/rocketchat
git clone --depth 1 https://github.com/RocketChat/rocketchat-compose.git "$INSTALL_DIR"
cd "$INSTALL_DIR"
cp .env.example .env

# Seed .env with user-supplied values
sed -i \
  -e "s|^RELEASE=.*|RELEASE=latest|" \
  -e "s|^DOMAIN=.*|DOMAIN=$domain|" \
  -e "s|^ROOT_URL=.*|ROOT_URL=https://$domain|" \
  -e "s|^LETSENCRYPT_ENABLED=.*|LETSENCRYPT_ENABLED=false|" \
  -e "s|^LETSENCRYPT_EMAIL=.*|LETSENCRYPT_EMAIL=demo@email.com|" \
  -e "s|^TRAEFIK_PROTOCOL=.*|TRAEFIK_PROTOCOL=http|" \
  -e "s|^GRAFANA_DOMAIN=.*|GRAFANA_DOMAIN=|" \
  -e "s|^GRAFANA_PATH=.*|GRAFANA_PATH=/grafana|" \
  -e "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=your_secure_password|" \
  -e "s|^HOST_PORT=.*|HOST_PORT=$port|" \
  .env

# Append keys that may not exist in the example yet
grep -q "^DOMAIN=" .env        || echo "DOMAIN=$domain"                >> .env
grep -q "^ROOT_URL=" .env      || echo "ROOT_URL=https://$domain"      >> .env
grep -q "^HOST_PORT=" .env     || echo "HOST_PORT=$port"               >> .env
# Bind to localhost only — Nginx proxies to RocketChat; 0.0.0.0 would expose ports 3000 and 9458 publicly
grep -q "^BIND_IP=" .env       || echo "BIND_IP=127.0.0.1"             >> .env

# ── Review .env ───────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit the .env file? [y/N] " ans_env
if [[ "$ans_env" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" .env
fi

# ── Review compose.yml ────────────────────────────────────────────────────────
read -rp "Would you like to review/edit compose.yml? [y/N] " ans_compose
if [[ "$ans_compose" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" compose.yml
fi

# ── Start containers ──────────────────────────────────────────────────────────
echo "==> Starting RocketChat containers…"
docker compose -f compose.database.yml -f compose.nats.yml -f compose.yml up -d
echo "==> Containers started."
echo

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
fi

# ── Nginx reverse proxy ───────────────────────────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then

  NGINX_AVAIL="/etc/nginx/sites-available/$domain"

  if [[ ! -f "$NGINX_CONF_SRC" ]]; then
    echo "ERROR: nginx config template not found at $NGINX_CONF_SRC"
    exit 1
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|chat\.example\.org|$domain|g" \
    -e "s|127\.0\.0\.1:3000|127.0.0.1:$port|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$domain"
    echo "==> Symlink created."
  fi

  echo "==> Testing Nginx configuration…"
  sudo nginx -t
  echo "==> Reloading Nginx…"
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

echo
echo "==> RocketChat installation complete."
echo "    URL: https://$domain"
echo
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : docker compose -f compose.database.yml -f compose.nats.yml -f compose.yml up -d"
echo "    Stop    : docker compose -f compose.database.yml -f compose.nats.yml -f compose.yml down"
echo "    Restart : docker compose -f compose.database.yml -f compose.nats.yml -f compose.yml restart"
