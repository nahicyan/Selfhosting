#!/bin/bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# NOTE — lms src/utils/ directory structure change
#
# The lms main branch added src/utils/plyr.js (a local video player wrapper)
# which index.js imports as "./plyr". The original Dockerfile only copied
# index.js into the image, causing vite to fail with:
#   Could not resolve "./plyr" from "src/utils/index.js"
#
# Fix: the Dockerfile now copies the entire src/utils/ directory from the
# freshly cloned lms workspace so that index.js and all its sibling files
# (plyr.js and any future additions) are present at build time.
#
# This is also the correct general approach — copying a single file was always
# fragile against additions to the same directory.
#
# HOW TO REVERT if lms restructures src/utils/ and this causes problems:
#   In Step 4 below, revert the Dockerfile COPY line back to:
#     COPY lms/frontend/src/utils/index.js \
#          /home/frappe/frappe-bench/apps/lms/frontend/src/utils/index.js
#   and revert the chown line to:
#     RUN chown frappe:frappe \
#          /home/frappe/frappe-bench/apps/lms/frontend/src/utils/index.js
# ══════════════════════════════════════════════════════════════════════════════

# Workspace is always lms-custom — the build context for the custom image
WORKSPACE="/var/www/docker/frappe-lms/lms-custom"
JS_FILE="$WORKSPACE/lms/frontend/src/utils/index.js"

# ── Inputs ────────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. training.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

DEPLOY_DIR="/var/www/docker/frappe-lms/$domain"
ENV_FILE="$DEPLOY_DIR/learning_prod_setup.env"
COMPOSE_FILE="$DEPLOY_DIR/learning_prod_setup-compose.yml"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo "==> Checking instance at $DEPLOY_DIR..."

[[ -d "$DEPLOY_DIR" ]] || {
  echo "ERROR: Deploy directory not found: $DEPLOY_DIR"
  echo "       Run frappe-docker-install.sh first."
  exit 1
}

[[ -f "$COMPOSE_FILE" ]] || {
  echo "ERROR: Compose file not found: $COMPOSE_FILE"
  exit 1
}

[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: Env file not found: $ENV_FILE"
  exit 1
}

# Guard: refuse to run on an already-modded instance
ALREADY_MODDED=false

if docker image inspect lms-dropbox:custom &>/dev/null; then
  echo "  [!] Docker image lms-dropbox:custom already exists."
  ALREADY_MODDED=true
fi

if grep -q 'lms-dropbox' "$COMPOSE_FILE" 2>/dev/null; then
  echo "  [!] $COMPOSE_FILE already references lms-dropbox."
  ALREADY_MODDED=true
fi

if [[ -f "$JS_FILE" ]] && grep -q 'dropbox' "$JS_FILE" 2>/dev/null; then
  echo "  [!] $JS_FILE already contains the Dropbox mod."
  ALREADY_MODDED=true
fi

if [[ "$ALREADY_MODDED" == "true" ]]; then
  echo ""
  echo "ERROR: This instance appears to already be modded. Aborting."
  echo "       To re-apply: remove lms-dropbox:custom image and revert $COMPOSE_FILE."
  exit 1
fi

echo "==> Instance looks clean. Proceeding."
echo ""

# ── Step 1: Prepare workspace ─────────────────────────────────────────────────
echo "==> Step 1: Preparing workspace at $WORKSPACE..."
sudo mkdir -p "$WORKSPACE"

# ── Step 2: Clone LMS repository ─────────────────────────────────────────────
echo "==> Step 2: Cloning LMS repository..."
if [[ -d "$WORKSPACE/lms/.git" ]]; then
  echo "    Repo already exists, pulling latest..."
  git -C "$WORKSPACE/lms" pull
else
  git clone --depth 1 https://github.com/frappe/lms.git "$WORKSPACE/lms"
fi

# ── Step 3: Patch index.js (Dropbox + Loom embed support) ────────────────────
echo "==> Step 3: Patching lms/frontend/src/utils/index.js..."

