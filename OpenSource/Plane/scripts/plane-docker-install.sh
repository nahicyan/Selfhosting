#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../plane-nginx.conf"
GH_REPO="makeplane/plane"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl docker openssl sed; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' is required but not installed."; exit 1; }
done

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. plane.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

read -rp "Enter HTTP port for Plane's internal proxy (e.g. 8080): " port
[[ -z "$port" ]] && { echo "Port cannot be empty."; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }
https_port=$((port + 1))

echo
echo "==> Domain : $domain"
echo "==> Port   : $port (internal HTTPS placeholder: $https_port, unused — TLS is terminated by Nginx)"
echo

# ── Resolve latest release ────────────────────────────────────────────────────
echo "==> Checking latest Plane release..."
release_tag="$(curl -fsSL "https://api.github.com/repos/$GH_REPO/releases/latest" \
  | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
[[ -z "$release_tag" ]] && { echo "ERROR: could not determine the latest Plane release."; exit 1; }
echo "==> Latest release: $release_tag"
echo

# ── Prepare install directory ─────────────────────────────────────────────────
INSTALL_DIR="/var/www/docker/plane/$domain"
if [[ -f "$INSTALL_DIR/docker-compose.yaml" ]]; then
  echo "ERROR: Plane already appears to be installed at $INSTALL_DIR (docker-compose.yaml exists)."
  echo "       Remove it first if you want to reinstall, or choose a different domain."
  exit 1
fi
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

PROJECT_NAME="plane-${domain//./-}"
COMPOSE_CMD="docker compose -f docker-compose.yaml --env-file=plane.env --project-name $PROJECT_NAME"

# ── Download release assets ───────────────────────────────────────────────────
echo "==> Downloading Plane $release_tag docker-compose.yaml and plane.env..."
curl -fsSL -o docker-compose.yaml "https://github.com/$GH_REPO/releases/download/$release_tag/docker-compose.yml"
curl -fsSL -o plane.env          "https://github.com/$GH_REPO/releases/download/$release_tag/variables.env"

# ── Generate secrets ──────────────────────────────────────────────────────────
# The downloaded plane.env ships with well-known defaults (SECRET_KEY=change-this-key-on-deployment,
# POSTGRES_PASSWORD=plane, AWS_ACCESS_KEY_ID=access-key, ...) — never run those in production.
echo "==> Generating secrets..."
secret_key="$(openssl rand -hex 32)"
live_secret_key="$(openssl rand -hex 32)"
postgres_password="$(openssl rand -hex 16)"
rabbitmq_password="$(openssl rand -hex 16)"
minio_access_key="$(openssl rand -hex 12)"
minio_secret_key="$(openssl rand -hex 24)"

# ── Configure plane.env ───────────────────────────────────────────────────────
echo "==> Writing plane.env..."
sed -i \
  -e "s|^APP_DOMAIN=.*|APP_DOMAIN=$domain|" \
  -e "s|^APP_RELEASE=.*|APP_RELEASE=$release_tag|" \
  -e "s|^LISTEN_HTTP_PORT=.*|LISTEN_HTTP_PORT=$port|" \
  -e "s|^LISTEN_HTTPS_PORT=.*|LISTEN_HTTPS_PORT=$https_port|" \
  -e "s|^WEB_URL=.*|WEB_URL=https://$domain|" \
  -e "s|^CORS_ALLOWED_ORIGINS=.*|CORS_ALLOWED_ORIGINS=https://$domain|" \
  -e "s|^SITE_ADDRESS=.*|SITE_ADDRESS=:80|" \
  -e "s|^SECRET_KEY=.*|SECRET_KEY=$secret_key|" \
  -e "s|^LIVE_SERVER_SECRET_KEY=.*|LIVE_SERVER_SECRET_KEY=$live_secret_key|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$postgres_password|" \
  -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://plane:${postgres_password}@plane-db/plane|" \
  -e "s|^RABBITMQ_PASSWORD=.*|RABBITMQ_PASSWORD=$rabbitmq_password|" \
  -e "s|^AMQP_URL=.*|AMQP_URL=amqp://plane:${rabbitmq_password}@plane-mq:5672/plane|" \
  -e "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=$minio_access_key|" \
  -e "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$minio_secret_key|" \
  plane.env
# SITE_ADDRESS is the key that matters for external reverse proxies (see
# .temp/reverse-proxy.txt) — it stops Plane's built-in Caddy proxy from
# attempting its own TLS/ACME handling, since Nginx terminates TLS instead.

# ── Bind the internal proxy to localhost only ─────────────────────────────────
# The official compose file publishes the proxy's ports with `mode: host`,
# which binds 0.0.0.0 by default. Nginx is the only intended public entrypoint,
# so pin both published ports to loopback.
echo "==> Binding Plane's internal proxy to 127.0.0.1..."
sed -i '/mode: host/a\        host_ip: 127.0.0.1' docker-compose.yaml

# ── Review ─────────────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit plane.env before starting? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" plane.env

read -rp "Would you like to review/edit docker-compose.yaml before starting? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" docker-compose.yaml

# ── Start containers ──────────────────────────────────────────────────────────
echo "==> Pulling Docker images (this may take a while)..."
$COMPOSE_CMD pull

echo "==> Starting Plane containers..."
$COMPOSE_CMD up -d
echo "==> Containers started."

# ── Wait for database migrations ──────────────────────────────────────────────
migrator_id="$(docker ps -aq -f "name=${PROJECT_NAME}-migrator")"
if [[ -n "$migrator_id" ]]; then
  echo -n "==> Waiting for database migrations to finish"
  while docker inspect --format='{{.State.Status}}' "$migrator_id" 2>/dev/null | grep -q running; do
    echo -n "."
    sleep 2
  done
  echo
  migrator_exit_code="$(docker inspect --format='{{.State.ExitCode}}' "$migrator_id")"
  if [[ "$migrator_exit_code" != "0" ]]; then
    echo "ERROR: Migrations failed (exit code $migrator_exit_code)."
    echo "       Check logs: $COMPOSE_CMD logs migrator"
    exit 1
  fi
  echo "==> Migrations completed successfully."
else
  echo "WARNING: Could not find the migrator container — skipping migration check."
fi

# ── Let's Encrypt ──────────────────────────────────────────────────────────────
echo
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
fi

# ── Nginx reverse proxy ────────────────────────────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$domain"

  if [[ ! -f "$NGINX_CONF_SRC" ]]; then
    echo "ERROR: nginx config template not found at $NGINX_CONF_SRC"
    exit 1
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|plane\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:8080|127.0.0.1:$port|g" \
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

# ── Done ───────────────────────────────────────────────────────────────────────
echo
echo "==> Plane installation complete."
echo "    URL: https://$domain"
echo
echo "    Install dir : $INSTALL_DIR"
echo "    Secrets     : $INSTALL_DIR/plane.env (randomly generated — back this up securely)"
echo
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : $COMPOSE_CMD up -d"
echo "    Stop    : $COMPOSE_CMD down"
echo "    Restart : $COMPOSE_CMD restart"
echo "    Logs    : $COMPOSE_CMD logs -f"
