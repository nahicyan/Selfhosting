#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../matrix-element-call-nginx.conf"

# Sets up the Element Call backend (LiveKit SFU + lk-jwt-service). Independent
# of Synapse/MAS — no shared secrets — but Synapse's well-known client JSON
# must point at this domain for clients to find it (see matrix-synapse-install.sh).

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter RTC / Element Call backend domain (e.g. rtc.example.com): " rtcdomain
[[ -z "$rtcdomain" ]] && { echo "RTC domain cannot be empty."; exit 1; }

echo "==> RTC domain : $rtcdomain"
echo

# ── Generate random secrets ─────────────────────────────────────────────────────
# livekit_key/secret are self-contained to this backend — shared only between
# livekit.yaml and lk-jwt-service's environment in the same docker-compose file.
livekit_key="matrixrtc"
livekit_secret=$(openssl rand -base64 48)

# Get public IP (needed for LiveKit external IP)
echo "==> Detecting public IP..."
ip=$(curl -s https://api.ipify.org)
echo "==> Public IP: $ip"

# ── Set up Element Call backend directory ───────────────────────────────────────
INSTALL_DIR="/var/www/docker/RTC/$rtcdomain"
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "==> Writing livekit.yaml..."
sudo tee livekit.yaml > /dev/null << LVEOF
port: 7880
bind_addresses:
  - "0.0.0.0"
rtc:
  tcp_port: 7881
  udp_port: 7882
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: true
keys:
  $livekit_key: $livekit_secret
room:
  auto_create: false
logging:
  level: info
LVEOF

echo "==> Writing docker-compose.yml..."
sudo tee docker-compose.yml > /dev/null << RTCEOF
services:
  livekit:
    image: livekit/livekit-server:latest
    container_name: livekit-sfu
    command: --config /etc/livekit.yaml
    network_mode: host
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml:ro
    restart: unless-stopped

  lk-jwt-service:
    image: ghcr.io/element-hq/lk-jwt-service:latest
    container_name: lk-jwt-service
    environment:
      - LIVEKIT_JWT_PORT=8070
      - LIVEKIT_URL=wss://$rtcdomain/livekit/sfu
      - LIVEKIT_KEY=$livekit_key
      - LIVEKIT_SECRET=$livekit_secret
      # Grants any homeserver's users full media-relay access. Safe for a
      # single-homeserver deployment; element-call's own reference compose
      # (dev-backend-docker-compose.yml) uses the same wildcard value.
      - LIVEKIT_FULL_ACCESS_HOMESERVERS=*
    ports:
      - "8070:8070"
    restart: unless-stopped
RTCEOF

# ── Open required firewall ports for LiveKit ─────────────────────────────────
read -rp "Open LiveKit firewall ports via ufw (7881/tcp, 7882/udp, 50100-50200/udp)? [y/N] " ans_ufw
if [[ "$ans_ufw" =~ ^[Yy]$ ]]; then
  sudo ufw allow 7881/tcp comment "LiveKit SFU TCP"
  sudo ufw allow 7882/udp comment "LiveKit SFU UDP"
  sudo ufw allow 50100:50200/udp comment "LiveKit RTC UDP range"
fi

# ── Start Element Call backend ──────────────────────────────────────────────────
echo "==> Starting Element Call backend..."
docker compose up -d
echo "==> Containers started."

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
echo
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$rtcdomain"
fi

# ── Nginx reverse proxy ───────────────────────────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$rtcdomain"

  if [[ ! -f "$NGINX_CONF_SRC" ]]; then
    echo "ERROR: nginx config template not found at $NGINX_CONF_SRC"
    exit 1
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|rtc\.example\.com|$rtcdomain|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$rtcdomain"
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
echo "================================================================"
echo " Element Call backend installation complete!"
echo "  RTC backend: https://$rtcdomain"
echo ""
echo "  Make sure Synapse's well-known client JSON (written by"
echo "  matrix-synapse-install.sh) points org.matrix.msc4143.rtc_foci at"
echo "  https://$rtcdomain/livekit/jwt"
echo "================================================================"
