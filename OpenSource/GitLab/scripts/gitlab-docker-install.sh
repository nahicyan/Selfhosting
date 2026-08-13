#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../gitlab-nginx.conf"

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. gitlab.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

read -rp "Enter host port to bind GitLab's web UI to (proxied via Nginx) [8929]: " http_port
http_port="${http_port:-8929}"
[[ "$http_port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }

echo
echo "GitLab needs a host port for Git-over-SSH. If this host's own SSH daemon"
echo "already uses port 22 (the usual case), pick a different port here, e.g. 2222."
read -rp "Enter host port for Git-over-SSH [2222]: " ssh_port
ssh_port="${ssh_port:-2222}"
[[ "$ssh_port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }

read -rp "Use GitLab Enterprise Edition (EE) instead of Community Edition (CE)? [y/N] " ans_ee
if [[ "$ans_ee" =~ ^[Yy]$ ]]; then
  edition="ee"
else
  edition="ce"
fi

read -rp "Enter image tag to install (e.g. 17.5.2-${edition}.0) [latest]: " version
version="${version:-latest}"

echo
echo "==> Domain    : $domain"
echo "==> HTTP port : 127.0.0.1:$http_port (proxied by Nginx)"
echo "==> SSH port  : $ssh_port"
echo "==> Image     : gitlab/gitlab-${edition}:${version}"
echo

# ── Create install directory & volumes ────────────────────────────────────────
INSTALL_DIR="/var/www/docker/gitlab/$domain"

sudo mkdir -p "$INSTALL_DIR"/{config,logs,data}
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Write docker-compose.yml ──────────────────────────────────────────────────
# nginx['listen_https'] is disabled because the host Nginx (set up below)
# terminates TLS and proxies to GitLab's internal Nginx over plain HTTP.
cat > docker-compose.yml <<EOF
services:
  gitlab:
    image: gitlab/gitlab-${edition}:${version}
    restart: always
    hostname: '${domain}'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${domain}'
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        gitlab_rails['gitlab_shell_ssh_port'] = ${ssh_port}
        # Add any other gitlab.rb configuration here, each on its own line
    ports:
      - '127.0.0.1:${http_port}:80'
      - '${ssh_port}:22'
    volumes:
      - './config:/etc/gitlab'
      - './logs:/var/log/gitlab'
      - './data:/var/opt/gitlab'
    shm_size: '256m'
EOF

echo "==> docker-compose.yml written to $INSTALL_DIR"

# ── Review compose file ────────────────────────────────────────────────────────
read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
if [[ "$ans_compose" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" docker-compose.yml
fi

# ── Start containers ──────────────────────────────────────────────────────────
echo "==> Pulling GitLab image (this may take a while)..."
docker compose pull
echo "==> Starting GitLab..."
docker compose up -d
echo "==> Container started. GitLab reconfigures itself on first boot — this can take several minutes."

read -rp "Would you like to tail the logs until GitLab finishes starting? [y/N] " ans_logs
if [[ "$ans_logs" =~ ^[Yy]$ ]]; then
  echo "==> Press Ctrl+C once you see GitLab come up (or when 'gitlab-ctl reconfigure' finishes)."
  docker compose logs -f gitlab || true
fi

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
    -e "s|gitlab\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:8929|127.0.0.1:$http_port|g" \
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

# ── Firewall ───────────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  read -rp "Would you like to open the SSH port ($ssh_port/tcp) in ufw? [y/N] " ans_ufw
  if [[ "$ans_ufw" =~ ^[Yy]$ ]]; then
    sudo ufw allow "$ssh_port"/tcp comment 'GitLab Git-over-SSH'
    sudo ufw reload
  fi
fi

# ── Initial root password ─────────────────────────────────────────────────────
read -rp "Would you like to fetch the initial root password now? [y/N] " ans_pw
if [[ "$ans_pw" =~ ^[Yy]$ ]]; then
  if docker compose exec gitlab test -f /etc/gitlab/initial_root_password; then
    docker compose exec gitlab grep 'Password:' /etc/gitlab/initial_root_password
  else
    echo "==> Not available yet — GitLab may still be reconfiguring. Try again shortly with:"
    echo "    docker compose exec gitlab grep 'Password:' /etc/gitlab/initial_root_password"
  fi
fi

echo
echo "==> GitLab installation complete."
echo "    URL      : https://$domain"
echo "    Login    : root / (see initial_root_password above — file is removed 24h after first start)"
if [[ "$ssh_port" != "22" ]]; then
  echo "    Git SSH  : ssh://git@$domain:$ssh_port/<namespace>/<project>.git"
fi
echo
echo "    Install dir: $INSTALL_DIR"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo "    Config  : docker compose exec gitlab editor /etc/gitlab/gitlab.rb  (then: docker compose restart)"
echo