python3 - <<'PYEOF'
import sys

path = '/var/www/docker/frappe-lms/lms-custom/lms/frontend/src/utils/index.js'

with open(path, 'r') as f:
    content = f.read()

# Guard: abort if already patched
if 'dropbox' in content or 'loom.com' in content:
    print('ERROR: File already contains dropbox or loom embed. Aborting patch.', file=sys.stderr)
    sys.exit(1)

# Anchor: dropbox and loom go between the drive block and docsPublic
# docsPublic appears only once in the embed services block (5 tabs deep)
ANCHOR = '\t\t\t\t\tdocsPublic: {'

if ANCHOR not in content:
    print('ERROR: Cannot find insertion anchor (docsPublic) in index.js.', file=sys.stderr)
    print('       The upstream file structure may have changed — inspect manually.', file=sys.stderr)
    sys.exit(1)

# Build the two new service blocks, matching the surrounding tab indentation
INSERT = (
    "\t\t\t\t\tdropbox: {\n"
    "\t\t\t\t\t\tregex: /(https?:\\/\\/(?:www\\.)?dropbox\\.com\\/[^\\s]+)/,\n"
    "\t\t\t\t\t\tembedUrl: '<%= remote_id %>',\n"
    "\t\t\t\t\t\thtml: `<iframe style='width: 100%; height: ${\n"
    "\t\t\t\t\t\t\twindow.innerWidth < 640 ? '15rem' : '30rem'\n"
    "\t\t\t\t\t\t}; border: 1px solid #D3D3D3; border-radius: 12px;' frameborder='0' allowfullscreen='true'></iframe>`,\n"
    "\t\t\t\t\t\tid: ([url]) => {\n"
    "\t\t\t\t\t\t\treturn url.replace('www.dropbox.com', 'dl.dropboxusercontent.com')\n"
    "\t\t\t\t\t\t\t          .replace('dropbox.com', 'dl.dropboxusercontent.com')\n"
    "\t\t\t\t\t\t\t          .replace(/dl=0/, 'raw=1');\n"
    "\t\t\t\t\t\t},\n"
    "\t\t\t\t\t},\n"
    "\t\t\t\t\tloom: {\n"
    "\t\t\t\t\t\tregex: /(https?:\\/\\/(?:www\\.)?loom\\.com\\/share\\/[a-zA-Z0-9]+)/,\n"
    "\t\t\t\t\t\tembedUrl: '<%= remote_id %>',\n"
    "\t\t\t\t\t\thtml: `<iframe style='width: 100%; height: ${\n"
    "\t\t\t\t\t\t\twindow.innerWidth < 640 ? '15rem' : '30rem'\n"
    "\t\t\t\t\t\t}; border: 0; border-radius: 12px;' frameborder='0' allowfullscreen='true'></iframe>`,\n"
    "\t\t\t\t\t\tid: ([url]) => {\n"
    "\t\t\t\t\t\t\treturn url.replace('loom.com/share/', 'loom.com/embed/');\n"
    "\t\t\t\t\t\t},\n"
    "\t\t\t\t\t},\n"
)

new_content = content.replace(ANCHOR, INSERT + ANCHOR, 1)

