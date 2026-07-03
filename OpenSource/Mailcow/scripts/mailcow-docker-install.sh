#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../mailcow-docker-nginx.conf"

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter domain name (no subdomain, e.g. example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }
fqdn="mail.$domain"

default_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"
read -rp "Enter timezone [$default_tz]: " timezone
timezone="${timezone:-$default_tz}"

read -rp "Temporarily disable IPv6 on this host until next reboot? [y/N] " ans_ipv6

echo
echo "==> Domain    : $domain"
echo "==> Mail host : $fqdn"
echo "==> Timezone  : $timezone"
echo

# ── IPv6 ──────────────────────────────────────────────────────────────────────
# Receiving mail servers often penalize mail from hosts advertising IPv6
# addresses with no matching AAAA/PTR record. This only disables IPv6 at
# runtime (reverts on reboot) — see the AAAA-record warning at the end.
if [[ "$ans_ipv6" =~ ^[Yy]$ ]]; then
  echo "==> Disabling IPv6 (runtime only — reverts on reboot)..."
  sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
  sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
  sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1
  echo "==> Verifying (0 = enabled, 1 = disabled):"
  sysctl net.ipv6.conf.all.disable_ipv6
  ip -6 addr show
  echo
fi

# ── Remove Exim4 (if present) ─────────────────────────────────────────────────
# Debian/Ubuntu often ship Exim4 bound to port 25, which conflicts with
# mailcow's own Postfix container. Not every host has it installed — guard on
# actual presence so an absent package doesn't abort the rest of the script.
echo "==> Checking for Exim4..."
if dpkg -l 'exim4*' 2>/dev/null | grep -q '^ii'; then
  echo "    Exim4 found — removing..."
  sudo systemctl disable --now exim4 || true
  sudo apt-get purge -y 'exim4*'
  sudo apt-get autoremove -y
  echo "    Exim4 removed."
else
  echo "    Exim4 not installed — skipping removal."
fi
echo

# ── Base packages ─────────────────────────────────────────────────────────────
echo "==> Updating packages..."
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y git vim ufw jq fail2ban

# ── Hostname & hosts file ─────────────────────────────────────────────────────
echo "==> Setting hostname..."
# mailcow expects the OS hostname to be the short "mail" label; the FQDN is
# supplied separately via MAILCOW_HOSTNAME below and resolved through /etc/hosts.
echo "mail" | sudo tee /etc/hostname > /dev/null
sudo hostnamectl set-hostname mail

echo "==> Detecting public IP..."
ip="$(curl -fs https://api.ipify.org)"
[[ -z "$ip" ]] && { echo "ERROR: Could not determine public IP."; exit 1; }
echo "    Public IP: $ip"

echo "==> Updating /etc/hosts..."
hosts_line1="127.0.0.1 $fqdn mail localhost localhost.localdomain"
hosts_line2="$ip $fqdn mail"
grep -qxF "$hosts_line1" /etc/hosts || echo "$hosts_line1" | sudo tee -a /etc/hosts > /dev/null
grep -qxF "$hosts_line2" /etc/hosts || echo "$hosts_line2" | sudo tee -a /etc/hosts > /dev/null

# ── Firewall ───────────────────────────────────────────────────────────────────
echo "==> Configuring UFW..."
sudo ufw allow proto tcp from any to any port 25,465,587,143,993,110,995,4190,80,443 comment 'Mail and Web Services'
sudo ufw reload
sudo systemctl restart ufw

# ── Clone mailcow ─────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/mailcow/$domain"
sudo mkdir -p "$INSTALL_DIR"

if [[ -d "$INSTALL_DIR/mailcow-dockerized/.git" ]]; then
  echo "==> mailcow-dockerized already cloned at $INSTALL_DIR, skipping clone."
else
  echo "==> Cloning mailcow-dockerized..."
  sudo git clone https://github.com/mailcow/mailcow-dockerized "$INSTALL_DIR/mailcow-dockerized"
fi
cd "$INSTALL_DIR/mailcow-dockerized"

# ── Generate mailcow config ───────────────────────────────────────────────────
echo "==> Generating mailcow configuration..."
# MAILCOW_HOSTNAME/MAILCOW_TZ skip generate_config.sh's interactive prompts.
sudo MAILCOW_HOSTNAME="$fqdn" MAILCOW_TZ="$timezone" ./generate_config.sh

# Bind mailcow's built-in nginx to localhost only — the host Nginx reverse
# proxy (set up below) needs ports 80/443 free to terminate TLS itself.
echo "==> Binding mailcow to 127.0.0.1:8080/8443 for the reverse proxy..."
sudo sed -i \
  -e "s|^HTTP_BIND=.*|HTTP_BIND=127.0.0.1|" \
  -e "s|^HTTP_PORT=.*|HTTP_PORT=8080|" \
  -e "s|^HTTPS_BIND=.*|HTTPS_BIND=127.0.0.1|" \
  -e "s|^HTTPS_PORT=.*|HTTPS_PORT=8443|" \
  -e "s|^HTTP_REDIRECT=.*|HTTP_REDIRECT=n|" \
  mailcow.conf

# ── Review config ──────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit mailcow.conf? [y/N] " ans_conf
if [[ "$ans_conf" =~ ^[Yy]$ ]]; then
  sudo "${EDITOR:-vim}" mailcow.conf
fi

read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
if [[ "$ans_compose" =~ ^[Yy]$ ]]; then
  # See "CONSIDER DISABLING IPv6 FROM DOCKER" in Mailcow.md if this host has no IPv6.
  sudo "${EDITOR:-vim}" docker-compose.yml
fi

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$fqdn"
fi

# ── Nginx reverse proxy ────────────────────────────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$fqdn"

  if [[ ! -f "$NGINX_CONF_SRC" ]]; then
    echo "ERROR: nginx config template not found at $NGINX_CONF_SRC"
    exit 1
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i "s|mail\.example\.com|$fqdn|g" "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$fqdn"
    echo "==> Symlink created."
  fi

  echo "==> Testing Nginx configuration..."
  sudo nginx -t
  echo "==> Reloading Nginx..."
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

# ── Start containers ──────────────────────────────────────────────────────────
echo "==> Pulling Docker images (this may take a while)..."
docker compose pull
echo "==> Starting mailcow containers..."
docker compose up -d
echo "==> Containers started."

# ── Done ───────────────────────────────────────────────────────────────────────
echo
echo "==> Mailcow installation complete."
echo "    URL: https://$fqdn"
echo
echo "    Install dir: $INSTALL_DIR/mailcow-dockerized"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo
echo "    NOTE: Make sure no IPv6 AAAA records exist for $fqdn on your registrar/DNS."
echo "    NOTE: Consider setting enable_ipv6: false under mailcow-network in docker-compose.yml if this host has no IPv6."
echo

read -rp "Would you like to reboot now? (y/n): " reboot_choice
[[ "$reboot_choice" == [Yy] ]] && sudo systemctl reboot
