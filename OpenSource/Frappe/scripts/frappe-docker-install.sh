#!/bin/bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# UPSTREAM BUG WORKAROUND — frappe/lms#2350, frappe/lms#2467
#
# Since ~May 2026, ghcr.io/frappe/lms:stable ships with only the base frappe
# framework inside — the lms app and its required payments dependency are NOT
# bundled. Root cause: frappe_docker commit ae275df changed the CI/CD pipeline
# from APPS_JSON_BASE64 build args to BuildKit secrets. The Containerfile now
# uses --mount=type=secret,id=apps_json instead of ARG APPS_JSON_BASE64. The
# secret was never wired up correctly in CI, so images were published as empty
# benches with only frappe installed.
#
# As a result, this script builds a custom image from source using
# frappe_docker's images/custom/Containerfile, passing apps.json as a BuildKit
# secret (--secret id=apps_json,src=...). The image includes:
#   - frappe (branch: version-16)
#   - payments (branch: develop — payments has no "main" branch)
#   - lms (branch: main)
#
# To verify whether the upstream bug has been fixed, run:
#   docker run --rm ghcr.io/frappe/lms:stable bash -c "ls /home/frappe/frappe-bench/apps/"
# If the output includes "lms" and "payments", the bug is resolved.
#
# HOW TO REVERT this workaround once the bug is fixed:
#   1. Delete the "Clone frappe_docker" section below.
#   2. Delete the "Build custom image" section below (APPS_JSON_FILE, _build_image,
#      the verify+rebuild block, and the IMAGE_NAME/IMAGE_TAG variables at the top).
#   3. In the "Deploy Frappe LMS" section, replace:
#        --image="$IMAGE_NAME" --version="$IMAGE_TAG"
#      with:
#        --image=ghcr.io/frappe/lms --version=stable
#   4. In frappe-docker-mod.sh Step 4, revert the Dockerfile FROM line to:
#        FROM ghcr.io/frappe/lms:stable
#      and revert the Step 7 sed target to: ghcr\.io/frappe/lms:stable
#   5. In Frappe-LMS.md Step 4, revert the same FROM and sed changes.
#   6. In frappe-docker-restore.sh Step 6, remove --skip-failing from migrate
#      (only needed because main branch patches.txt references deleted files).
# ══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../frappe-lms-nginx.conf"
IMAGE_NAME="frappe-lms-custom"
IMAGE_TAG="stable"

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. lms.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

read -rp "Enter site name (e.g. training.example.com) [$domain]: " sitename
sitename="${sitename:-$domain}"

read -rp "Enter admin email: " email
[[ -z "$email" ]] && { echo "Email cannot be empty."; exit 1; }

read -rp "Enter HTTP port for Frappe (e.g. 8080): " port
[[ -z "$port" ]] && { echo "Port cannot be empty."; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }

echo
echo "==> Domain   : $domain"
echo "==> Sitename : $sitename"
echo "==> Email    : $email"
echo "==> Port     : $port"
echo

# ── Prepare folder ────────────────────────────────────────────────────────────
BASE="/var/www/docker/frappe-lms/$domain"
sudo mkdir -p "$BASE"

# ── Clone frappe_docker ───────────────────────────────────────────────────────
# easy-install.py also needs this directory; cloning it here means it won't
# re-download it and we can use the same copy for the image build.
echo "==> Cloning frappe_docker..."
if [[ ! -d "$BASE/frappe_docker" ]]; then
  git clone --depth 1 https://github.com/frappe/frappe_docker.git "$BASE/frappe_docker"
  echo "==> Cloned to $BASE/frappe_docker"
else
  echo "    frappe_docker already present, skipping clone."
fi

# ── Build custom image ────────────────────────────────────────────────────────
# The official ghcr.io/frappe/lms:stable image does not include the lms app
# (frappe/lms#2350). We build our own image that includes both lms and the
# required payments dependency using frappe_docker's Containerfile.
#
# NOTE: The current frappe_docker Containerfile passes apps.json via a BuildKit
# secret (--mount=type=secret,id=apps_json), NOT via the old ARG APPS_JSON_BASE64
# build arg. We write apps.json to a file and pass it with --secret.
# BuildKit secrets do NOT participate in layer cache invalidation, so a previous
# build that ran without the secret (or with the wrong content) may have cached a
# layer with no apps. We verify lms is present after the build and force a clean
# rebuild with --no-cache if it isn't.
echo
echo "==> Building custom image ${IMAGE_NAME}:${IMAGE_TAG}"
echo "    This clones frappe, payments, and lms from source — expect 20-40 minutes."
echo

APPS_JSON_FILE="$BASE/apps.json"
# payments uses "develop" as its default/active branch (no "main" branch exists).
# lms uses "main".
printf '[
  {"url": "https://github.com/frappe/payments.git", "branch": "develop"},
  {"url": "https://github.com/frappe/lms.git", "branch": "main"}
]' > "$APPS_JSON_FILE"

_build_image() {
  docker buildx build \
    --build-arg=FRAPPE_BRANCH=version-16 \
    --secret "id=apps_json,src=$APPS_JSON_FILE" \
    "$@" \
    --tag="${IMAGE_NAME}:${IMAGE_TAG}" \
    --file="$BASE/frappe_docker/images/custom/Containerfile" \
    "$BASE/frappe_docker"
}

_build_image

# Verify lms is in the image. A stale cached layer can silently omit it.
if ! docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" \
    bash -c "ls /home/frappe/frappe-bench/apps/" 2>/dev/null | grep -q "^lms$"; then
  echo "    WARNING: lms not found in image — stale cache detected, rebuilding without cache..."
  _build_image --no-cache
fi

echo "==> Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
echo

# ── Download easy-install.py ──────────────────────────────────────────────────
echo "==> Downloading easy-install.py..."
wget -q -O "$BASE/easy-install.py" https://frappe.io/easy-install.py

# ── Deploy Frappe LMS ─────────────────────────────────────────────────────────
echo "==> Deploying Frappe LMS (creating containers and site)..."
cd "$BASE"
HOME="$BASE" python3 "$BASE/easy-install.py" deploy \
  --project=learning_prod_setup \
  --email="$email" \
  --image="$IMAGE_NAME" \
  --version="$IMAGE_TAG" \
  --app=lms \
  --sitename "$sitename" \
  --no-ssl \
  --http-port "$port"

echo
echo "==> Frappe LMS deployed."

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

  if [[ ! -f "$NGINX_CONF_SRC" ]]; then
    echo "ERROR: nginx config template not found at $NGINX_CONF_SRC"
    exit 1
  fi

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|lms\.example\.com|$domain|g" \
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

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "==> Frappe LMS installation complete."
echo "    URL: https://$domain"
echo
echo "    Useful commands (run from $BASE):"
COMPOSE_CMD="docker compose -f $BASE/learning_prod_setup-compose.yml --project-name learning_prod_setup"
echo "    Start   : $COMPOSE_CMD up -d"
echo "    Stop    : $COMPOSE_CMD down"
echo "    Restart : $COMPOSE_CMD restart"