#!/bin/bash
# jitsi-docker-mod.sh — Interactive customization script for a Jitsi Meet Docker install.
#
# What it does (in order):
#   1. Asks where your Jitsi instances live and lets you pick one.
#   2. Prompts for welcome-page text and patches it into app.bundle.min.js
#      (English strings are baked into the bundle at build time — lang/main.json
#       alone is not enough to change the visible title/subtitle for EN users).
#   3. Prompts for browser tab title and Open Graph meta tags (title.html).
#   4. Prompts for hex colors and writes CSS overrides to all.css.
#   5. Prompts for custom image files (favicon, watermark, hero background).
#      Accepts local file paths OR https:// URLs (downloaded via wget).
#   6. Writes custom-interface_config.js with branding/logo settings.
#   7. Injects the resulting file mounts into docker-compose.yml automatically.
#   8. Optionally restarts the containers so everything takes effect.
#
# Re-running is safe — existing values are shown as defaults, CSS blocks are
# stripped and re-appended cleanly, and volume mounts already in the compose
# file are detected and skipped.
#
# Key files this script manages (all under $CFG_DIR/web/):
#   css/all.css                 — color and layout overrides
#   lang/main.json              — full i18n translation file (source of truth)
#   lang/main-en.json           — copy of main.json (served by XHR backend for EN)
#   libs/app.bundle.min.js      — patched React bundle (only way to change EN text)
#   libs/app.bundle.min.js.map  — source map, must be mounted alongside the bundle
#   libs/app.bundle.min.js.orig — pristine bundle extracted from container (never modified)
#   images/favicon.svg          — browser tab icon
#   images/watermark.svg        — logo shown inside meetings
#   images/welcome-background.png — hero background on the welcome page
#   title.html                  — browser <title> and Open Graph meta tags
#   custom-interface_config.js  — JS config: app name, logo URLs, watermark toggles

set -euo pipefail

echo ""
echo "════════════════════════════════════════════════"
echo " Jitsi Meet — Modification Script"
echo "════════════════════════════════════════════════"
echo ""

# ── 1. Choose base directory ──────────────────────────────────────────────────
# The install script places every domain under a shared base directory.
# Default is /var/www/docker/jitsi — option 2 lets you override this.
echo "Where are your Jitsi Meet Docker instances located?"
echo "  1) Default: /var/www/docker/jitsi"
echo "  2) Custom path"
read -rp "Select [1/2]: " _base_choice

if [[ "$_base_choice" == "2" ]]; then
  read -rp "Enter custom base path: " BASE_DIR
  # Expand ~ to $HOME because Docker Compose doesn't accept ~ in bind-mount paths
  BASE_DIR="${BASE_DIR/#\~/$HOME}"
else
  BASE_DIR="/var/www/docker/jitsi"
fi

[[ -d "$BASE_DIR" ]] || { echo "ERROR: Directory not found: $BASE_DIR"; exit 1; }

# ── 2. List Jitsi instances (subdirs containing docker-compose.yml) ───────────
# Each domain has its own subdirectory created by jitsi-docker-install.sh.
# We identify valid instances by the presence of a docker-compose.yml inside.
echo ""
mapfile -t INSTANCES < <(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d \
  -exec test -f "{}/docker-compose.yml" \; -print | sort)

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
  echo "No Jitsi instances found in '$BASE_DIR'."
  echo "Run jitsi-docker-install.sh first."
  exit 1
fi

