#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../matrix-synapse-nginx.conf"

# This script only installs Synapse itself. MAS and Element Call are separate:
#   matrix-authentication-service-install.sh
#   matrix-element-call-install.sh
# Run this one first — it generates matrix_secret, which MAS needs.

# ── Add Matrix.org repository and install Synapse + PostgreSQL ─────────────────
echo "==> Adding Matrix.org apt repository..."
sudo apt install -y lsb-release wget apt-transport-https
sudo wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/matrix-org.list

echo "==> Installing matrix-synapse-py3 and PostgreSQL..."
sudo apt update
sudo apt install -y matrix-synapse-py3 postgresql

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter Matrix homeserver domain (e.g. matrix.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

# masdomain/rtcdomain are only used to fill in the well-known client discovery
# JSON below — this script does not install MAS or the RTC backend.
read -rp "Enter MAS domain, for well-known discovery only (e.g. auth.example.com): " masdomain
[[ -z "$masdomain" ]] && { echo "MAS domain cannot be empty."; exit 1; }

read -rp "Enter RTC / Element Call domain, for well-known discovery only (e.g. rtc.example.com): " rtcdomain
[[ -z "$rtcdomain" ]] && { echo "RTC domain cannot be empty."; exit 1; }

# Synapse's default config binds to both ::1 (IPv6 loopback) and 127.0.0.1 (IPv4).
# If your server doesn't use IPv6 or you want IPv4-only, answer N.
read -rp "Enable IPv6 binding for Synapse? (y/N): " want_ipv6

echo
read -rsp "Enter PostgreSQL password for 'matrix' user: " postgres_password
echo
echo

echo "==> Domain     : $domain"
echo "==> MAS domain : $masdomain"
echo "==> RTC domain : $rtcdomain"
echo "==> IPv6       : ${want_ipv6:-N}"
echo

# ── Generate random secrets ─────────────────────────────────────────────────────
# reg_secret    = registration_shared_secret (for admin user registration via API)
# matrix_secret = shared secret between Synapse and MAS (matrix_authentication_service.secret).
#                 MUST match 'matrix.secret' in MAS's config.yaml — this script
#                 prints it at the end and also drops it in a handoff file that
#                 matrix-authentication-service-install.sh looks for automatically.
reg_secret=$(openssl rand -base64 48)
matrix_secret=$(openssl rand -base64 48)

# ── Configure Synapse bind address ──────────────────────────────────────────────
# WHY PYTHON INSTEAD OF SED:
#   The current Synapse Debian package generates bind_addresses in YAML block
#   style (each address on its own "- " line), NOT the old inline flow style.
#   sed cannot reliably match a multiline block, and even for the old format
#   sed's BRE treats "[" as a special character and silently fails to match.
#   Python handles the block style with a single robust multiline regex.
#
#   Block style (current Synapse Debian package):
#     bind_addresses:
#     - ::1
#     - 127.0.0.1
echo "==> Configuring bind_addresses in homeserver.yaml..."
if [[ "${want_ipv6,,}" == "y" ]]; then
  sudo tee /tmp/set_bind_ipv6.py > /dev/null << 'PYEOF'
import re
path = '/etc/matrix-synapse/homeserver.yaml'
txt  = open(path).read()
def repl(m):
    existing = m.group(2)
    first    = existing.split('\n')[0]
    indent   = first[:len(first) - len(first.lstrip())]
    return m.group(1) + indent + '- ::1\n' + indent + '- 127.0.0.1\n'
txt = re.sub(r'(bind_addresses:\n)((?:[ \t]*-[ \t]+\S+\n)+)', repl, txt)
open(path,'w').write(txt)
print('bind_addresses => IPv4 + IPv6 loopback (::1 and 127.0.0.1)')
PYEOF
  sudo python3 /tmp/set_bind_ipv6.py
else
  sudo tee /tmp/set_bind_ipv4.py > /dev/null << 'PYEOF'
import re
path = '/etc/matrix-synapse/homeserver.yaml'
txt  = open(path).read()
# Capture bind_addresses: header + all existing address lines separately.
# Derive the correct indent from the existing entries so we never hardcode it.
def repl(m):
    existing = m.group(2)
    first    = existing.split('\n')[0]
    indent   = first[:len(first) - len(first.lstrip())]
    return m.group(1) + indent + '- 127.0.0.1\n'
txt = re.sub(r'(bind_addresses:\n)((?:[ \t]*-[ \t]+\S+\n)+)', repl, txt)
open(path,'w').write(txt)
print('bind_addresses => IPv4 loopback only (127.0.0.1)')
PYEOF
  sudo python3 /tmp/set_bind_ipv4.py
fi

# ── Append custom config to homeserver.yaml ─────────────────────────────────────
# The Debian matrix-synapse package already comments out the SQLite database
# block, so no sed is needed there — our postgres block below takes precedence.
# postgres_password is single-quoted below: an unquoted YAML scalar breaks if the
# password contains ': ' (creates a mapping) or '#' (starts a comment).
echo "==> Appending custom config to homeserver.yaml..."
sudo tee -a /etc/matrix-synapse/homeserver.yaml > /dev/null << SYNEOF

#Custom-Config-Upload#
max_upload_size: 131072M
#Custom-Config-Registration#
#enable_registration: true
registration_shared_secret: $reg_secret
#Custom-Config-Postgres#
database:
  name: psycopg2
  args:
    user: matrix
    password: '$postgres_password'
    dbname: synapse
    host: localhost
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3
#Coturn-Turnserver-Config# (uncomment to enable coturn)
#turn_uris: [ "turns:$rtcdomain?transport=udp", "turns:$rtcdomain?transport=tcp" ]
#turn_shared_secret: changeme
#turn_user_lifetime: 86400000
#turn_allow_guests: True
#Server-Name#
server_name: $domain
#Custom-Config-End#

# === MAS Delegation (replaces legacy experimental_features.msc3861) ===
matrix_authentication_service:
  enabled: true
  # Internal URL to MAS (avoids external round-trip)
  endpoint: http://localhost:8086/
  # Must match 'matrix.secret' in MAS config.yaml
  secret: $matrix_secret

# === MatrixRTC / Element Call experimental features ===
# Per element-call/docs/self_hosting.md's Prerequisites section, Element Call
# only requires msc3266_enabled + msc4222_enabled (plus max_event_delay_duration
# and the rate limits below). msc4140_enabled, sliding_sync, msc4190_enabled and
# msc3202_device_masquerading were dropped here: none of them are real config
# keys in current Synapse (verified against synapse/config/experimental.py) —
# MSC4140 delayed events are gated purely by max_event_delay_duration being
# set, MSC3575 (sliding sync) now defaults to enabled with no flag needed, and
# MSC4190/MSC3202 device masquerading both became unconditional default
# behaviour. Setting them was a harmless no-op, but no reason to keep dead keys.
experimental_features:
  # MSC3266: Room summary API - needed for knocking over federation. Synapse
  # has since stabilized this (the flag is now a no-op there), but
  # element-call's docs still list it as required, so it stays for clarity.
  msc3266_enabled: true
  # MSC4222: syncv2 state_after - lets clients track room state correctly
  msc4222_enabled: true
  # MSC4108: QR-code login rendezvous (not required by Element Call, kept for
  # QR sign-in support in modern Matrix clients — still a real, current flag)
  msc4108_enabled: true

# Maximum delay for MSC4140 delayed events (call signalling)
max_event_delay_duration: 24h

# Rate control - must accommodate E2EE key-sharing bursts
rc_message:
  per_second: 0.5
  burst_count: 30

# Rate control - must accommodate heartbeat frequency (~0.2/s)
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
SYNEOF

# ── PostgreSQL: create Synapse user and database ────────────────────────────────
# IMPORTANT: Synapse requires LC_COLLATE='C' and LC_CTYPE='C'.
# Without this Synapse refuses to start with an "incorrect collation" error.
# Must use template0 (not template1) to allow overriding the default collation.
echo "==> Creating PostgreSQL user and database..."
sudo systemctl start postgresql
sudo -u postgres psql -c "CREATE USER matrix WITH ENCRYPTED PASSWORD '${postgres_password}';"
sudo -u postgres psql -c "CREATE DATABASE synapse ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0 OWNER matrix;"

# ── Save matrix_secret handoff file for the MAS install script ─────────────────
SECRET_HANDOFF_DIR="/var/www/docker/MAS/$masdomain"
sudo mkdir -p "$SECRET_HANDOFF_DIR"
echo "$matrix_secret" | sudo tee "$SECRET_HANDOFF_DIR/.matrix-secret" > /dev/null
sudo chmod 600 "$SECRET_HANDOFF_DIR/.matrix-secret"

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
    -e "s|matrix\.example\.com|$domain|g" \
    -e "s|auth\.example\.com|$masdomain|g" \
    -e "s|rtc\.example\.com|$rtcdomain|g" \
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

# ── Restart Synapse to pick up new homeserver.yaml ──────────────────────────────
echo "==> Restarting matrix-synapse..."
sudo systemctl restart matrix-synapse

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " Synapse installation complete!"
echo "  Homeserver: https://$domain"
echo ""
echo "  IMPORTANT — save this value, MAS setup needs it:"
echo "  matrix_secret = $matrix_secret"
echo ""
echo "  It has also been saved to (auto-detected by the MAS install script):"
echo "  $SECRET_HANDOFF_DIR/.matrix-secret"
echo ""
echo "  Next: run matrix-authentication-service-install.sh"
echo "        then matrix-element-call-install.sh"
echo "================================================================"
