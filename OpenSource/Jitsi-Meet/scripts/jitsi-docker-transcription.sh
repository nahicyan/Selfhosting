#!/bin/bash
# jitsi-docker-transcription.sh — Enable AI transcription on selected meetings of a
# Jitsi Meet Docker install, using Jitsi's bridge-based transcription path.
#
# Architecture (replaces Jigasi transcription, which Jitsi has deprecated):
#
#   participant audio ──Opus──► JVB ──WebSocket──► opus-transcriber ──► OpenAI / Deepgram /
#                                                  (added by this script)  Gemini / xAI / self-hosted
#   captions in the meeting ◄── JVB ◄──── transcription-result ◄────────┘
#
# What it does (in order):
#   1. Asks where your Jitsi instances live and lets you pick one.
#   2. Asks whether to enable/update or disable AI transcription.
#   3. Prompts for the speech-to-text provider, API key and model.
#   4. Prompts for which meetings may be transcribed (room-name patterns) and
#      whether transcription starts by itself or waits for a moderator.
#   5. Writes the proxy settings to opus-transcriber/transcriber.env (chmod 600).
#   6. Injects an opus-transcriber service into docker-compose.yml, so the start/stop
#      commands from jitsi-docker-install.sh and jitsi-docker-mod.sh pick it up as-is.
#   7. Writes the Prosody module mod_ai_transcription.lua and adds it to XMPP_MUC_MODULES.
#   8. Writes the jicofo.transcription block into jicofo/custom-jicofo.conf.
#   9. Writes the config.transcription block into web/custom-config.js.
#  10. Optionally restarts the containers so everything takes effect.
#
# HOW "SELECTED MEETINGS" WORKS:
#   Jicofo starts transcription only when the room metadata has BOTH
#     asyncTranscription = true               — a server-only key; clients cannot set it.
#                                               mod_ai_transcription sets it on rooms that
#                                               match your patterns, and on no other room.
#     recording.isTranscribingEnabled = true  — set when a moderator starts subtitles /
#                                               transcription, or by mod_ai_transcription
#                                               itself when auto-start is on.
#   In rooms that do not match, mod_ai_transcription also switches off the
#   'transcription' permission sent to moderators, so the client hides the button.
#   Only moderators can start it (with AUTH_TYPE=internal: your logged-in users).
#   While a meeting is transcribed the clients leave peer-to-peer mode, so the
#   bridge also gets the audio of two-person calls.
#
# Re-running is safe — current values are shown as defaults, and every managed
# block is marked and replaced in place.
#
# Options (used by jitsi-docker-install.sh; run without options for the menus):
#   --install-dir DIR   use this instance and go straight to enable/update
#   --no-restart        skip the image pull and restart (the caller starts the stack)
#
# Key files this script manages:
#   $CFG_DIR/opus-transcriber/transcriber.env                      — provider, API key, model
#   $CFG_DIR/prosody/prosody-plugins-custom/mod_ai_transcription.lua
#   $CFG_DIR/jicofo/custom-jicofo.conf                             — marked block
#   $CFG_DIR/web/custom-config.js                                  — marked block
#   $INSTALL_DIR/docker-compose.yml                                — marked opus-transcriber service
#   $INSTALL_DIR/.env                                              — marked block + XMPP_MUC_MODULES

set -euo pipefail

OPT_INSTALL_DIR=""
NO_RESTART=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) OPT_INSTALL_DIR="${2:?--install-dir needs a path}"; shift 2 ;;
    --no-restart) NO_RESTART=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Docker ────────────────────────────────────────────────────────────────────
# Checked before anything else: every step below runs through Docker.
command -v docker >/dev/null 2>&1 \
  || { echo "ERROR: Docker is not installed. Install Docker Engine (https://docs.docker.com/engine/install/), then run this script again."; exit 1; }
docker compose version >/dev/null 2>&1 \
  || { echo "ERROR: the Docker Compose plugin ('docker compose') is not installed. Install it (https://docs.docker.com/compose/install/linux/), then run this script again."; exit 1; }
docker info >/dev/null 2>&1 \
  || { echo "ERROR: cannot talk to Docker - is it running, and is $(id -un) in the docker group?"; exit 1; }

echo ""
echo "════════════════════════════════════════════════"
echo " Jitsi Meet — AI Transcription Script"
echo "════════════════════════════════════════════════"
echo ""