# If there's only one instance, select it automatically — no need to prompt.
if [[ ${#INSTANCES[@]} -eq 1 ]]; then
  INSTALL_DIR="${INSTANCES[0]}"
  domain="$(basename "$INSTALL_DIR")"
  echo "Found one instance: $domain"
else
  echo "Found Jitsi instances:"
  for i in "${!INSTANCES[@]}"; do
    echo "  $((i+1))) $(basename "${INSTANCES[$i]}")"
  done
  echo ""
  read -rp "Select instance number: " _inst_num
  # Validate the number is in range before using it as an array index
  if ! [[ "$_inst_num" =~ ^[0-9]+$ ]] || \
     [[ "$_inst_num" -lt 1 ]] || \
     [[ "$_inst_num" -gt "${#INSTANCES[@]}" ]]; then
    echo "Invalid selection."
    exit 1
  fi
  INSTALL_DIR="${INSTANCES[$((_inst_num-1))]}"
  domain="$(basename "$INSTALL_DIR")"
fi

echo ""

# ── Path setup ────────────────────────────────────────────────────────────────
# Locate the required files for the chosen instance.
ENV_FILE="$INSTALL_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }

COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || { echo "ERROR: docker-compose.yml not found at $COMPOSE_FILE"; exit 1; }

# CONFIG= in .env tells Docker Compose where to write runtime config files.
# The install script sets this to a per-domain path to avoid Prosody credential
# conflicts between multiple instances. Fall back to the per-domain default if
# the line isn't present.
CFG_DIR=$(grep "^CONFIG=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
CFG_DIR="${CFG_DIR:-$INSTALL_DIR/.jitsi-meet-cfg}"
# Expand leading ~ if the user set CONFIG=~/... in .env
[[ "$CFG_DIR" == ~* ]] && CFG_DIR="${HOME}${CFG_DIR#\~}"

# Shorthand paths for every file this script manages.
# All of these live under CFG_DIR/web/ which is bind-mounted into the container.
IFACE_CFG="$CFG_DIR/web/custom-interface_config.js"   # JS branding/logo config
IMG_DIR="$CFG_DIR/web/images"                          # favicon, watermark, hero bg
CSS_DIR="$CFG_DIR/web/css"                             # all.css color overrides
LANG_DIR="$CFG_DIR/web/lang"                           # main.json + main-en.json
LIBS_DIR="$CFG_DIR/web/libs"                           # patched app bundle
TITLE_HTML="$CFG_DIR/web/title.html"                   # <title> + Open Graph tags
ALL_CSS="$CSS_DIR/all.css"                             # full CSS file (base + overrides)
MAIN_JSON="$LANG_DIR/main.json"                        # i18n translation strings
BUNDLE_JS="$LIBS_DIR/app.bundle.min.js"                # patched React bundle

mkdir -p "$IMG_DIR" "$CSS_DIR" "$LANG_DIR" "$LIBS_DIR"

echo ""
echo "==> Installation : $INSTALL_DIR"
echo "==> Config dir   : $CFG_DIR"
echo ""

# ── Helper functions ──────────────────────────────────────────────────────────

# ask <prompt> <default>
# Prints the user's input, or <default> if they just pressed Enter.
# Used to show current values and let the user skip unchanged fields.
ask() {
  local prompt="$1" default="$2" result
  read -rp "$prompt [$default]: " result
  printf '%s' "${result:-$default}"
}

# ask_color <prompt> <default>
# Like ask(), but loops until the user enters a valid 3- or 6-digit hex color.
ask_color() {
  local prompt="$1" default="$2" color
  while true; do
    read -rp "$prompt [$default]: " color
    color="${color:-$default}"
    if [[ "$color" =~ ^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$ ]]; then
      printf '%s' "$color"
      return
    fi
    echo "    Invalid hex color — enter a value like #040404 or #fff"
  done
}

# copy_image <prompt> <destination>
# Asks for a source (local file path or https:// URL) and places it at
# <destination>. Blank input skips. URLs are fetched with wget.
copy_image() {
  local prompt="$1" dest="$2" src
  read -rp "$prompt (local path, https:// URL, or blank to skip): " src
  [[ -z "$src" ]] && return
  if [[ "$src" =~ ^https?:// ]]; then
    echo "    Downloading..."
    if wget -q -O "$dest" "$src" 2>/dev/null && [[ -s "$dest" ]]; then
      echo "    Downloaded → $dest"
    else
      rm -f "$dest"
      echo "    WARNING: Download failed: $src — skipping."
    fi
  elif [[ -f "$src" ]]; then
    cp "$src" "$dest"
    echo "    Copied → $dest"
  else
    echo "    WARNING: File not found: $src — skipping."
  fi
}

# read_iface <key> <default>
# Reads a string property from custom-interface_config.js so we can show
# the current value as a default when prompting.
read_iface() {
  local key="$1" default="$2"
  grep -oP "(?<=interfaceConfig\.$key = ')[^']+" "$IFACE_CFG" 2>/dev/null || echo "$default"
}

# read_iface_bool <key> <default>
# Like read_iface() but extracts a bare true/false value (no quotes in JS).
read_iface_bool() {
  local key="$1" default="$2"
  grep -oP "(?<=interfaceConfig\.$key = )(true|false)" "$IFACE_CFG" 2>/dev/null || echo "$default"
}

# ── Check web container ───────────────────────────────────────────────────────
# Several sections extract base files (all.css, title.html, main.json, the JS
# bundle) from the live container. If the container isn't running those sections
# fall back to any locally cached copies, or skip gracefully.
WEB_RUNNING=false
if cd "$INSTALL_DIR" && docker compose ps web 2>/dev/null | grep -q "running\|Up"; then
  WEB_RUNNING=true
fi

if [[ "$WEB_RUNNING" == "false" ]]; then
  echo "WARNING: Jitsi web container is not running."
  echo "         Sections that extract files from the container will be skipped."
  echo "         Start the stack first, then re-run this script."
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 1 — Interface Branding (custom-interface_config.js)
#
#  custom-interface_config.js is loaded by the Jitsi web app and overrides
#  fields in the built-in interfaceConfig object. It controls:
#    APP_NAME                    — displayed in the meeting header and tab title
#    DEFAULT_REMOTE_DISPLAY_NAME — placeholder name for participants with no profile
#    BRAND_WATERMARK_LINK        — URL opened when clicking the brand logo
#    JITSI_WATERMARK_LINK        — URL opened when clicking the Jitsi logo
#    DEFAULT_LOGO_URL            — logo shown in meetings (relative or absolute URL)
#    DEFAULT_WELCOME_PAGE_LOGO_URL — logo on the welcome / landing page
#    PROVIDER_NAME               — shown in calendar integration text
#    SHOW_BRAND_WATERMARK        — toggles your brand logo in meetings
#    SHOW_JITSI_WATERMARK        — toggles the Jitsi logo in meetings
#    DEFAULT_BACKGROUND          — solid hex color behind the video tiles
#
#  This section reads current values first so pressing Enter keeps them.
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 1 — Interface Branding"
echo " These values control the app name, watermarks, and"
echo " logo displayed inside meetings and on the welcome page."
echo "══════════════════════════════════════════════════════"
echo ""

cur_app_name=$(read_iface APP_NAME "Jitsi Meet")
cur_display_name=$(read_iface DEFAULT_REMOTE_DISPLAY_NAME "Fellow Jitster")
cur_brand_link=$(read_iface BRAND_WATERMARK_LINK "")
cur_jitsi_link=$(read_iface JITSI_WATERMARK_LINK "https://jitsi.org")
cur_logo=$(read_iface DEFAULT_LOGO_URL "images/watermark.svg")
cur_welcome_logo=$(read_iface DEFAULT_WELCOME_PAGE_LOGO_URL "images/watermark.svg")
cur_provider=$(read_iface PROVIDER_NAME "Jitsi")
cur_show_brand=$(read_iface_bool SHOW_BRAND_WATERMARK "false")
cur_show_jitsi=$(read_iface_bool SHOW_JITSI_WATERMARK "true")
cur_bg=$(read_iface DEFAULT_BACKGROUND "#040404")

app_name=$(ask "App name (shown in meeting header & tab title)" "$cur_app_name")
display_name=$(ask "Default guest display name (shown for unnamed participants)" "$cur_display_name")
brand_link=$(ask "Brand watermark click-through URL" "$cur_brand_link")
jitsi_link=$(ask "Jitsi watermark click-through URL" "$cur_jitsi_link")
logo_url=$(ask "Default logo URL (relative path or https://...)" "$cur_logo")
welcome_logo=$(ask "Welcome page logo URL" "$cur_welcome_logo")
provider_name=$(ask "Provider name (appears in calendar connect text)" "$cur_provider")

# Watermark toggles accept y/n interactively but must be stored as true/false
# for the JS file.
read -rp "Show brand watermark in meeting? (y/n) [$cur_show_brand]: " _sb
show_brand="${_sb:-$cur_show_brand}"
[[ "$show_brand" =~ ^[Yy]$ || "$show_brand" == "true" ]] && show_brand="true" || show_brand="false"

read -rp "Show Jitsi watermark in meeting? (y/n) [$cur_show_jitsi]: " _sj
show_jitsi="${_sj:-$cur_show_jitsi}"
[[ "$show_jitsi" =~ ^[Yy]$ || "$show_jitsi" == "true" ]] && show_jitsi="true" || show_jitsi="false"

bg_default=$(ask_color "Default meeting background color (hex)" "$cur_bg")

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 2 — Welcome Page Text
#
#  WHY THIS IS COMPLEX (important to understand before editing):
#
#  Jitsi uses i18next for translations. During the React build, English strings
#  from lang/main.json are embedded directly into app.bundle.min.js via:
#    addResourceBundle('en', 'main', MAIN_RESOURCES, deep=true, overwrite=true)
#  This marks the EN/main namespace as already loaded, so the i18next HTTP
#  backend never fetches lang/main-en.json at runtime for English users.
#
#  Consequence: mounting a custom lang/main.json or lang/main-en.json does NOT
#  change what English-speaking visitors see. The only reliable method is to
#  extract the stock bundle from the container and search-replace the string
#  values directly inside the minified JS.
#
#  The strings inside the bundle look like: "headerTitle":"Jitsi Meet"
#  (minified JSON — no spaces around the colon).
#
#  KEYS PATCHED IN THE BUNDLE:
#    headerTitle    — large heading on the welcome page hero
#    headerSubtitle — smaller text below the heading
#    jitsiOnMobile  — mobile app promo line at the bottom of the page
#    startMeeting   — text on the Start/Join button
#
#  WORKFLOW:
#    First run   → docker cp extracts the stock bundle to .orig (pristine copy)
#    Every run   → .orig is copied to app.bundle.min.js, then Python replaces
#                  the four keys above using regex. The .orig file is never
#                  modified so we always start from a clean base.
#    Offline run → if .orig exists from a previous online run, patching still
#                  works without the container.
#
#  main.json and main-en.json are also updated (covers non-English locales and
#  future Jitsi versions that may fix the XHR override path).
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 2 — Welcome Page Text"
echo " Controls the title, subtitle, description, and other"
echo " text shown on the Jitsi welcome / landing page."
echo "══════════════════════════════════════════════════════"
echo ""

# Extract pristine bundle once — Jitsi bakes English strings into app.bundle.min.js
# at build time. The XHR lang loader skips EN (it's pre-loaded), so the only way
# to change the visible title/subtitle/mobile text is to patch the bundle itself.
# docker cp is used here instead of exec+cat because the bundle is ~20 MB and
# exec stdout piping can truncate or mangle large files.
if [[ "$WEB_RUNNING" == "true" ]] && [[ ! -f "${BUNDLE_JS}.orig" ]]; then
  echo "==> Extracting app.bundle.min.js from container (first time, may take a moment)..."
  cd "$INSTALL_DIR"
  # Get the container ID for the web service so we can use docker cp
  _cid=$(docker compose ps -q web 2>/dev/null | head -1)
  if [[ -n "$_cid" ]] \
     && docker cp "${_cid}:/usr/share/jitsi-meet/libs/app.bundle.min.js" "${BUNDLE_JS}.orig" 2>/dev/null \
     && [[ -s "${BUNDLE_JS}.orig" ]]; then
    echo "    Bundle saved ($(du -sh "${BUNDLE_JS}.orig" | cut -f1))."
    # The .map source map must be mounted alongside the bundle; without it the
    # browser logs 404 errors for every page load (non-fatal but noisy).
    if docker cp "${_cid}:/usr/share/jitsi-meet/libs/app.bundle.min.js.map" "${BUNDLE_JS}.map" 2>/dev/null; then
      echo "    Source map saved ($(du -sh "${BUNDLE_JS}.map" | cut -f1))."
    fi
  else
    rm -f "${BUNDLE_JS}.orig"
    echo "    WARNING: Could not extract bundle from container."
  fi
  unset _cid
fi

# Extract main.json from the container so we have a fresh baseline with all keys.
# We write to a .tmp file first and validate it as JSON before replacing the real
# file — this prevents an empty or partial read (e.g. container still starting)
# from corrupting the cached copy.
SKIP_JSON=false
_json_extracted=false
if [[ "$WEB_RUNNING" == "true" ]]; then
  echo "==> Extracting main.json from container..."
  cd "$INSTALL_DIR"
  _json_tmp="${MAIN_JSON}.tmp"
  if docker compose exec -T web cat /usr/share/jitsi-meet/lang/main.json > "$_json_tmp" 2>/dev/null \
     && python3 -c "import json; json.load(open('$_json_tmp'))" 2>/dev/null; then
    mv "$_json_tmp" "$MAIN_JSON"
    echo "    Saved to $MAIN_JSON"
    _json_extracted=true
  else
    rm -f "$_json_tmp"
    echo "    WARNING: Container returned empty or invalid JSON (may still be starting up)."
  fi
fi

# If we couldn't get a fresh copy, fall back to whatever is cached locally.
if [[ "$_json_extracted" == "false" ]]; then
  if [[ -f "$MAIN_JSON" ]]; then
    echo "    Using cached $MAIN_JSON"
  else
    echo "    No main.json available. Skipping Section 2."
    SKIP_JSON=true
  fi
fi

if [[ "$SKIP_JSON" == "false" ]]; then
  # Read current values from main.json to use as prompt defaults.
  # These will be the user's own custom strings on re-runs, or the Jitsi
  # defaults on first run (since we just extracted the stock main.json).
  cur_h_title=$(python3 -c "
import json, sys
try:
    d = json.load(open('$MAIN_JSON'))
    print(d.get('welcomepage', {}).get('headerTitle', 'Jitsi Meet'))
except: print('Jitsi Meet')
")
  cur_h_sub=$(python3 -c "
import json, sys
try:
    d = json.load(open('$MAIN_JSON'))
    print(d.get('welcomepage', {}).get('headerSubtitle', 'Secure and high quality meetings'))
except: print('Secure and high quality meetings')
")
  cur_desc=$(python3 -c "
import json, sys
try:
    d = json.load(open('$MAIN_JSON'))
    print(d.get('welcomepage', {}).get('appDescription', ''))
except: print('')
")
  cur_mobile=$(python3 -c "
import json, sys
try:
    d = json.load(open('$MAIN_JSON'))
    print(d.get('welcomepage', {}).get('jitsiOnMobile', ''))
except: print('')
")
  cur_enter=$(python3 -c "
import json, sys
try:
    d = json.load(open('$MAIN_JSON'))
    print(d.get('welcomepage', {}).get('startMeeting', 'Start meeting'))
except: print('Start meeting')
")

  header_title=$(ask "Welcome page main title" "$cur_h_title")
  header_sub=$(ask "Welcome page subtitle (below the main title)" "$cur_h_sub")
  echo "    App description (shown below subtitle, can be long):"
  echo "    Current: $cur_desc"
  read -rp "    New description (blank to keep current): " _desc
  app_desc="${_desc:-$cur_desc}"
  mobile_text=$(ask "Mobile app promo text (shown at page bottom)" "$cur_mobile")
  enter_room=$(ask "Start/join button text" "$cur_enter")

  # Pass values to Python via environment variables to avoid quoting/injection
  # issues with heredoc variable expansion inside single-quoted PYEOF delimiters.
  export MAIN_JSON
  export MOD_HEADER_TITLE="$header_title"
  export MOD_HEADER_SUB="$header_sub"
  export MOD_APP_DESC="$app_desc"
  export MOD_MOBILE="$mobile_text"
  export MOD_START="$enter_room"

  # Update the welcomepage section of main.json.
  # data.setdefault('welcomepage', {}) creates the key if it doesn't exist.
  # json.dump with ensure_ascii=False preserves UTF-8 characters (em dashes etc.)
  python3 - <<'PYEOF'
import json, os

path = os.environ['MAIN_JSON']
with open(path, 'r') as f:
    data = json.load(f)

wp = data.setdefault('welcomepage', {})
wp['headerTitle']    = os.environ['MOD_HEADER_TITLE']
wp['headerSubtitle'] = os.environ['MOD_HEADER_SUB']
wp['appDescription'] = os.environ['MOD_APP_DESC']
wp['jitsiOnMobile']  = os.environ['MOD_MOBILE']
wp['startMeeting']   = os.environ['MOD_START']

with open(path, 'w') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
print('    main.json updated.')
PYEOF

  # Keep main-en.json in sync (fallback for non-EN languages and future-proofing).
  # The i18next HTTP backend fetches lang/main-{{lng}}.json, so for English that
  # is lang/main-en.json (not main.json). This copy covers that path.
  cp "$MAIN_JSON" "$LANG_DIR/main-en.json"
  echo "    main-en.json written."

  # Patch app.bundle.min.js — English strings are baked into the bundle at build
  # time. The i18next XHR backend skips EN (pre-loaded via addResourceBundle), so
  # the only reliable way to change visible text is to replace the strings directly.
  #
  # Strategy: always start from .orig (the pristine container copy) so each run
  # produces a clean result with no accumulation of previous replacements.
  #
  # The regex matches the exact minified key-value format: "key":"value"
  # json.dumps() wraps the new value in quotes and escapes any special characters.
  export BUNDLE_JS
  if [[ -f "${BUNDLE_JS}.orig" ]]; then
    cp "${BUNDLE_JS}.orig" "$BUNDLE_JS"
    python3 - <<'BEOF'
import re, json, os

bundle_path = os.environ['BUNDLE_JS']
with open(bundle_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Keys to replace and their new values.
# To add more keys: find the exact key name in lang/main.json and add it here.
replacements = {
    'headerTitle':    os.environ['MOD_HEADER_TITLE'],
    'headerSubtitle': os.environ['MOD_HEADER_SUB'],
    'jitsiOnMobile':  os.environ['MOD_MOBILE'],
    'startMeeting':   os.environ['MOD_START'],
}

for key, value in replacements.items():
    # Pattern: "key":"<anything except a quote>"
    # Replacement: "key":<json-encoded value>  (json.dumps adds the quotes)
    content = re.sub(
        r'"' + key + r'":"[^"]*"',
        '"' + key + '":' + json.dumps(value, ensure_ascii=False),
        content
    )

with open(bundle_path, 'w', encoding='utf-8') as f:
    f.write(content)
print('    app.bundle.min.js patched.')
BEOF
  else
    echo "    NOTE: No pristine bundle found — run again with container online to enable bundle patching."
  fi

  unset MOD_HEADER_TITLE MOD_HEADER_SUB MOD_APP_DESC MOD_MOBILE MOD_START BUNDLE_JS
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 3 — Page Title & Open Graph Meta Tags (title.html)
#
#  title.html is injected into the <head> of every page by Nginx. It controls:
#    <title>              — text in the browser tab
#    og:title             — heading in link previews (Slack, Teams, WhatsApp, etc.)
#    og:description       — body text in link previews
#    og:image             — thumbnail image in link previews
#    <link rel="icon">    — favicon (points to images/favicon.svg)
#
#  We always extract a fresh copy from the container so we don't miss any
#  structure changes across Jitsi version upgrades. The container copy is
#  then parsed for current values, shown as defaults, and rewritten.
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 3 — Page Title & Meta Tags"
echo " Controls the browser tab title and link preview"
echo " cards (Open Graph tags) for your Jitsi instance."
echo "══════════════════════════════════════════════════════"
echo ""

SKIP_TITLE=false
if [[ "$WEB_RUNNING" == "true" ]]; then
  echo "==> Extracting title.html from container..."
  cd "$INSTALL_DIR"
  docker compose exec -T web cat /usr/share/jitsi-meet/title.html > "$TITLE_HTML"
  echo "    Saved to $TITLE_HTML"
elif [[ -f "$TITLE_HTML" ]]; then
  echo "    Container offline — using cached $TITLE_HTML"
else
  echo "    Container offline and no cached title.html. Skipping Section 3."
  SKIP_TITLE=true
fi

if [[ "$SKIP_TITLE" == "false" ]]; then
  # Parse current values from the HTML with regex so we can show them as defaults
  cur_tab_title=$(grep -oP '(?<=<title>)[^<]+' "$TITLE_HTML" 2>/dev/null || echo "Jitsi Meet")
  cur_og_title=$(grep -oP 'og:title" content="\K[^"]+' "$TITLE_HTML" 2>/dev/null || echo "Jitsi Meet")
  cur_og_desc=$(grep -oP 'og:description" content="\K[^"]+' "$TITLE_HTML" 2>/dev/null || echo "Join a WebRTC video conference powered by the Jitsi Videobridge")
  cur_og_image=$(grep -oP 'og:image" content="\K[^"]+' "$TITLE_HTML" 2>/dev/null || echo "images/jitsilogo.png?v=1")

  tab_title=$(ask "Browser tab title" "$cur_tab_title")
  og_title=$(ask "Open Graph title (shown in link previews)" "$cur_og_title")
  og_desc=$(ask "Open Graph description (shown in link previews)" "$cur_og_desc")
  og_image=$(ask "Open Graph image URL (shown in link previews)" "$cur_og_image")

  # Write the complete title.html. The favicon link here overrides the default
  # Jitsi favicon so it points to our custom images/favicon.svg mount.
  cat > "$TITLE_HTML" <<EOF
<title>${tab_title}</title>
<meta property="og:title" content="${og_title}"/>
<meta property="og:image" content="${og_image}"/>
<meta property="og:description" content="${og_desc}"/>
<meta description="${og_desc}"/>
<meta itemprop="name" content="${og_title}"/>
<meta itemprop="description" content="${og_desc}"/>
<meta itemprop="image" content="${og_image}"/>
<link rel="icon" href="images/favicon.svg?v=1">
EOF
  echo "    title.html written."
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 4 — Colors (CSS override appended to all.css)
#
#  Rather than replacing all.css entirely (which would break on Jitsi upgrades),
#  we extract the stock file once and then append a clearly-marked override block.
#  On every subsequent run the old override block is stripped first so we don't
#  accumulate duplicate rules.
#
#  CSS SELECTORS (verified against jitsi-meet source):
#    .welcome .header             — the hero background on the welcome page
#                                   (defined in css/_welcome_page.scss)
#    h1.header-text-title         — the large title text on the hero
#    span.header-text-subtitle    — the subtitle text below it
#    .welcome-page-button         — the Start / Join meeting button
#    .welcome-page-button:hover   — same button on hover
#    --toolbox-background-color   — CSS variable read by the toolbar component
#    .toolbox-content-wrapper::after — the actual toolbar pill background
#                                      (defined in css/_toolbars.scss)
#
#  BACKGROUND IMAGE PRIORITY:
#    Section 4 checks whether welcome-background.png already exists. If it does,
#    it uses background-image: url(...). If not, it falls back to a solid color.
#    Section 5 runs after Section 4, so if a new image is provided there, it
#    appends a second override rule that wins via CSS cascade order (last wins).
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 4 — Colors"
echo " Enter hex colors (e.g. #1a2b3c). Press Enter to keep"
echo " the current/default value shown in brackets."
echo "══════════════════════════════════════════════════════"
echo ""

SKIP_CSS=false
# Extract the base all.css from the container only on the first run.
# After that we work on the local copy (which has our override block appended)
# and the Python strip-and-reappend logic handles idempotency.
if [[ "$WEB_RUNNING" == "true" ]] && [[ ! -f "$ALL_CSS" ]]; then
  echo "==> Extracting base all.css from container (first run)..."
  cd "$INSTALL_DIR"
  docker compose exec -T web cat /usr/share/jitsi-meet/css/all.css > "$ALL_CSS"
  echo "    Saved to $ALL_CSS"
elif [[ ! -f "$ALL_CSS" ]]; then
  echo "    Container offline and no cached all.css. Skipping Section 4."
  SKIP_CSS=true
fi

if [[ "$SKIP_CSS" == "false" ]]; then
  # Parse the current override block to use as defaults on re-runs.
  # Falls back to sensible Jitsi-like defaults if the pattern isn't found.
  cur_hero_bg=$(grep -oP '(?<=background-color: )#[0-9a-fA-F]{3,6}(?= !important)' "$ALL_CSS" 2>/dev/null | head -1 || echo "#131519")
  cur_toolbar_bg=$(grep -oP '(?<=--toolbox-background-color: )#[0-9a-fA-F]{3,6}' "$ALL_CSS" 2>/dev/null | head -1 || echo "#1e2126")
  cur_btn_bg=$(grep -oP '(?<=\.welcome-page-button \{ background: )[^!]+(?= !important)' "$ALL_CSS" 2>/dev/null | head -1 || echo "#0074E0")
  cur_btn_hover=$(grep -oP '(?<=\.welcome-page-button:hover \{ background-color: )[^!]+(?= !important)' "$ALL_CSS" 2>/dev/null | head -1 || echo "#4687ED")
  cur_title_color=$(grep -oP '(?<=h1\.header-text-title \{ color: )[^!]+(?= !important)' "$ALL_CSS" 2>/dev/null | head -1 || echo "#ffffff")

  hero_bg=$(ask_color "Welcome page hero background color (replaces default space image)" "${cur_hero_bg:-#131519}")
  welcome_title_color=$(ask_color "Welcome page title & subtitle text color" "${cur_title_color:-#ffffff}")
  btn_bg=$(ask_color "Start/join button background color" "${cur_btn_bg:-#0074E0}")
  btn_hover=$(ask_color "Start/join button hover color" "${cur_btn_hover:-#4687ED}")
  toolbar_bg=$(ask_color "In-meeting toolbar background color" "${cur_toolbar_bg:-#1e2126}")

  # Strip the previous custom block (identified by the marker comment) so we
  # don't stack duplicate rules on repeated runs. The marker line and everything
  # after it is removed; the stock CSS above it is preserved unchanged.
  python3 - <<PYEOF
path = '$ALL_CSS'
with open(path, 'r') as f:
    content = f.read()
marker = '/* === JITSI CUSTOM COLOR OVERRIDES === */'
idx = content.find(marker)
if idx != -1:
    content = content[:idx].rstrip('\n')
with open(path, 'w') as f:
    f.write(content)
PYEOF

  # Choose the hero rule based on whether the background image file is present.
  # If present: use background-image pointing to the mounted file.
  # If absent:  use a solid background-color and remove the default space image.
  if [[ -f "$IMG_DIR/welcome-background.png" ]]; then
    HERO_CSS=".welcome .header { background-image: url('/images/welcome-background.png') !important; background-size: cover !important; background-position: center !important; }"
  else
    HERO_CSS=".welcome .header { background-image: none !important; background-color: ${hero_bg} !important; }"
  fi

  # Append the override block. The marker comment acts as the anchor for the
  # strip logic above, so it must appear on its own line at the top of the block.
  cat >> "$ALL_CSS" <<EOF

/* === JITSI CUSTOM COLOR OVERRIDES === */
/* Applied by jitsi-docker-mod.sh — edit or re-run to change. */

/* Welcome page hero header background */
${HERO_CSS}

/* Welcome page title and subtitle text */
h1.header-text-title { color: ${welcome_title_color} !important; }
span.header-text-subtitle { color: ${welcome_title_color} !important; }

/* Welcome page start/join button */
.welcome-page-button { background: ${btn_bg} !important; }
.welcome-page-button:hover { background-color: ${btn_hover} !important; }

/* In-meeting toolbar */
:root { --toolbox-background-color: ${toolbar_bg}; }
.toolbox-content-wrapper::after { background: ${toolbar_bg} !important; }
EOF

  echo "    Color overrides written to all.css."
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 5 — Images
#
#  Three image slots — each accepts a local file path or an https:// URL.
#  Leaving a prompt blank skips that image (existing file is kept).
#
#  favicon.svg          → images/favicon.svg in the container
#                         Shown in the browser tab. SVG is preferred over PNG.
#
#  watermark.svg        → images/watermark.svg in the container
#                         Logo displayed inside the meeting room (top-left area).
#                         Also used as the welcome page logo if DEFAULT_LOGO_URL
#                         points to images/watermark.svg (the default).
#
#  welcome-background.png → images/welcome-background.png in the container
#                         Hero background on the welcome / landing page.
#                         If this file exists, Section 4's solid-color rule is
#                         overridden by the image rule appended below.
#
#  Note: Section 4 runs before Section 5. If a background image is uploaded here
#  for the first time, the image-override block below appended after Section 4's
#  output wins via CSS cascade (last rule at same specificity wins).
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 5 — Images"
echo " Provide paths to your custom image files."
echo " Leave blank to skip any image."
echo ""
echo " favicon.svg        — browser tab icon"
echo " watermark.svg      — logo shown inside meetings"
echo " welcome-background.png — hero background image"
echo "══════════════════════════════════════════════════════"
echo ""

copy_image "Path to favicon.svg" "$IMG_DIR/favicon.svg"
copy_image "Path to watermark.svg" "$IMG_DIR/watermark.svg"
copy_image "Path to welcome-background.png" "$IMG_DIR/welcome-background.png"

# If an image was just copied this run, override the solid-color hero CSS with the image URL.
# (Section 4 only uses url() if the file already existed when it ran — this handles first-time uploads.)
if [[ -f "$IMG_DIR/welcome-background.png" && -f "$ALL_CSS" ]]; then
  cat >> "$ALL_CSS" <<'BGEOF'

/* Welcome background image override (Section 5 — image takes priority over solid color) */
.welcome .header { background-image: url('/images/welcome-background.png') !important; background-size: cover !important; background-position: center !important; }
BGEOF
  echo "    Background image CSS applied."
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 6 — Write custom-interface_config.js
#
#  Writes the file using the values collected in Section 1. The file is wrapped
#  in an IIFE with a typeof guard so it degrades gracefully if interfaceConfig
#  is not defined (e.g. in newer Jitsi versions that removed the global).
#
#  To add more interfaceConfig keys, add them to both the Section 1 prompts
#  (above) and to the cat heredoc below.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Writing custom-interface_config.js..."
cat > "$IFACE_CFG" <<EOF
(function () {
  if (typeof interfaceConfig === 'undefined') return;
  interfaceConfig.APP_NAME = '${app_name}';
  interfaceConfig.DEFAULT_REMOTE_DISPLAY_NAME = '${display_name}';
  interfaceConfig.BRAND_WATERMARK_LINK = '${brand_link}';
  interfaceConfig.JITSI_WATERMARK_LINK = '${jitsi_link}';
  interfaceConfig.DEFAULT_LOGO_URL = '${logo_url}';
  interfaceConfig.DEFAULT_WELCOME_PAGE_LOGO_URL = '${welcome_logo}';
  interfaceConfig.PROVIDER_NAME = '${provider_name}';
  interfaceConfig.SHOW_BRAND_WATERMARK = ${show_brand};
  interfaceConfig.SHOW_JITSI_WATERMARK = ${show_jitsi};
  interfaceConfig.DEFAULT_BACKGROUND = '${bg_default}';
})();
EOF
echo "    Written."

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 7 — Update docker-compose.yml volume mounts
#
#  Docker Compose bind-mounts make host files visible inside the container.
#  We inject our custom files here so the Nginx web server serves them instead
#  of the originals baked into the Docker image.
#
#  HOW THE INJECTION WORKS:
#    The stock docker-compose.yml always ends the web service volumes block with
#    the load-test line. We use that as an anchor and insert our mounts after it.
#    On re-runs the script checks whether a container path is already present in
#    the file and skips it — so mounts are never duplicated.
#
#  MOUNTED FILES AND WHY:
#    favicon.svg          — custom browser tab icon
#    watermark.svg        — custom meeting room logo
#    welcome-background.png — custom hero background (optional, skipped if absent)
#    all.css              — CSS overrides for colors and layout
#    title.html           — custom <title> and Open Graph tags
#    main.json            — i18n strings (covers non-EN locales)
#    main-en.json         — i18n strings for EN (XHR path: lang/main-{{lng}}.json)
#    app.bundle.min.js    — patched React bundle with custom EN text strings
#    app.bundle.min.js.map — source map (must accompany the bundle)
#
#  All mounts use :ro (read-only) since the container never needs to write back.
#
#  TO ADD A NEW MOUNT: add a tuple to the candidates list below following the
#  same (host_path, container_path) pattern.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> Updating docker-compose.yml volume mounts..."

# We insert custom mounts after the last default volume line in the web service.
# Anchor: the load-test mount is always last in the default compose file.
export COMPOSE_FILE CFG_DIR
python3 - <<'PYEOF'
import os, sys

compose_path = os.environ['COMPOSE_FILE']
cfg_dir      = os.environ['CFG_DIR']

with open(compose_path, 'r') as f:
    content = f.read()

# Files to potentially mount (host_path, container_path).
# Each entry is only added if the host file exists — so skipped images or a
# missing bundle don't produce broken mounts pointing at non-existent files.
candidates = [
    (f'{cfg_dir}/web/images/favicon.svg',           '/usr/share/jitsi-meet/images/favicon.svg'),
    (f'{cfg_dir}/web/images/watermark.svg',          '/usr/share/jitsi-meet/images/watermark.svg'),
    (f'{cfg_dir}/web/images/welcome-background.png', '/usr/share/jitsi-meet/images/welcome-background.png'),
    (f'{cfg_dir}/web/css/all.css',                   '/usr/share/jitsi-meet/css/all.css'),
    (f'{cfg_dir}/web/title.html',                    '/usr/share/jitsi-meet/title.html'),
    (f'{cfg_dir}/web/lang/main.json',                '/usr/share/jitsi-meet/lang/main.json'),
    (f'{cfg_dir}/web/lang/main-en.json',             '/usr/share/jitsi-meet/lang/main-en.json'),
    (f'{cfg_dir}/web/libs/app.bundle.min.js',         '/usr/share/jitsi-meet/libs/app.bundle.min.js'),
    (f'{cfg_dir}/web/libs/app.bundle.min.js.map',     '/usr/share/jitsi-meet/libs/app.bundle.min.js.map'),
]

# The anchor line we insert new mounts after. This is the last line in the
# default web service volumes block across all docker-jitsi-meet releases.
ANCHOR = '            - ${CONFIG}/web/load-test:/usr/share/jitsi-meet/load-test:Z\n'

new_mounts = []
for host, container in candidates:
    if not os.path.exists(host):
        continue                              # file not created yet — skip silently
    if container in content:
        print(f'    Already mounted: {container}')
        continue                              # already in compose — don't duplicate
    new_mounts.append(f'            - {host}:{container}:ro\n')

if not new_mounts:
    print('    No new mounts needed.')
    sys.exit(0)

if ANCHOR not in content:
    print('WARNING: Could not find anchor line in docker-compose.yml.', file=sys.stderr)
    print('         Add these mounts manually to the web service volumes section:', file=sys.stderr)
    for m in new_mounts:
        print(f'  {m.strip()}', file=sys.stderr)
    sys.exit(0)

# Insert our mounts on the line immediately after the anchor
content = content.replace(ANCHOR, ANCHOR + ''.join(new_mounts), 1)
with open(compose_path, 'w') as f:
    f.write(content)

print(f'    Added {len(new_mounts)} new mount(s) to docker-compose.yml.')
for m in new_mounts:
    print(f'      + {m.strip().split(":")[1]}')
PYEOF

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 8 — Restart containers
#
#  Volume mount changes in docker-compose.yml only take effect after a full
#  stop + start (not just restart/reload). We bring the entire stack down and
#  back up using the same compose file set as the install script:
#    docker-compose.yml  — core Jitsi services (web, prosody, jicofo, jvb)
#    etherpad.yml        — collaborative notepad
#    jibri.yml           — recording / live-streaming
#    whiteboard.yml      — collaborative whiteboard
#
#  Say N to skip the restart (e.g. you want to review the compose file first).
# ═══════════════════════════════════════════════════════════════════════════════
read -rp "Restart containers now to apply all changes? [Y/n]: " ans_restart
if [[ ! "$ans_restart" =~ ^[Nn]$ ]]; then
  cd "$INSTALL_DIR"
  echo "==> Stopping containers..."
  docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml down
  echo "==> Starting containers..."
  docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml up -d
  echo "==> Containers restarted."
fi

echo ""
echo "==> Jitsi Meet modifications applied."
echo "    Site        : https://$domain"
echo "    Config dir  : $CFG_DIR"
echo ""
echo "    Re-run this script at any time to update branding, colors, or images."
echo ""
echo "    Tip — verify overrides are active:"
echo "      docker compose exec web grep 'JITSI CUSTOM' /usr/share/jitsi-meet/css/all.css"
echo "      docker compose exec web cat /usr/share/jitsi-meet/title.html"
