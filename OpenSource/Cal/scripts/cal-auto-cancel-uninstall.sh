#!/bin/bash
set -euo pipefail
# =============================================================================
# Cal.diy auto-cancel uninstaller
# =============================================================================
# Removes what cal-auto-cancel-install.sh added to a Cal.diy install:
#
#   - the auto-cancel container (stopped, then removed)
#   - <install-dir>/docker-compose.override.yml   (only if the installer made it)
#   - <install-dir>/auto-cancel.env               (the webhook secret and rule)
#   - <install-dir>/auto-cancel/                  (the receiver and the reasons)
#   - <install-dir>/auto-cancel-data/             (the list of rejected applicants;
#                                                  you are asked whether to keep it)
#   - the Python image the receiver ran on, if nothing else is using it
#
# Cal.diy itself - the app, its database and its data - is not touched, and
# neither are existing bookings. The one thing this script cannot do is delete
# the webhook inside Cal.diy; it is left pointing at a service that no longer
# exists, so remove it there (see the note printed at the end).
# =============================================================================

DEFAULT_BASE="/var/www/docker/cal"
MARKER="# Managed by cal-auto-cancel-install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || _die "'docker' is required but not installed."
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
docker info >/dev/null 2>&1 || _die "cannot reach the Docker daemon - is it running, and is this user allowed to use it?"

echo ""
echo "=====> Cal.diy auto-cancel: uninstall"
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
[ -f "$INSTALL_DIR/docker-compose.yml" ] || _die "$INSTALL_DIR/docker-compose.yml not found - is Cal.diy installed there?"
[ -w "$INSTALL_DIR" ] || _die "$INSTALL_DIR is not writable by this user."

OVERRIDE="$INSTALL_DIR/docker-compose.override.yml"
ENV_FILE="$INSTALL_DIR/auto-cancel.env"
APP_DIR="$INSTALL_DIR/auto-cancel"
DATA_DIR="$INSTALL_DIR/auto-cancel-data"

# The override file is only ours to delete if the installer wrote it.
if [ -e "$OVERRIDE" ] && ! head -n1 "$OVERRIDE" | grep -qF "$MARKER"; then
  _die "$OVERRIDE was not made by cal-auto-cancel-install.sh - remove the auto-cancel service from it by hand."
fi
if [ ! -e "$OVERRIDE" ] && [ ! -e "$ENV_FILE" ] && [ ! -e "$APP_DIR" ] && [ ! -e "$DATA_DIR" ]; then
  echo "Nothing to remove: auto-cancel is not installed in $INSTALL_DIR."
  exit 0
fi

# The image the receiver ran on, read from the file that names it.
py_image=""
if [ -e "$OVERRIDE" ]; then
  py_image="$(awk '$1 == "image:" { print $2; exit }' "$OVERRIDE")"
fi

# The people it has cancelled are the one thing worth keeping across a reinstall.
keep_list=false
rejected_count=0
if [ -f "$DATA_DIR/rejected.txt" ]; then
  rejected_count="$(grep -cvE '^[[:space:]]*(#|$)' "$DATA_DIR/rejected.txt" || true)"
fi
if [ "$rejected_count" -gt 0 ]; then
  echo ""
  echo "$DATA_DIR/rejected.txt lists $rejected_count rejected applicant(s). A reinstall"
  echo "would forget them unless the list is kept."
  read -rp "Keep the list? [y/N] " ans_keep
  [[ "$ans_keep" =~ ^[Yy]$ ]] && keep_list=true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== WILL REMOVE ===================="
echo "Container       : auto-cancel (stopped, then deleted)"
for f in "$OVERRIDE" "$ENV_FILE" "$APP_DIR"; do
  [ -e "$f" ] && echo "File            : $f"
done
if [ -e "$DATA_DIR" ]; then
  if [[ "$keep_list" == "true" ]]; then
    echo "Kept            : $DATA_DIR (the list of $rejected_count rejected applicant(s))"
  else
    echo "File            : $DATA_DIR ($rejected_count rejected applicant(s) listed)"
  fi
fi
[[ -n "$py_image" ]] && echo "Image           : $py_image (unless something else uses it)"
echo "Left alone      : Cal.diy, its database, and all bookings"
echo "====================================================="
echo ""
read -rp "Remove it? [y/N] " ans_go
[[ "$ans_go" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Remove ────────────────────────────────────────────────────────────────────
# The container goes first, while the override file that defines it still exists.
cd "$INSTALL_DIR"
if [ -e "$OVERRIDE" ]; then
  echo ""
  echo "==> Stopping and removing the container"
  docker compose rm -sf auto-cancel
fi

echo "==> Removing files"
rm -f "$OVERRIDE" "$ENV_FILE"
rm -rf "$APP_DIR"
[[ "$keep_list" == "true" ]] || rm -rf "$DATA_DIR"

if [[ -n "$py_image" ]]; then
  if docker image rm "$py_image" >/dev/null 2>&1; then
    echo "==> Removed image $py_image"
  else
    echo "==> Kept image $py_image (still in use, or already gone)"
  fi
fi

# What is left should be Cal.diy and its database, still running.
echo ""
docker compose ps --format 'table {{.Service}}\t{{.Status}}'

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> auto-cancel removed. One step is left, inside Cal.diy:"
echo ""
echo "    Open the event type > Webhooks tab and delete the webhook whose Subscriber URL is"
echo "    http://auto-cancel:8787 (or Settings > Developer > Webhooks, if you made it there)."
echo "    Until then Cal.diy tries to call it on every booking, and the call fails."
echo ""
echo "    To install it again: cal-auto-cancel-install.sh"