if [[ -n "$OPT_INSTALL_DIR" ]]; then
  [[ -d "$OPT_INSTALL_DIR" ]] || { echo "ERROR: Directory not found: $OPT_INSTALL_DIR"; exit 1; }
  INSTALL_DIR="$(cd "$OPT_INSTALL_DIR" && pwd)"
  domain="$(basename "$INSTALL_DIR")"
else

# ── 1. Choose base directory ──────────────────────────────────────────────────
# Same layout as jitsi-docker-install.sh: one subdirectory per domain.
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
echo ""
mapfile -t INSTANCES < <(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d \
  -exec test -f "{}/docker-compose.yml" \; -print | sort)

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
  echo "No Jitsi instances found in '$BASE_DIR'."
  echo "Run jitsi-docker-install.sh first."
  exit 1
fi

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
  if ! [[ "$_inst_num" =~ ^[0-9]+$ ]] || \
     [[ "$_inst_num" -lt 1 ]] || \
     [[ "$_inst_num" -gt "${#INSTANCES[@]}" ]]; then
    echo "Invalid selection."
    exit 1
  fi
  INSTALL_DIR="${INSTANCES[$((_inst_num-1))]}"
  domain="$(basename "$INSTALL_DIR")"
fi

fi  # --install-dir

# ── Path setup ────────────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }

COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || { echo "ERROR: docker-compose.yml not found at $COMPOSE_FILE"; exit 1; }

