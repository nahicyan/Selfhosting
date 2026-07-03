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
# WHY 0.0.0.0 AND NOT 127.0.0.1:
#   MAS runs in a Docker container and reaches Synapse via host.docker.internal,
#   which resolves to the Docker bridge gateway IP (e.g. 172.18.0.1) — NOT
#   127.0.0.1. A loopback-only bind means Synapse never sees that connection at
#   all (no listening socket on the bridge-facing interface), which surfaces as
#   "Connection refused" from inside the MAS container even though Synapse
#   itself is perfectly healthy. Synapse's own reverse_proxy.md warns about
#   exactly this: "Do not change bind_addresses to 127.0.0.1 when using a
#   containerized Synapse, as that will prevent it from responding to proxied
#   traffic." Since this now listens on all interfaces, it's locked back down
#   with a ufw rule below — nginx (loopback) and MAS (Docker bridge range) are
#   the only intended callers.
#
# WHY THE ADDRESSES ARE QUOTED ('0.0.0.0' / '::') AND NOT BARE:
#   A bare, unquoted "::" is a YAML edge case — a plain scalar consisting of
#   nothing but colons gets misparsed as a mapping (observed in production as
#   bind_addresses becoming [{':': None}, '0.0.0.0'], which crashes Synapse's
#   listener startup with ListenerException). The original default "::1"
#   never hit this because the trailing "1" makes it unambiguous; the bare
#   wildcard address "::" does not. Quoting is always valid for the IPv4
#   address too, so both are quoted uniformly rather than special-casing IPv6.
#
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
#
# WHY THE "CHANGED"/"UNCHANGED" CHECK BELOW:
#   A regex that matches zero times still exits 0 — a silent no-op that looks
#   identical to success in the script's own output, and was previously
#   mistaken for success for several debugging round-trips. The patch itself
#   now reports whether it actually changed anything, and the script aborts
#   immediately if it didn't. This check only proves the substitution *ran* —
#   it does NOT prove the result is valid YAML (that's what the separate
#   validation step further down is for, after both patches to this file).
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
    return m.group(1) + indent + "- '::'\n" + indent + "- '0.0.0.0'\n"
new_txt = re.sub(r'(bind_addresses:\n)((?:[ \t]*-[ \t]+\S+\n)+)', repl, txt)
if new_txt == txt:
    print('UNCHANGED')
else:
    open(path, 'w').write(new_txt)
    print('CHANGED')
PYEOF
  bind_result=$(sudo python3 /tmp/set_bind_ipv6.py)
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
    return m.group(1) + indent + "- '0.0.0.0'\n"
new_txt = re.sub(r'(bind_addresses:\n)((?:[ \t]*-[ \t]+\S+\n)+)', repl, txt)
if new_txt == txt:
    print('UNCHANGED')
else:
    open(path, 'w').write(new_txt)
    print('CHANGED')
PYEOF
  bind_result=$(sudo python3 /tmp/set_bind_ipv4.py)
fi

if [[ "$bind_result" != "CHANGED" ]]; then
  echo "ERROR: bind_addresses substitution matched nothing in homeserver.yaml —"
  echo "       Synapse's listeners block doesn't have the expected shape (or"
  echo "       this install already had a non-default one). Refusing to"
  echo "       continue with a config that's still loopback-only, since MAS"
  echo "       would silently fail to reach Synapse later. Inspect"
  echo "       /etc/matrix-synapse/homeserver.yaml's listeners[].bind_addresses"
  echo "       manually."
  exit 1
fi
echo "==> bind_addresses now listens on all interfaces (0.0.0.0$([[ "${want_ipv6,,}" == "y" ]] && echo " + ::"))."

# ── Firewall: port 8008 must not be reachable from the public internet ─────────
# It's now bound to 0.0.0.0 so MAS (in Docker) can reach it, but it's plain
# HTTP with no auth of its own — nginx (loopback) and MAS (Docker bridge) are
# the only callers that should ever reach it directly.
read -rp "Restrict port 8008 to localhost + Docker's bridge range via ufw? Recommended. [Y/n] " ans_fw8008
ans_fw8008="${ans_fw8008:-Y}"
if [[ "$ans_fw8008" =~ ^[Yy]$ ]]; then
  sudo ufw allow from 127.0.0.1 to any port 8008 proto tcp comment "Synapse client API - nginx (localhost)"
  sudo ufw allow from 172.16.0.0/12 to any port 8008 proto tcp comment "Synapse client API - Docker bridge (MAS)"
  sudo ufw deny 8008/tcp comment "Synapse client API - block public internet"
  echo "==> ufw: port 8008 restricted to localhost + 172.16.0.0/12 (Docker's default bridge range)."
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

# ── Validate homeserver.yaml before doing anything else with it ────────────────
# Confirms the file is actually valid YAML before we invest in postgres/nginx
# setup and finally restart the service on it. This is the check that would
# have caught the '::' bug above immediately with a clear message, instead of
# writing broken syntax that only surfaced as a cryptic ListenerException from
# journalctl after everything else had already run. Uses Synapse's own venv
# python — guaranteed to have PyYAML, since Synapse needs it to parse this
# same file — rather than assuming the system python3 has it installed.
echo "==> Validating homeserver.yaml..."
if ! sudo /opt/venvs/matrix-synapse/bin/python -c "import yaml; yaml.safe_load(open('/etc/matrix-synapse/homeserver.yaml'))" 2>/tmp/synapse_yaml_check_err; then
  echo "ERROR: /etc/matrix-synapse/homeserver.yaml is not valid YAML:"
  cat /tmp/synapse_yaml_check_err
  exit 1
fi
echo "==> homeserver.yaml parses cleanly."

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
