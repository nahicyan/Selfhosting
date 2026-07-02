#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../matrix-authentication-service-nginx.conf"

# Requires Synapse to already be installed (matrix-synapse-install.sh) — MAS
# needs to reach it at host.docker.internal:8008 and share its matrix_secret.
# MAS's stable Synapse-delegation feature requires Synapse 1.136.0 or later.

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter MAS domain (e.g. auth.example.com): " masdomain
[[ -z "$masdomain" ]] && { echo "MAS domain cannot be empty."; exit 1; }

read -rp "Enter Matrix homeserver domain (e.g. matrix.example.com): " domain
[[ -z "$domain" ]] && { echo "Matrix homeserver domain cannot be empty."; exit 1; }

# matrix_secret must match 'matrix_authentication_service.secret' in Synapse's
# homeserver.yaml. matrix-synapse-install.sh drops it here automatically; fall
# back to a manual paste if this script is run standalone / on another host.
SECRET_HANDOFF_FILE="/var/www/docker/MAS/$masdomain/.matrix-secret"
if [[ -f "$SECRET_HANDOFF_FILE" ]]; then
  matrix_secret=$(sudo cat "$SECRET_HANDOFF_FILE")
  echo "==> Found matrix_secret from Synapse install at $SECRET_HANDOFF_FILE"
else
  echo "No matrix_secret handoff file found at $SECRET_HANDOFF_FILE."
  read -rsp "Enter matrix_secret (printed by matrix-synapse-install.sh — must match homeserver.yaml's matrix_authentication_service.secret): " matrix_secret
  echo
  [[ -z "$matrix_secret" ]] && { echo "matrix_secret cannot be empty."; exit 1; }
fi

read -rsp "Enter PostgreSQL password for MAS's docker database: " mas_password
echo
echo

echo "==> MAS domain      : $masdomain"
echo "==> Matrix domain   : $domain"
echo

# ── Set up MAS directory and generate config ────────────────────────────────────
INSTALL_DIR="/var/www/docker/MAS/$masdomain"
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "==> Generating base config.yaml..."
docker run --rm ghcr.io/element-hq/matrix-authentication-service:latest config generate > config.yaml

# ── Patch config.yaml in-place with all required values ────────────────────────
# Using Python instead of awk/sed because awk had two compounding bugs:
#   1. The default { print } rule fired BEFORE in_matrix rules, printing every
#      line as-is first, then the in_matrix rule also fired — producing
#      duplicate lines.
#   2. in_matrix was reset to 0 after the FIRST field match, so secret and
#      endpoint were never replaced (only homeserver was, appearing twice).
# Python reads the whole file and makes all substitutions in one clean pass.
echo "==> Patching config.yaml..."
sudo tee /tmp/patch_mas_config.py > /dev/null << 'PYEOF'
import sys, re

path          = sys.argv[1]
masdomain     = sys.argv[2]
domain        = sys.argv[3]
mas_password  = sys.argv[4]
matrix_secret = sys.argv[5]

txt = open(path).read()

# ── http block: public_base and issuer ───────────────────────────────────────
txt = re.sub(r"(public_base:).*", r"\1 https://" + masdomain, txt)
txt = re.sub(r"(issuer:).*",      r"\1 https://" + masdomain, txt)

# ── database: replace postgresql URI ─────────────────────────────────────────
txt = re.sub(r"(uri: postgresql://)\S+",
             r"\1mas:" + mas_password + "@db:5432/mas", txt)

# ── matrix: block — replace ALL fields, keeping the block intact ─────────────
# Replace every occurrence of these keys under matrix: regardless of order.
# re.sub replaces all matches globally so duplicate homeserver: lines are also
# collapsed to a single correct value.
def replace_matrix_block(t):
    def repl(m):
        block = m.group(0)
        # Remove ALL homeserver: lines (there may be duplicates from the generator)
        block = re.sub(r"^[ \t]+homeserver:.*\n", "", block, flags=re.MULTILINE)
        # Remove secret:, endpoint: lines so we can re-insert them cleanly
        block = re.sub(r"^[ \t]+secret:.*\n",   "", block, flags=re.MULTILINE)
        block = re.sub(r"^[ \t]+endpoint:.*\n", "", block, flags=re.MULTILINE)
        # Insert our values right after "matrix:\n"
        block = block.replace("matrix:\n",
            "matrix:\n"
            "  homeserver: " + domain        + "\n"
            "  secret: "     + matrix_secret + "\n"
            "  endpoint: http://host.docker.internal:8008\n"
        )
        return block
    return re.sub(r"^matrix:\n(?:[ \t]+.*\n)*", repl, t, flags=re.MULTILINE)

