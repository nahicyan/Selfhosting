#!/bin/bash
set -euo pipefail
# =============================================================================
# Cal.diy auto-cancel installer
# =============================================================================
# Cancels a booking automatically, with a stated reason, when the answer to a
# number question is above a limit. Cal.diy has no such setting (no Workflows
# in this fork, and a Number question has no maximum), so this adds a small
# receiver next to Cal.diy:
#
#   booking made -> Cal.diy sends a signed webhook -> cal-auto-cancel.py checks
#   the answer -> if above the limit, it cancels through Cal.diy's own
#   /api/cancel endpoint -> Cal.diy emails the reason to the attendee.
#
# The receiver runs as one more service in the existing Cal.diy Compose
# project, so it needs no public URL, Nginx block or certificate: Cal.diy
# reaches it at http://auto-cancel:8787 on the project's private network, and it
# reaches Cal.diy at http://calcom:3000. Nothing is published on the host.
#
# What this script adds to <install-dir> (it does not touch docker-compose.yml
# or .env, so cal-docker-install.sh's edits stay as they are):
#
#   docker-compose.override.yml   the auto-cancel service. Compose merges it
#                                 into docker-compose.yml on its own, so the
#                                 usual `docker compose up -d` includes it.
#   auto-cancel.env               WEBHOOK_SECRET, FIELD, MAX_VALUE (mode 600)
#   auto-cancel/                  mounted read-only into the container:
#     cal-auto-cancel.py            the receiver
#     reason.txt                    the cancellation reason; edit it any time,
#                                   it is read on every cancellation
#
# Re-running the script reconfigures it and keeps the existing webhook secret.
# cal-auto-cancel-uninstall.sh removes everything it adds.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIVER_SRC="$SCRIPT_DIR/cal-auto-cancel.py"

DEFAULT_BASE="/var/www/docker/cal"
PY_IMAGE="python:3.13-slim"
MARKER="# Managed by cal-auto-cancel-install.sh"

# What Cal.diy generates as the Identifier for the question labelled
# "What is your expected hourly rate ($ USD)?": every character that is not a
# letter, digit, - or _ becomes "-", trailing dashes are dropped. The real
# value is shown under Advanced > Booking questions, so check it there.
DEFAULT_FIELD="What-is-your-expected-hourly-rate----USD"
DEFAULT_MAX="14"
DEFAULT_REASON="Sorry, you are unaffordable for us. But we wish you best of luck. Thank you."

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in docker openssl install grep cut; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot reach the Docker daemon - is it running, and is this user allowed to use it?"
[ -f "$RECEIVER_SRC" ] || _die "cal-auto-cancel.py not found at $RECEIVER_SRC"

echo ""
echo "=====> Cal.diy auto-cancel"
echo "========================================"
echo ""

# ── 1. Which Cal.diy ──────────────────────────────────────────────────────────
read -rp "Domain of the Cal.diy install (e.g. cal.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"