if new_content == content:
    print('ERROR: Replacement produced no change. Anchor may not match exactly.', file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(new_content)

print('    index.js patched successfully (dropbox + loom).')
PYEOF

read -rp "Would you like to review index.js before building? [y/N] " ans_js
if [[ "$ans_js" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" "$JS_FILE"
fi

# ── Step 4: Create Dockerfile ─────────────────────────────────────────────────
# UPSTREAM BUG WORKAROUND — frappe/lms#2350, frappe/lms#2467
# We build FROM frappe-lms-custom:stable (our own image built by frappe-docker-install.sh)
# instead of FROM ghcr.io/frappe/lms:stable because the official image ships without
# the lms app since ~May 2026 (frappe_docker CI/CD regression, commit ae275df).
#
# To verify if the upstream is fixed:
#   docker run --rm ghcr.io/frappe/lms:stable bash -c "ls /home/frappe/frappe-bench/apps/"
# If output includes "lms", revert the FROM line below to: FROM ghcr.io/frappe/lms:stable
# and revert the sed in Step 7 target to: ghcr\.io/frappe/lms:stable
echo "==> Step 4: Creating Dockerfile..."
cat > "$WORKSPACE/Dockerfile" <<'EOF'
FROM frappe-lms-custom:stable

USER root
# Copy the entire src/utils/ directory so index.js and all sibling files
# (e.g. plyr.js, added in a recent lms commit) are present for the vite build.
# Copying only index.js caused "Could not resolve './plyr'" build failures.
COPY lms/frontend/src/utils/ /home/frappe/frappe-bench/apps/lms/frontend/src/utils/
RUN chown -R frappe:frappe /home/frappe/frappe-bench/apps/lms/frontend/src/utils/

# Provide a minimal config so bench build does not fail
RUN echo '{"socketio_port": 9000}' > /home/frappe/frappe-bench/sites/common_site_config.json && \
    chown frappe:frappe /home/frappe/frappe-bench/sites/common_site_config.json

USER frappe
WORKDIR /home/frappe/frappe-bench
RUN bench build --app lms
EOF
echo "    Dockerfile written to $WORKSPACE/Dockerfile"

# ── Step 5: Build custom Docker image ─────────────────────────────────────────
echo "==> Step 5: Building lms-dropbox:custom image (this may take several minutes)..."
docker build -t lms-dropbox:custom "$WORKSPACE"
echo "==> Image built successfully."
echo ""

# ── Step 6: Update deployment env ────────────────────────────────────────────
echo "==> Step 6: Updating $ENV_FILE..."

# Handle both commented (#CUSTOM_IMAGE=...) and missing keys
sed -i \
  -e 's|^#\?CUSTOM_IMAGE=.*|CUSTOM_IMAGE=lms-dropbox|' \
  -e 's|^#\?CUSTOM_TAG=.*|CUSTOM_TAG=custom|' \
  "$ENV_FILE"

# Append if the key was not present at all
grep -q '^CUSTOM_IMAGE=' "$ENV_FILE" || echo 'CUSTOM_IMAGE=lms-dropbox' >> "$ENV_FILE"
grep -q '^CUSTOM_TAG=' "$ENV_FILE"    || echo 'CUSTOM_TAG=custom'        >> "$ENV_FILE"

read -rp "Would you like to review learning_prod_setup.env? [y/N] " ans_env
if [[ "$ans_env" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" "$ENV_FILE"
fi

# ── Step 7: Update compose image reference ────────────────────────────────────
# Target is frappe-lms-custom:stable (set by frappe-docker-install.sh workaround).
# When upstream bug is fixed and install.sh reverts to ghcr.io/frappe/lms:stable,
# change the sed target here back to: ghcr\.io/frappe/lms:stable
echo "==> Step 7: Updating image reference in $COMPOSE_FILE..."
sed -i 's|frappe-lms-custom:stable|lms-dropbox:custom|g' "$COMPOSE_FILE"
echo "    Compose file updated."

# ── Step 8: Restart containers ────────────────────────────────────────────────
echo "==> Step 8: Restarting containers..."
cd "$DEPLOY_DIR"
docker compose -f learning_prod_setup-compose.yml --project-name learning_prod_setup down
docker compose -f learning_prod_setup-compose.yml --project-name learning_prod_setup up -d
echo "==> Containers restarted."
echo ""

# ── Step 9: Clear Frappe cache ────────────────────────────────────────────────
echo "==> Step 9: Clearing Frappe cache for site $domain..."
docker exec learning_prod_setup-backend-1 bash -lc "bench --site ${domain} clear-cache"

echo ""
echo "==> Mod complete! Dropbox and Loom embed support is now active."
echo "    Site: https://$domain"