# Last CONFIG= line wins, as it does for Docker Compose.
CFG_DIR=$(grep "^CONFIG=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
CFG_DIR="${CFG_DIR:-$INSTALL_DIR/.jitsi-meet-cfg}"
[[ "$CFG_DIR" == ~* ]] && CFG_DIR="${HOME}${CFG_DIR#\~}"

TRANSCRIBER_DIR="$CFG_DIR/opus-transcriber"
TRANSCRIBER_ENV="$TRANSCRIBER_DIR/transcriber.env"                     # proxy settings + secrets
PROSODY_MODULE="$CFG_DIR/prosody/prosody-plugins-custom/mod_ai_transcription.lua"
JICOFO_CUSTOM="$CFG_DIR/jicofo/custom-jicofo.conf"                     # included by jicofo.conf
WEB_CUSTOM="$CFG_DIR/web/custom-config.js"                             # appended to config.js

# The same compose file set used by jitsi-docker-install.sh / jitsi-docker-mod.sh.
COMPOSE_ARGS=(-f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml)

mkdir -p "$TRANSCRIBER_DIR" "$(dirname "$PROSODY_MODULE")" "$CFG_DIR/jicofo" "$CFG_DIR/web"

echo ""
echo "==> Installation : $INSTALL_DIR"
echo "==> Config dir   : $CFG_DIR"
echo ""

# ── Helper functions ──────────────────────────────────────────────────────────

# ask <prompt> <default>
# Prints the user's input, or <default> if they just pressed Enter.
ask() {
  local prompt="$1" default="$2" result
  read -rp "$prompt [$default]: " result
  printf '%s' "${result:-$default}"
}

# ask_yn <prompt> <default true|false>
# Prints true or false.
ask_yn() {
  local prompt="$1" default="$2" hint result
  [[ "$default" == "true" ]] && hint="Y/n" || hint="y/N"
  read -rp "$prompt [$hint]: " result
  result="${result:-$([[ "$default" == "true" ]] && echo y || echo n)}"
  [[ "$result" =~ ^[Yy] ]] && printf 'true' || printf 'false'
}

# env_get <file> <key>
# Prints the value of KEY=value from an env file, or nothing.
env_get() {
  [[ -f "$1" ]] && grep -m1 "^$2=" "$1" | cut -d= -f2- || true
}

# edit_block <upsert|remove> <file> <comment-prefix> [body] [anchor-regex]
# Manages a block delimited by
#   <prefix> === AI TRANSCRIPTION (jitsi-docker-transcription.sh) ===
#   <prefix> === END AI TRANSCRIPTION ===
# upsert puts <body> back where the old block was, otherwise in front of the line
# matching <anchor-regex> (and the comments/blank lines just above it), otherwise
# at the end of the file. remove deletes the block. Everything else is untouched.
edit_block() {
  python3 - "$@" <<'PYEOF'
import os, re, sys

action, path, prefix = sys.argv[1:4]
body = sys.argv[4] if len(sys.argv) > 4 else ''
anchor = sys.argv[5] if len(sys.argv) > 5 else ''

begin = f'{prefix} === AI TRANSCRIPTION (jitsi-docker-transcription.sh) ==='
end = f'{prefix} === END AI TRANSCRIPTION ==='

if action == 'remove' and not os.path.exists(path):
    sys.exit(0)

text = open(path).read() if os.path.exists(path) else ''

pos = None
start = text.find(begin)
if start != -1:
    stop = text.find(end, start)
    if stop == -1:
        sys.exit(f'ERROR: {path} has the start marker but no end marker — fix it by hand.')
    start = text.rfind('\n', 0, start) + 1        # beginning of the start-marker line
    stop = text.find('\n', stop)
    stop = len(text) if stop == -1 else stop + 1  # just past the end-marker line
    text = text[:start] + text[stop:]
    pos = start

if action == 'upsert':
    block = f'{begin}\n{body.rstrip()}\n{end}\n'
    if pos is None and anchor:
        m = re.search(anchor, text, re.M)
        if not m:
            sys.exit(f'ERROR: could not find where to insert the block in {path}.')
        pos = m.start()
        # Step back over the comments and blank lines that introduce the anchor.
        while pos > 0:
            prev = text.rfind('\n', 0, pos - 1) + 1
            line = text[prev:pos].strip()
            if line and not line.startswith('#'):
                break
            pos = prev
    if pos is None:
        text = text.rstrip('\n') + ('\n\n' if text.strip() else '') + block
    else:
        text = text[:pos] + block + text[pos:]
elif pos is not None and pos >= len(text.rstrip('\n')):
    text = text.rstrip('\n') + '\n' if text.strip() else ''

with open(path, 'w') as f:
    f.write(text)
PYEOF
}

# muc_modules <enable|disable>
# Adds/removes ai_transcription in an XMPP_MUC_MODULES line that you maintain
# yourself in .env (outside this script's block). Prints 'present' if such a
# line exists, 'absent' otherwise — then the script's own block carries it.
muc_modules() {
  MUC_ACTION="$1" ENV_FILE="$ENV_FILE" python3 - <<'PYEOF'
import os, re

path = os.environ['ENV_FILE']
enable = os.environ['MUC_ACTION'] == 'enable'

with open(path) as f:
    text = f.read()

m = re.search(r'^XMPP_MUC_MODULES=(.*)$', text, re.M)
if not m:
    print('absent')
else:
    mods = [x.strip() for x in m.group(1).split(',') if x.strip() and x.strip() != 'ai_transcription']
    if enable:
        mods.append('ai_transcription')
    text = text[:m.start()] + 'XMPP_MUC_MODULES=' + ','.join(mods) + text[m.end():]
    with open(path, 'w') as f:
        f.write(text)
    print('present')
PYEOF
}

# restart_stack
# Full down + up — required because .env and docker-compose.yml changed.
restart_stack() {
  read -rp "Restart containers now to apply all changes? (active meetings will drop) [Y/n]: " ans_restart
  if [[ ! "$ans_restart" =~ ^[Nn]$ ]]; then
    cd "$INSTALL_DIR"
    echo "==> Stopping containers..."
    docker compose "${COMPOSE_ARGS[@]}" down
    echo "==> Starting containers..."
    docker compose "${COMPOSE_ARGS[@]}" up -d
    echo "==> Containers restarted."
  fi
}

# ── Choose action ─────────────────────────────────────────────────────────────
if [[ -n "$OPT_INSTALL_DIR" ]]; then
  _action=1  # enable/update
else
  echo "What would you like to do?"
  echo "  1) Enable or update AI transcription"
  echo "  2) Disable AI transcription"
  read -rp "Select [1/2]: " _action
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  DISABLE — remove every managed block, the Prosody module and the proxy service.
#  transcriber.env (your API key) is kept unless you ask for it to be deleted.
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$_action" == "2" ]]; then
  # Stop the proxy while it is still defined in docker-compose.yml; once the
  # service is gone, compose would treat the container as an orphan and
  # 'down' could not remove the meet.jitsi network.
  if grep -q "opus-transcriber:" "$COMPOSE_FILE"; then
    echo "==> Stopping the opus-transcriber container..."
    (cd "$INSTALL_DIR" && docker compose "${COMPOSE_ARGS[@]}" rm -sf opus-transcriber) || true
  fi

  edit_block remove "$COMPOSE_FILE" "    #"
  edit_block remove "$ENV_FILE" "#"
  edit_block remove "$JICOFO_CUSTOM" "#"
  edit_block remove "$WEB_CUSTOM" "//"
  muc_modules disable > /dev/null
  rm -f "$PROSODY_MODULE"
  echo "==> Removed AI transcription from docker-compose.yml, .env, custom-jicofo.conf,"
  echo "    custom-config.js and the Prosody plugins directory."

  if [[ -f "$TRANSCRIBER_ENV" ]]; then
    read -rp "Also delete $TRANSCRIBER_ENV (contains your API key)? [y/N]: " ans_del
    [[ "$ans_del" =~ ^[Yy]$ ]] && rm -f "$TRANSCRIBER_ENV" && echo "    Deleted."
  fi

  echo ""
  restart_stack
  echo ""
  echo "==> AI transcription disabled for https://$domain"
  exit 0
fi

[[ "$_action" == "1" ]] || { echo "Invalid selection."; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 1 — Speech-to-text provider
#
#  The proxy (jitsi/opus-transcriber-proxy) decodes each participant's Opus audio
#  and streams it to one of these backends. Only the provider you pick gets a key.
#
#  Option 5 is for a model you host yourself that speaks the OpenAI Realtime
#  transcription WebSocket protocol (no audio leaves your infrastructure). The
#  proxy does not read that URL/key from its env: jicofo hands them to the bridge
#  per conference (provider=openai_custom&openaiCustomUrl=... plus the
#  X-Custom-Openai-Api-Key header), so they end up in custom-jicofo.conf.
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 1 — Speech-to-text provider"
echo "══════════════════════════════════════════════════════"
echo ""

case "$(env_get "$TRANSCRIBER_ENV" PROVIDERS_PRIORITY)" in
  deepgram) _prov_default=2 ;;
  gemini) _prov_default=3 ;;
  xai) _prov_default=4 ;;
  openai_custom) _prov_default=5 ;;
  *) _prov_default=1 ;;