read -rp "Install directory [$DEFAULT_BASE/$domain]: " answer
INSTALL_DIR="${answer:-$DEFAULT_BASE/$domain}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
INSTALL_DIR="${INSTALL_DIR%/}"
[[ "$INSTALL_DIR" = /* ]] || _die "Install directory must be an absolute path."
[ -f "$INSTALL_DIR/docker-compose.yml" ] || _die "$INSTALL_DIR/docker-compose.yml not found - is Cal.diy installed there (cal-docker-install.sh)?"
[ -w "$INSTALL_DIR" ] || _die "$INSTALL_DIR is not writable by this user."

cd "$INSTALL_DIR"
docker compose config --services 2>/dev/null | grep -qx calcom \
  || _die "no 'calcom' service in $INSTALL_DIR/docker-compose.yml (or the file does not validate)."

OVERRIDE="$INSTALL_DIR/docker-compose.override.yml"
ENV_FILE="$INSTALL_DIR/auto-cancel.env"
APP_DIR="$INSTALL_DIR/auto-cancel"
if [ -e "$OVERRIDE" ] && ! grep -qxF "$MARKER" "$OVERRIDE"; then
  _die "$OVERRIDE already exists and was not made by this script - add the auto-cancel service to it by hand (see this script's header)."
fi

# ── 2. The rule ───────────────────────────────────────────────────────────────
echo ""
echo "The booking question to check, by its Identifier (Cal.diy: event type >"
echo "Advanced > Booking questions > open the question > Identifier)."
read -rp "Question identifier [$DEFAULT_FIELD]: " answer
field="${answer:-$DEFAULT_FIELD}"
[[ "$field" =~ ^[A-Za-z0-9_-]+$ ]] || _die "'$field' is not a valid identifier (letters, digits, - and _ only)."

echo ""
read -rp "Cancel when the answer is greater than [$DEFAULT_MAX]: " answer
max_value="${answer:-$DEFAULT_MAX}"
[[ "$max_value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _die "'$max_value' is not a number."

echo ""
echo "The reason sent to the attendee in the cancellation email."
echo "{value} and {max} are replaced by their answer and the limit."
read -rp "Reason [$DEFAULT_REASON]: " answer
reason="${answer:-$DEFAULT_REASON}"

# The webhook secret survives a re-run, so the webhook in Cal.diy stays valid.
secret=""
if [ -f "$ENV_FILE" ]; then
  secret="$(grep -m1 '^WEBHOOK_SECRET=' "$ENV_FILE" | cut -d= -f2- || true)"
fi
if [[ -n "$secret" ]]; then secret_note="kept from the previous run"; else secret="$(openssl rand -hex 32)"; secret_note="generated"; fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Cal.diy         : $INSTALL_DIR"
echo "Question        : $field"
echo "Cancel when     : answer > $max_value"
echo "Reason          : $reason"
echo "Webhook secret  : $secret_note"
echo "Receiver        : service 'auto-cancel' ($PY_IMAGE), http://auto-cancel:8787 inside the stack"
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Write ─────────────────────────────────────────────────────────────────────
had_override=false; [ -e "$OVERRIDE" ] && had_override=true
mkdir -p "$APP_DIR"
chmod 755 "$APP_DIR"
install -m 644 "$RECEIVER_SRC" "$APP_DIR/cal-auto-cancel.py"
printf '%s\n' "$reason" > "$APP_DIR/reason.txt"
chmod 644 "$APP_DIR/reason.txt"

( umask 077; printf 'WEBHOOK_SECRET=%s\nFIELD=%s\nMAX_VALUE=%s\n' "$secret" "$field" "$max_value" > "$ENV_FILE" )
chmod 600 "$ENV_FILE"

# No ports: nothing is published. read_only/cap_drop/no-new-privileges and a
# non-root user keep a script that handles a secret as small as it can be.
cat > "$OVERRIDE" <<EOF
$MARKER
# Re-run that script to change the service.
services:
  auto-cancel:
    image: $PY_IMAGE
    restart: always
    command: ["python", "-u", "/app/cal-auto-cancel.py"]
    user: "65534:65534"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    env_file: ./auto-cancel.env
    environment:
      CAL_URL: http://calcom:3000
      BIND: 0.0.0.0
      REASON_FILE: /app/reason.txt
      PYTHONDONTWRITEBYTECODE: "1"
    volumes:
      - ./auto-cancel:/app:ro
    networks:
      - stack
    depends_on:
      - calcom
EOF

if ! docker compose config --quiet 2>/dev/null; then
  [[ "$had_override" == "true" ]] || rm -f "$OVERRIDE"
  _die "the compose files did not validate with the auto-cancel service added (is the 'stack' network still defined in docker-compose.yml?). Run 'docker compose config' in $INSTALL_DIR to see why."
fi

# ── Start ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Starting the receiver (pulls $PY_IMAGE the first time)"
docker compose up -d --force-recreate --no-deps auto-cancel   # always: a changed script is mounted, not part of the config Compose compares

echo "==> Waiting for the receiver"
up=false
for _ in $(seq 1 30); do
  if docker compose logs auto-cancel 2>/dev/null | grep -q "listening on"; then up=true; break; fi
  sleep 1
done
if [[ "$up" != "true" ]]; then
  docker compose logs --tail 20 auto-cancel >&2 || true
  _die "the receiver did not start - see its log above."
fi
docker compose logs --tail 1 auto-cancel

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Receiver running. One step is left, inside Cal.diy:"
echo ""
echo "    Event type > Webhooks tab > New webhook   (or Settings > Developer > Webhooks > Add webhook)"
echo "      Subscriber URL : http://auto-cancel:8787"
echo "      Event triggers : Booking created"
echo "                       Booking requested     (only if the event type needs confirmation)"
echo "      Secret         : $secret"
echo "      Enable webhook : on"
echo ""
echo "    Use the event type's own Webhooks tab so only that event type is checked."
echo "    The question must be of type Number and the event type must not be a seated event."
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Logs    : docker compose logs -f auto-cancel"
echo "    Reason  : edit $APP_DIR/reason.txt (no restart needed)"
echo "    Limit   : re-run this script"
echo "    Remove  : bash $SCRIPT_DIR/cal-auto-cancel-uninstall.sh"