txt = replace_matrix_block(txt)

# NOTE: no clients: block is written. The old MSC3861-era setup needed a
# statically-registered "Synapse" OAuth client (id 0000000000000000000SYNAPSE)
# — that's retired. The stable matrix_authentication_service delegation (which
# matrix-synapse-install.sh already uses) authenticates Synapse to MAS purely
# via the shared matrix.secret as a bearer token; no client registration
# exists anywhere in current MAS docs or source. Whatever config generate
# produced for clients: (typically an empty list) is left untouched.

open(path, "w").write(txt)
print("MAS config.yaml patched successfully")
PYEOF
sudo python3 /tmp/patch_mas_config.py config.yaml \
  "$masdomain" "$domain" "$mas_password" "$matrix_secret"

# ── Write MAS docker-compose.yml ────────────────────────────────────────────────
echo "==> Writing docker-compose.yml..."
sudo tee docker-compose.yml > /dev/null << DCEOF
services:
  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_USER=mas
      - POSTGRES_PASSWORD=$mas_password
      - POSTGRES_DB=mas
    volumes:
      - mas_db_data:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      # pg_isready polls until PostgreSQL is actually accepting connections.
      # Without this, MAS starts before the DB is ready and gets "Connection refused".
      test: ["CMD-SHELL", "pg_isready -U mas -d mas"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 10s

  matrix-auth-service:
    image: ghcr.io/element-hq/matrix-authentication-service:latest
    container_name: matrix-auth-service
    extra_hosts:
      # Allows the container to reach Synapse running on the host.
      # Without this, 'localhost' inside the container refers to the container
      # itself, not the host — causing MAS to fail to connect to Synapse.
      - "host.docker.internal:host-gateway"
    environment:
      - MAS_CONFIG=/app/config/config.yaml
    ports:
      - "8086:8080"
      # No mapping for MAS's internal :8081 health listener — it binds to
      # localhost inside the container, so publishing it reaches nothing.
    volumes:
      - ./config.yaml:/app/config/config.yaml:ro
    depends_on:
      db:
        # depends_on alone only waits for the db *container* to start, not for
        # PostgreSQL inside it to finish initialising — MAS would try to connect
        # a few milliseconds later and get "Connection refused". condition:
        # service_healthy holds MAS until the db healthcheck actually passes.
        condition: service_healthy
    restart: unless-stopped

volumes:
  mas_db_data:
DCEOF

read -rp "Would you like to review/edit config.yaml before starting? [y/N] " ans_config
[[ "$ans_config" =~ ^[Yy]$ ]] && sudo "${EDITOR:-vim}" config.yaml

# ── Validate MAS config before starting ─────────────────────────────────────────
echo "==> Validating config.yaml..."
docker run --rm -v "$INSTALL_DIR":/app/config \
  ghcr.io/element-hq/matrix-authentication-service:latest \
  --config /app/config/config.yaml config check

# ── Start MAS ─────────────────────────────────────────────────────────────────
echo "==> Starting MAS..."
docker compose up -d
echo "==> Containers started."

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
echo
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$masdomain"
fi

# ── Nginx reverse proxy ───────────────────────────────────────────────────────
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$masdomain"

  if [[ ! -f "$NGINX_CONF_SRC" ]]; then
    echo "ERROR: nginx config template not found at $NGINX_CONF_SRC"
    exit 1
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|auth\.example\.com|$masdomain|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL"

  read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
  if [[ "$ans_link" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$NGINX_AVAIL" "/etc/nginx/sites-enabled/$masdomain"
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
echo " MAS installation complete!"
echo "  MAS: https://$masdomain"
echo ""
echo "  To create the first user:"
echo "  cd $INSTALL_DIR"
echo "  docker compose exec matrix-auth-service mas-cli manage register-user"
echo ""
echo "  Next: run matrix-element-call-install.sh"
echo "================================================================"