esac

echo "  1) OpenAI (realtime transcription)"
echo "  2) Deepgram"
echo "  3) Google Gemini"
echo "  4) xAI"
echo "  5) Self-hosted OpenAI-compatible realtime endpoint"
_prov=$(ask "Select provider" "$_prov_default")

custom_url=""
case "$_prov" in
  1) provider=openai;        key_var=OPENAI_API_KEY;        model_var=OPENAI_MODEL;   model_default=gpt-4o-mini-transcribe ;;
  2) provider=deepgram;      key_var=DEEPGRAM_API_KEY;      model_var=DEEPGRAM_MODEL; model_default=nova-2 ;;
  3) provider=gemini;        key_var=GEMINI_API_KEY;        model_var=GEMINI_MODEL;   model_default=gemini-2.0-flash-exp ;;
  4) provider=xai;           key_var=XAI_API_KEY;           model_var="";             model_default="" ;;
  5) provider=openai_custom; key_var=CUSTOM_OPENAI_API_KEY; model_var=OPENAI_MODEL;   model_default=gpt-4o-mini-transcribe ;;
  *) echo "Invalid selection."; exit 1 ;;
esac

if [[ "$provider" == "openai_custom" ]]; then
  cur_url=$(env_get "$TRANSCRIBER_ENV" CUSTOM_OPENAI_URL)
  custom_url=$(ask "Realtime WebSocket URL of your endpoint" "${cur_url:-wss://stt.example.com/v1/realtime?intent=transcription}")
  [[ "$custom_url" =~ ^wss?://[^[:space:]\"]+$ ]] || { echo "ERROR: URL must start with ws:// or wss://"; exit 1; }
fi

# The key is read silently. On re-runs, Enter keeps the stored one.
cur_key=$(env_get "$TRANSCRIBER_ENV" "$key_var")
if [[ -n "$cur_key" ]]; then
  _key_hint="Enter keeps ****${cur_key: -4}"
elif [[ "$provider" == "openai_custom" ]]; then
  _key_hint="any value if your endpoint has no auth"
else
  _key_hint="required"
fi
read -rsp "API key ($_key_hint): " api_key
echo ""
api_key="${api_key:-$cur_key}"
[[ -n "$api_key" ]] || { echo "ERROR: An API key is required."; exit 1; }
[[ "$api_key" =~ ^[A-Za-z0-9._:/+=-]+$ ]] || { echo "ERROR: The API key contains unexpected characters."; exit 1; }

model=""
if [[ -n "$model_var" ]]; then
  cur_model=$(env_get "$TRANSCRIBER_ENV" "$model_var")
  model=$(ask "Model" "${cur_model:-$model_default}")
  [[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "ERROR: Invalid model name."; exit 1; }
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 2 — Which meetings
#
#  Room names or patterns, comma-separated. '*' is a wildcard. Matching is on the
#  room name only (the part after the domain in the meeting URL), lowercase.
#    *              every meeting (still opt-in per meeting unless auto-start is on)
#    board,*-ai     only the room 'board' and rooms ending in '-ai'
#  Breakout rooms are not transcribed.
# ═══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════"
echo " Section 2 — Which meetings"
echo " Room names or patterns, comma-separated; '*' is a"
echo " wildcard.  e.g.  *   or   board,weekly-sync,*-ai"
echo "══════════════════════════════════════════════════════"
echo ""

cur_rooms=$(env_get "$ENV_FILE" AI_TRANSCRIPTION_ROOMS)
rooms=$(ask "Meetings that may be transcribed" "${cur_rooms:-*}")
rooms=$(printf '%s' "$rooms" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
[[ "$rooms" =~ ^[a-z0-9*._-]+(,[a-z0-9*._-]+)*$ ]] || \
  { echo "ERROR: Use letters, digits, '.', '_', '-' and '*' only, separated by commas."; exit 1; }

echo ""
echo "    Auto-start: transcription runs from the moment a selected meeting begins."
echo "    Otherwise a moderator starts it with the subtitles (CC) button."
auto_start=$(ask_yn "Auto-start transcription in the selected meetings?" \
  "$(env_get "$ENV_FILE" AI_TRANSCRIPTION_AUTO_START | grep -qx true && echo true || echo false)")

if [[ "$auto_start" == "true" && ",$rooms," == *",*,"* ]]; then
  echo "    WARNING: '*' with auto-start transcribes EVERY meeting on this server,"
  echo "             and the provider bills for all of it."
fi

echo ""
interim=$(ask_yn "Show interim captions (words appear while people are still speaking)?" \
  "$(env_get "$ENV_FILE" AI_TRANSCRIPTION_INTERIM | grep -qx true && echo true || echo false)")

# Passed to the provider as-is (OpenAI wants ISO-639-1), so two letters only.
cur_lang=$(env_get "$ENV_FILE" AI_TRANSCRIPTION_LANG)
read -rp "Spoken-language hint, two letters e.g. en or de ('-' = auto-detect) [${cur_lang:--}]: " lang
lang="${lang:-$cur_lang}"
[[ "$lang" == "-" ]] && lang=""
[[ -z "$lang" || "$lang" =~ ^[a-z]{2}$ ]] || { echo "ERROR: Use a two-letter language code."; exit 1; }

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 3 — Proxy settings (transcriber.env)
#
#  Passed to the opus-transcriber container via env_file. chmod 600 because it
#  holds the API key. This file is owned by the script: it is rewritten on every
#  run. See the proxy's README.md / BACKENDS.md for further variables.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Writing $TRANSCRIBER_ENV..."
{
  echo "# Managed by jitsi-docker-transcription.sh — re-run the script to change."
  echo "# Settings for jitsi/opus-transcriber-proxy (see its README.md / BACKENDS.md)."
  echo "PORT=8080"
  echo "# The image ships both Opus decoders; native (libopus) is the faster one."
  echo "OPUS_BACKEND=native"
  echo "PROVIDERS_PRIORITY=$provider"
  if [[ "$provider" == "openai_custom" ]]; then
    echo "ENABLE_OPENAI_CUSTOM_PROVIDER=true"
    [[ "$custom_url" == ws://* ]] && echo "OPENAI_CUSTOM_REQUIRE_WSS=false"
    echo "OPENAI_MODEL=$model"
    echo "# Not read by the proxy: jicofo sends these to the bridge (custom-jicofo.conf)."
    echo "# Kept here so re-runs can show them as defaults."
    echo "CUSTOM_OPENAI_URL=$custom_url"
    echo "CUSTOM_OPENAI_API_KEY=$api_key"
  else
    echo "$key_var=$api_key"
    [[ -n "$model_var" ]] && echo "$model_var=$model"
  fi
} > "$TRANSCRIBER_ENV"
chmod 600 "$TRANSCRIBER_ENV"
echo "    Written (chmod 600)."

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 4 — opus-transcriber service in docker-compose.yml
#
#  Injected into docker-compose.yml itself (not a separate overlay file) so the
#  existing 'docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml
#  -f whiteboard.yml ...' commands start and stop it too.
#
#  The service is not called 'transcriber': that name belongs to the Jigasi
#  transcriber in the release's transcriber.yml.
#
#  The JVB reaches it at ws://opus-transcriber.meet.jitsi:8080 on the internal
#  meet.jitsi network. Port 8080 is also published on 127.0.0.1 only (default
#  9095, 9090 is taken by prometheus.yml) for local testing with wscat.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Updating docker-compose.yml..."
edit_block upsert "$COMPOSE_FILE" "    #" "$(cat <<'EOF'
    # Bridge-based transcription proxy — the JVB streams each participant's Opus
    # audio here; the text goes back to the meeting through the JVB.
    opus-transcriber:
        image: ${OPUS_TRANSCRIBER_IMAGE:-jitsi/opus-transcriber-proxy:latest}
        restart: ${RESTART_POLICY:-unless-stopped}
        env_file:
            - ${CONFIG}/opus-transcriber/transcriber.env
        environment:
            - TZ
        ports:
            - '127.0.0.1:${OPUS_TRANSCRIBER_PORT:-9095}:8080'
        healthcheck:
            test: ['CMD', 'wget', '-qO-', 'http://127.0.0.1:8080/health']
            interval: 30s
            timeout: 5s
            retries: 3
        networks:
            meet.jitsi:
                aliases:
                    - opus-transcriber.meet.jitsi
EOF
)" '^networks:'
echo "    opus-transcriber service in place."

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 5 — .env
#
#  The settings block is what this script reads back as defaults on re-runs;
#  OPUS_TRANSCRIBER_IMAGE / _PORT are also used by the compose service above.
#
#  XMPP_MUC_MODULES loads mod_ai_transcription on the main MUC component. If you
#  already keep an XMPP_MUC_MODULES line yourself, ai_transcription is added to it
#  in place; otherwise the line lives in this script's block.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Updating .env..."
# Keep a pinned image tag or a changed port across re-runs.
image=$(env_get "$ENV_FILE" OPUS_TRANSCRIBER_IMAGE)
port=$(env_get "$ENV_FILE" OPUS_TRANSCRIBER_PORT)
port="${port:-9095}"

edit_block remove "$ENV_FILE" "#"
muc_state=$(muc_modules enable)

env_body="AI_TRANSCRIPTION_ROOMS=$rooms
AI_TRANSCRIPTION_AUTO_START=$auto_start
AI_TRANSCRIPTION_INTERIM=$interim
AI_TRANSCRIPTION_LANG=$lang
# Pin a tag from hub.docker.com/r/jitsi/opus-transcriber-proxy/tags for reproducible upgrades.
OPUS_TRANSCRIBER_IMAGE=${image:-jitsi/opus-transcriber-proxy:latest}
OPUS_TRANSCRIBER_PORT=$port"
[[ "$muc_state" == "absent" ]] && env_body+=$'\n'"XMPP_MUC_MODULES=ai_transcription"
edit_block upsert "$ENV_FILE" "#" "$env_body"
echo "    Written (XMPP_MUC_MODULES: $([[ "$muc_state" == "present" ]] && echo "your existing line" || echo "script block"))."

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 6 — Prosody module (mod_ai_transcription.lua)
#
#  Lives in prosody-plugins-custom, which is first on Prosody's plugin_paths.
#  The room list and auto-start flag are written into the top of the file.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Writing $PROSODY_MODULE..."

# board,*-ai  →  "board", "*-ai"
lua_rooms=$(printf '%s' "$rooms" | sed 's/[^,]*/"&"/g; s/,/, /g')

cat > "$PROSODY_MODULE" <<EOF
-- mod_ai_transcription.lua
-- Generated by jitsi-docker-transcription.sh — re-run the script to change the settings below.
--
-- Decides, per room, whether bridge-based AI transcription may run. Jicofo only
-- starts transcription when the room metadata has both
--   asyncTranscription = true               (server-only key, set here)
--   recording.isTranscribingEnabled = true  (set by a moderator, or here on auto-start)
--
-- Rooms that do not match ROOMS never get asyncTranscription, and the
-- 'transcription' permission sent to their moderators is switched off so the
-- client hides the button.
--
-- Loaded on the main MUC component through XMPP_MUC_MODULES.

local ROOMS = { ${lua_rooms} };   -- room-name globs, '*' matches anything
local AUTO_START = ${auto_start};  -- start transcribing as soon as a selected room is created

EOF

cat >> "$PROSODY_MODULE" <<'EOF'
local filters = require 'util.filters';
local jid = require 'util.jid';

local util = module:require 'util';
local is_healthcheck_room = util.is_healthcheck_room;
local get_room_from_jid = util.get_room_from_jid;
local room_jid_match_rewrite = util.room_jid_match_rewrite;

-- Each glob becomes an anchored Lua pattern: magic characters are escaped,
-- then '*' becomes '.*'.
local patterns = {};
local all_rooms = false;
for _, glob in ipairs(ROOMS) do
    if glob == '*' then
        all_rooms = true;
    end
    local escaped = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0');
    table.insert(patterns, '^'..escaped:gsub('%*', '.*')..'$');
end

local function is_selected(room)
    if all_rooms then
        return true;
    end

    -- The node is '[tenant]room' when subdomains are used; match on the room name only.
    local name = (jid.node(room.jid) or ''):gsub('^%[.-%]', ''):lower();

    for _, pattern in ipairs(patterns) do
        if name:match(pattern) then
            return true;
        end
    end

    return false;
end

-- Priority -2: after mod_room_metadata_component (-1), which creates room.jitsiMetadata.
module:hook('muc-room-created', function(event)
    local room = event.room;

    if is_healthcheck_room(room.jid) or not is_selected(room) then
        return;
    end

    room.jitsiMetadata = room.jitsiMetadata or {};
    room.jitsiMetadata.asyncTranscription = true;

    if AUTO_START then
        room.jitsiMetadata.recording = { isTranscribingEnabled = true };
    end

    module:log('info', 'AI transcription %s for room %s',
        AUTO_START and 'auto-started' or 'available', room.jid);
end, -2);

-- Rooms not selected: switch off the 'transcription' permission that
-- mod_jitsi_permissions puts in a moderator's self-presence.
local function filter_stanza(stanza)
    if stanza.name ~= 'presence' or not stanza.attr or not stanza.attr.from
            or stanza.attr.type == 'unavailable' then
        return stanza;
    end

    local permissions = stanza:get_child('permissions', 'http://jitsi.org/jitmeet');
    if not permissions then
        return stanza;
    end

    local room = get_room_from_jid(room_jid_match_rewrite(jid.bare(stanza.attr.from)));
    if not room or is_selected(room) then
        return stanza;
    end

    for p in permissions:childtags('p') do
        if p.attr.name == 'transcription' then
            p.attr.val = 'false';
        end
    end

    return stanza;
end

local function filter_session(session)
    -- mod_jitsi_permissions adds <permissions> at priority -2, so run after it.
    filters.add_filter(session, 'stanzas/out', filter_stanza, -3);
end

if not all_rooms then
    filters.add_filter_hook(filter_session);

    function module.unload()
        filters.remove_filter_hook(filter_session);
    end
end
EOF
# Prosody runs as uid 1000 (stable-11146+); readable whatever the umask.
chmod 644 "$PROSODY_MODULE"
echo "    Written (rooms: $rooms, auto-start: $auto_start)."

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 7 — Jicofo (custom-jicofo.conf)
#
#  jicofo.conf ends with include "custom-jicofo.conf", and that file is copied
#  as-is (not run through the image's templating), so {{MEETING_ID}} survives
#  for jicofo to fill in. Jicofo hands the URL (and any headers) to the JVB,
#  which opens the WebSocket.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Updating $JICOFO_CUSTOM..."

url="ws://opus-transcriber.meet.jitsi:8080/transcribe?sessionId={{MEETING_ID}}&sendBack=true"
[[ "$interim" == "true" ]] && url+="&sendBackInterim=true"
[[ -n "$lang" ]] && url+="&lang=$lang"
if [[ "$provider" == "openai_custom" ]]; then
  enc_url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$custom_url")
  url+="&provider=openai_custom&openaiCustomUrl=$enc_url"
fi

jicofo_body="jicofo.transcription {
  url-template = \"$url\"
  ping {
    enabled = true
    interval = 10 seconds
    timeout = 3 seconds
  }"
if [[ "$provider" == "openai_custom" ]]; then
  jicofo_body+="
  http-headers {
    \"X-Custom-Openai-Api-Key\" = \"$api_key\"
  }"
fi
jicofo_body+="
}"
edit_block upsert "$JICOFO_CUSTOM" "#" "$jicofo_body"
# Jicofo copies /config as uid 1000 (rootless images, stable-11146+), so the file
# must be readable by that uid. With the custom endpoint's key in it, it goes to
# uid 1000 alone instead of being world-readable.
if [[ "$provider" == "openai_custom" ]]; then
  chown 1000:1000 "$JICOFO_CUSTOM" 2>/dev/null || sudo chown 1000:1000 "$JICOFO_CUSTOM"
  chmod 600 "$JICOFO_CUSTOM" 2>/dev/null || sudo chmod 600 "$JICOFO_CUSTOM"
else
  chmod 644 "$JICOFO_CUSTOM" 2>/dev/null || sudo chmod 644 "$JICOFO_CUSTOM"
fi
echo "    Written."

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 8 — Web client (custom-config.js)
#
#  Turns on the transcription / closed-caption UI. The env-generated config.js
#  sets disableClosedCaptions: true while ENABLE_TRANSCRIPTIONS is off (that
#  variable is for Jigasi and stays off), so it is overridden here.
#  This cannot pick rooms: the web app evaluates config.js once per page load,
#  not per meeting, so the per-room choice is made by mod_ai_transcription.
# ═══════════════════════════════════════════════════════════════════════════════
echo "==> Updating $WEB_CUSTOM..."
edit_block upsert "$WEB_CUSTOM" "//" "$(cat <<'EOF'
(function () {
  if (typeof config === 'undefined') return;
  config.transcription = config.transcription || {};
  config.transcription.enabled = true;
  config.transcription.disableClosedCaptions = false;
  // Show captions to everyone as soon as transcription starts.
  config.transcription.autoCaptionOnTranscribe = true;
})();
EOF
)"
echo "    Written."

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 9 — Restart containers
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$NO_RESTART" == "true" ]]; then
  echo "==> AI transcription configured — it starts with the rest of the stack."
  exit 0
fi

if read -rp "Pull the opus-transcriber image now? [Y/n]: " ans_pull && [[ ! "$ans_pull" =~ ^[Nn]$ ]]; then
  (cd "$INSTALL_DIR" && docker compose "${COMPOSE_ARGS[@]}" pull opus-transcriber) \
    || echo "    WARNING: Pull failed — 'up' will try again."
fi
restart_stack

echo ""
echo "==> AI transcription configured."
echo "    Site        : https://$domain"
echo "    Provider    : $provider${model:+ ($model)}"
echo "    Meetings    : $rooms"
echo "    Auto-start  : $auto_start"
echo ""
if [[ "$auto_start" == "true" ]]; then
  echo "    Selected meetings are transcribed from the start; a moderator can stop it from the CC menu."
else
  echo "    In a selected meeting, a moderator clicks the subtitles (CC) button / 'Start subtitles'."
fi
echo "    Transcription is not available while end-to-end encryption is on."
echo ""
echo "    Verify (from $INSTALL_DIR):"
echo "      docker compose logs -f opus-transcriber"
echo "      docker compose logs prosody | grep -i 'ai transcription'"
echo "      docker compose logs jicofo | grep -i transcri"
echo "      docker compose logs jvb | grep -i transcri"
echo "      wscat -c 'ws://127.0.0.1:$port/transcribe?sessionId=test&sendBack=true'"
echo ""
echo "    Re-run this script to change rooms, provider or key, or to disable it."
echo ""
