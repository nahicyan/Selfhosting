#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../jitsi-nginx.conf"

# ── Gather inputs ─────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. meet.example.com): " domain
[[ -z "$domain" ]] && { echo "Domain cannot be empty."; exit 1; }

read -rp "Enter company/entity name (for branding): " company
[[ -z "$company" ]] && { echo "Company name cannot be empty."; exit 1; }

read -rp "Enter site domain only (e.g. example.com): " site
[[ -z "$site" ]] && { echo "Site domain cannot be empty."; exit 1; }

read -rp "Enter timezone (e.g. America/New_York): " timezone
[[ -z "$timezone" ]] && { echo "Timezone cannot be empty."; exit 1; }

read -rp "Enter HTTP port [8008]: " http_port
http_port="${http_port:-8008}"
[[ "$http_port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }

read -rp "Enter HTTPS port [8444]: " https_port
https_port="${https_port:-8444}"
[[ "$https_port" =~ ^[0-9]+$ ]] || { echo "Port must be a number."; exit 1; }

read -rp "Enter JVB advertise IPs — comma-separated for NAT/split-horizon (leave blank to skip): " jvb_ips

echo
echo "==> Domain   : $domain"
echo "==> Company  : $company"
echo "==> Site     : $site"
echo "==> Timezone : $timezone"
echo "==> HTTP     : $http_port"
echo "==> HTTPS    : $https_port"
[[ -n "$jvb_ips" ]] && echo "==> JVB IPs  : $jvb_ips"
echo

# ── Prepare directories ───────────────────────────────────────────────────────
INSTALL_DIR="/var/www/docker/jitsi/$domain"
# Per-domain config dir — avoids stale Prosody credentials from other installs
# causing SCRAM-SHA-1 not-authorized failures on Jicofo / JVB / Jibri.
CFG_DIR="$INSTALL_DIR/.jitsi-meet-cfg"

sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Download & extract latest release ────────────────────────────────────────
echo "==> Fetching latest Jitsi Docker release tag from GitHub..."
JITSI_TAG=$(curl -s https://api.github.com/repos/jitsi/docker-jitsi-meet/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d '"' -f 4)
[[ -z "$JITSI_TAG" ]] && { echo "ERROR: Could not fetch release tag from GitHub API."; exit 1; }
echo "==> Latest release: $JITSI_TAG"

JITSI_URL="https://github.com/jitsi/docker-jitsi-meet/archive/refs/tags/${JITSI_TAG}.tar.gz"
echo "==> Downloading $JITSI_URL ..."
wget "$JITSI_URL"

echo "==> Extracting..."
tar -zxf "${JITSI_TAG}.tar.gz"
shopt -s dotglob
mv "docker-jitsi-meet-${JITSI_TAG}/"* .
shopt -u dotglob
rm -rf "${JITSI_TAG}.tar.gz" "docker-jitsi-meet-${JITSI_TAG}/"

# ── Configure .env ────────────────────────────────────────────────────────────
echo "==> Configuring .env..."
cp env.example .env

sed -i \
  -e "s|^HTTP_PORT=8000|HTTP_PORT=$http_port|" \
  -e "s|^HTTPS_PORT=8443|HTTPS_PORT=$https_port|" \
  -e "s|^TZ=UTC|TZ=$timezone|" \
  -e "s|#PUBLIC_URL=https://meet.example.com:\${HTTPS_PORT}|PUBLIC_URL=https://$domain|" \
  .env

# Append all extra settings
cat >> .env <<EOF

# ── Custom additions ───────────────────────────────────────────────────────────
JVB_COLIBRI_PORT=8084
START_AUDIO_MUTED=9999
START_VIDEO_MUTED=9999
START_WITH_AUDIO_MUTED=false
START_WITH_VIDEO_MUTED=false
ENABLE_RECORDING=1
IGNORE_CERTIFICATE_ERRORS=true
CHROMIUM_FLAGS=--use-fake-ui-for-media-stream,--start-maximized,--kiosk,--enabled,--autoplay-policy=no-user-gesture-required,--ignore-certificate-errors,--no-sandbox,--disable-dev-shm-usage,--disable-gpu
WHITEBOARD_COLLAB_SERVER_URL_BASE=http://whiteboard.meet.jitsi
ETHERPAD_URL_BASE=http://etherpad.meet.jitsi:9001
DESKTOP_SHARING_FRAMERATE_AUTO=false
DESKTOP_SHARING_FRAMERATE_MIN=5
DESKTOP_SHARING_FRAMERATE_MAX=30
VIDEOQUALITY_PREFERRED_CODEC=VP9
VIDEOQUALITY_BITRATE_VP9_SS_HIGH=5000000
VIDEOQUALITY_BITRATE_VP8_SS_HIGH=5000000
VIDEOQUALITY_BITRATE_H264_SS_HIGH=5000000
VIDEOQUALITY_BITRATE_AV1_SS_HIGH=5000000
JVB_TCP_HARVESTER_DISABLED=false
JVB_TCP_PORT=4443
JIBRI_FINALIZE_RECORDING_SCRIPT_PATH=/config/finalize.sh
EOF

# Set CONFIG to an absolute path (Docker Compose does not expand ~)
grep -q "^CONFIG=" .env && sed -i "s|^CONFIG=.*|CONFIG=$CFG_DIR|" .env || echo "CONFIG=$CFG_DIR" >> .env

# Add JVB_ADVERTISE_IPS if provided
if [[ -n "$jvb_ips" ]]; then
  echo "JVB_ADVERTISE_IPS=$jvb_ips" >> .env
fi

# ── Review .env ───────────────────────────────────────────────────────────────
read -rp "Would you like to review/edit .env? [y/N] " ans_env
if [[ "$ans_env" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" .env
fi

# ── Review docker-compose.yml ─────────────────────────────────────────────────
read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
if [[ "$ans_compose" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" docker-compose.yml
fi

# ── Generate passwords ────────────────────────────────────────────────────────
echo "==> Generating passwords..."
bash ./gen-passwords.sh

# ── Create config directories ─────────────────────────────────────────────────
echo "==> Creating config directories at $CFG_DIR..."
mkdir -p "$CFG_DIR"/{web/images,web/css,web/lang,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}

# ── Write Jibri finalize stub ─────────────────────────────────────────────────
# Jibri's JAR defaults finalize-script to "/path/to/finalize"; without a real
# file at the configured path it logs SEVERE on every recording stop.
# This stub exits 0 so recordings save cleanly. Add upload/move logic here later.
cat > "$CFG_DIR/jibri/finalize.sh" <<'EOF'
#!/bin/bash
# Jibri post-recording finalize script.
# $1 = path to the recording directory for this session.
# Add post-processing here (e.g. upload to S3, move to NAS).
exit 0
EOF
chmod +x "$CFG_DIR/jibri/finalize.sh"
echo "==> Jibri finalize stub written to $CFG_DIR/jibri/finalize.sh"

# ── Write custom-config.js ────────────────────────────────────────────────────
echo "==> Writing custom-config.js..."
cat > "$CFG_DIR/web/custom-config.js" <<'EOF'
(function () {
  if (typeof config === 'undefined') return;

  // Camera quality
  config.resolution = 1080;
  config.constraints = config.constraints || {};
  config.constraints.video = config.constraints.video || {};
  config.constraints.video.height = { ideal: 1080, max: 1440, min: 480 };

  config.enableNoisyMicDetection = true;

  // Screenshare frame rate
  config.desktopSharingFrameRate = { min: 5, max: 30 };

  // Codec preference — VP9 first for SVC screenshare
  config.videoQuality = config.videoQuality || {};
  config.videoQuality.codecPreferenceOrder = ['VP9', 'VP8', 'H264'];

  config.videoQuality.vp9 = config.videoQuality.vp9 || {};
  config.videoQuality.vp9.low = 100000;
  config.videoQuality.vp9.standard = 300000;
  config.videoQuality.vp9.high = 1200000;
  config.videoQuality.vp9.fullHd = 2500000;
  config.videoQuality.vp9.ssHigh = 5000000;

  config.videoQuality.vp8 = config.videoQuality.vp8 || {};
  config.videoQuality.vp8.low = 200000;
  config.videoQuality.vp8.standard = 500000;
  config.videoQuality.vp8.high = 1500000;
  config.videoQuality.vp8.fullHd = 3000000;
  config.videoQuality.vp8.ssHigh = 5000000;
})();
EOF

# ── Write custom-interface_config.js ─────────────────────────────────────────
echo "==> Writing custom-interface_config.js..."
cat > "$CFG_DIR/web/custom-interface_config.js" <<EOF
(function () {
  if (typeof interfaceConfig === 'undefined') return;
  interfaceConfig.APP_NAME = '${company}';
  interfaceConfig.DEFAULT_REMOTE_DISPLAY_NAME = '${company} Guest';
  interfaceConfig.BRAND_WATERMARK_LINK = 'https://${site}';
  interfaceConfig.JITSI_WATERMARK_LINK = 'https://${site}';
  interfaceConfig.DEFAULT_BACKGROUND = '#040404';
  interfaceConfig.SHOW_BRAND_WATERMARK = false;
  interfaceConfig.SHOW_JITSI_WATERMARK = true;
})();
EOF

read -rp "Would you like to review/edit custom-interface_config.js? [y/N] " ans_iface
if [[ "$ans_iface" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" "$CFG_DIR/web/custom-interface_config.js"
fi

# ── Pull Docker images ────────────────────────────────────────────────────────
echo "==> Pulling Docker images (this may take several minutes)..."
docker compose pull

# ── Start containers ──────────────────────────────────────────────────────────
echo "==> Starting Jitsi containers..."
docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml up -d
echo "==> Containers started."
echo ""

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
    -e "s|meet\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:8008|127.0.0.1:$http_port|g" \
    -e "s|localhost:8444|localhost:$https_port|g" \
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
echo ""
echo "==> Jitsi Meet installation complete."
echo "    URL: https://$domain"
echo ""
echo "    Config dir  : $CFG_DIR"
echo "    Install dir : $INSTALL_DIR"
echo ""
echo "    Start   : docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml up -d"
echo "    Stop    : docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml down"
echo ""
echo "    Add user    : docker compose exec prosody prosodyctl --config /config/prosody.cfg.lua register USERNAME meet.jitsi PASSWORD"
echo "    Remove user : docker compose exec prosody prosodyctl --config /config/prosody.cfg.lua unregister USERNAME meet.jitsi"
echo ""
echo "    Run jitsi-docker-mod.sh to customize branding, colors, and text."
