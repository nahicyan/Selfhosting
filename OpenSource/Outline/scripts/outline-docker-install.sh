#!/bin/bash
set -euo pipefail
# =============================================================================
# Outline Docker Install Script
# =============================================================================
# Deploys Outline (outline + postgres + redis) from the docker-compose.yml
# next to this script, behind a host Nginx reverse proxy.
#
#   <install-dir>/
#     |-- docker-compose.yml   copied from this repo
#     `-- .env                 written here (mode 600) - all app config
#
# Postgres and Redis data live in named Docker volumes (storage-data,
# database-data), not bind mounts, so there is no host UID/GID to reconcile.
#
# Two sign-in methods:
#   1) Email magic link - needs a working SMTP server (custom mail server
#                         only, matching outline/temp/SMTP.txt).
#   2) Keycloak (OIDC)  - uses a Keycloak instance from ../../Keycloak on this
#                         host, or installs a new one with
#                         keycloak-docker-install.sh. Using the admin
#                         credentials in that instance's .env, this script
#                         creates the realm, the confidential "outline" client
#                         (redirect + post-logout URIs), and optionally the
#                         first user, then writes the OIDC_* keys. SMTP is
#                         optional here: if you configure it, Outline sends
#                         notifications and the new realm gets it too, for
#                         password resets.
#
# File attachments are stored on local disk (FILE_STORAGE=local), not S3.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../outline-nginx.conf"
COMPOSE_SRC="$SCRIPT_DIR/../docker-compose.yml"
KC_INSTALL_SCRIPT="$SCRIPT_DIR/../../Keycloak/scripts/keycloak-docker-install.sh"
KC_COMPOSE_FILENAME="docker-compose.external-cert.yml"
KC_BASE="/var/www/docker/keycloak"

DEFAULT_BASE="/var/www/docker/outline"
DEFAULT_PORT="3000"

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_port_in_use() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

# Deliberately permissive: accepts a bare address or "Name <address>", and
# only checks for an "@" and a "." - GNU regex treats \< \> as word-boundary
# anchors (not literal brackets), so a stricter ERE here would be a footgun.
_valid_email() {
  [[ "$1" == *@*.* ]]
}

_mask() { [[ -n "${1:-}" ]] && echo "(set, ${#1} chars)" || echo "(empty)"; }

_gen_secret() { openssl rand -hex 32; }

# _ask_required <var-name> <prompt> - loop until a non-empty value is entered.
_ask_required() {
  local -n _ref="$1"
  local prompt="$2" value
  while :; do
    read -rp "$prompt" value
    if [[ -n "$value" ]]; then
      _ref="$value"
      return 0
    fi
    echo "    This value is required."
  done
}

# _ask_password <var-name> <label> - hidden + confirmed; blank generates one.
# Sets _PW_GENERATED=true when the value was generated.
_ask_password() {
  local -n _pref="$1"
  local label="$2" first second
  while :; do
    read -rsp "  ${label} (blank = generate one): " first; echo
    if [[ -z "$first" ]]; then
      _pref="$(openssl rand -base64 18 | tr -d '/+=')"
      _PW_GENERATED=true
      return 0
    fi
    read -rsp "  Confirm ${label}: " second; echo
    if [[ "$first" == "$second" ]]; then
      _pref="$first"
      _PW_GENERATED=false
      return 0
    fi
    echo "    Values do not match - try again."
  done
}

# Read one key from a Keycloak .env without leaking its other keys into this
# shell. That file is written for `source` (secrets are single-quoted).
_env_get() {  # _env_get <file> <key>
  (
    set +eu
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    printf '%s' "${!2:-}"
  )
}

# ── Keycloak admin REST API ──────────────────────────────────────────────────
# KC_API is the base URL (tried on 127.0.0.1:<port> first, so it doesn't
# depend on DNS or certificates, then the public https URL). Master-realm
# admin tokens only live 60s by default, so _kc_login runs again right before
# provisioning instead of reusing the token from the prompt phase.
KC_API=""
KC_TOKEN=""
KC_STATUS=""
KC_BODY=""

_kc_login() {  # _kc_login <base-url> <user> <password>
  KC_TOKEN="$(curl -s --max-time 15 -X POST \
      "$1/realms/master/protocol/openid-connect/token" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=$2" \
      --data-urlencode "password=$3" 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null || true)"
  [[ -n "$KC_TOKEN" ]]
}

_kc() {  # _kc <method> <path> [json-body] - sets KC_STATUS and KC_BODY
  local method="$1" path="$2" body="${3:-}" out
  local -a args=(-s --max-time 30 -X "$method" -H "Authorization: Bearer $KC_TOKEN")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-binary "$body")
  out="$(mktemp)"
  KC_STATUS="$(curl "${args[@]}" -o "$out" -w '%{http_code}' "$KC_API$path" 2>/dev/null || echo "000")"
  KC_BODY="$(cat "$out")"
  rm -f "$out"
}

_kc_expect() {  # _kc_expect <what> <status>... - die unless KC_STATUS matches
  local what="$1" s; shift
  for s in "$@"; do [[ "$KC_STATUS" == "$s" ]] && return 0; done
  _die "Keycloak: $what failed (HTTP $KC_STATUS): ${KC_BODY:0:300}"
}

_kc_find_instances() {
  [ -d "$KC_BASE" ] || return 0
  find "$KC_BASE" -maxdepth 2 -name "$KC_COMPOSE_FILENAME" -exec dirname {} \; 2>/dev/null | sort -u
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in docker curl openssl sed; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
docker compose version >/dev/null 2>&1 || _die "the Docker Compose plugin ('docker compose') is required."
[ -f "$COMPOSE_SRC" ]    || _die "docker-compose.yml not found at $COMPOSE_SRC"
[ -f "$NGINX_CONF_SRC" ] || _die "outline-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> Outline Install"
echo "========================================"
echo "Compose source: $COMPOSE_SRC"
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. outline.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"   # hostnames are case-insensitive; compose project name must be lowercase

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
echo "Outline will be installed into a per-domain directory."
read -rp "Install directory [$DEFAULT_BASE/$domain]: " answer
INSTALL_DIR="${answer:-$DEFAULT_BASE/$domain}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
INSTALL_DIR="${INSTALL_DIR%/}"
[[ "$INSTALL_DIR" = /* ]] || _die "Install directory must be an absolute path."
if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  _die "$INSTALL_DIR already exists and is not empty - remove it first, or choose another path."
fi

# ── 3. Host port ──────────────────────────────────────────────────────────────
echo ""
echo "Outline is published on 127.0.0.1:<port> and proxied by Nginx."
read -rp "Host port [$DEFAULT_PORT]: " answer
port="${answer:-$DEFAULT_PORT}"
_valid_port "$port" || _die "Port must be a number between 1 and 65535."
if _port_in_use "$port"; then
  echo ""
  echo "WARNING: something is already listening on port $port:"
  ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  read -rp "Continue anyway? [y/N] " ans_port
  [[ "$ans_port" =~ ^[Yy]$ ]] || _die "Aborted - pick a free port."
fi

# ── 4. Sign-in method ────────────────────────────────────────────────────────
echo ""
echo "How should people sign in to Outline?"
echo "  1) Email magic link  (needs an SMTP server)"
echo "  2) Keycloak (OIDC)   (uses/creates a Keycloak instance on this host and"
echo "                        sets up the realm and client automatically)"
read -rp "Select [1/2]: " AUTH_CHOICE
case "$AUTH_CHOICE" in
  1) AUTH_METHOD="magic" ;;
  2) AUTH_METHOD="keycloak" ;;
  *) _die "Invalid selection." ;;
esac

# ── 5. Keycloak ──────────────────────────────────────────────────────────────
kc_dir=""; kc_domain=""; kc_port=""; kc_admin_user=""; kc_admin_pass=""
kc_realm=""; kc_realm_exists=false
kc_client_id=""; kc_client_uuid=""; kc_client_secret=""
kc_display_name=""
kc_create_user=false
kc_user_name=""; kc_user_email=""; kc_user_first=""; kc_user_last=""
kc_user_pass=""; kc_user_pass_generated=false

if [[ "$AUTH_METHOD" == "keycloak" ]]; then
  command -v jq >/dev/null 2>&1 || _die "'jq' is required for Keycloak setup (apt install jq)."

  echo ""
  echo "==> Keycloak instance"
  mapfile -t KC_INSTANCES < <(_kc_find_instances)
  for i in "${!KC_INSTANCES[@]}"; do
    echo "  $((i+1))) Use existing: $(basename "${KC_INSTANCES[$i]}")"
  done
  KC_NEW_CHOICE=$(( ${#KC_INSTANCES[@]} + 1 ))
  echo "  ${KC_NEW_CHOICE}) Install a new Keycloak instance now"
  read -rp "Select [1-${KC_NEW_CHOICE}]: " KC_CHOICE
  if ! [[ "$KC_CHOICE" =~ ^[0-9]+$ ]] || [ "$KC_CHOICE" -lt 1 ] || [ "$KC_CHOICE" -gt "$KC_NEW_CHOICE" ]; then
    _die "Invalid selection."
  fi

  if [ "$KC_CHOICE" -eq "$KC_NEW_CHOICE" ]; then
    [ -f "$KC_INSTALL_SCRIPT" ] || _die "Keycloak installer not found at $KC_INSTALL_SCRIPT"
    echo ""
    echo "==> Running the Keycloak installer. Outline setup continues when it"
    echo "    finishes. Accept the Let's Encrypt and Nginx steps: Outline"
    echo "    reaches Keycloak through its public https URL."
    echo "----------------------------------------------------------------"
    bash "$KC_INSTALL_SCRIPT" || _die "Keycloak installer failed - fix that first, then re-run this script."
    echo "----------------------------------------------------------------"
    echo "==> Back in the Outline installer."
    # Whatever was not there before is the instance that was just installed.
    mapfile -t KC_AFTER < <(_kc_find_instances)
    for d in "${KC_AFTER[@]}"; do
      [[ " ${KC_INSTANCES[*]:-} " == *" $d "* ]] || kc_dir="$d"
    done
    [[ -n "$kc_dir" ]] || _die "No new Keycloak instance was found under $KC_BASE (was the install aborted?)."
  else
    kc_dir="${KC_INSTANCES[$((KC_CHOICE-1))]}"
  fi

  KC_ENV_FILE="$kc_dir/.env"
  [ -r "$KC_ENV_FILE" ] || _die "Cannot read $KC_ENV_FILE"
  kc_domain="$(_env_get "$KC_ENV_FILE" KEYCLOAK_URL)"
  kc_port="$(_env_get "$KC_ENV_FILE" KEYCLOAK_PORT)"
  kc_admin_user="$(_env_get "$KC_ENV_FILE" KEYCLOAK_USER)"
  kc_admin_pass="$(_env_get "$KC_ENV_FILE" KEYCLOAK_PASSWORD)"
  [[ -n "$kc_domain" ]] || _die "KEYCLOAK_URL is not set in $KC_ENV_FILE"
  kc_domain="${kc_domain#https://}"; kc_domain="${kc_domain#http://}"; kc_domain="${kc_domain%/}"
  echo "    Instance : $kc_dir"
  echo "    URL      : https://$kc_domain"

  # Log in to the admin API - local port first, public URL as a fallback.
  # KEYCLOAK_USER/PASSWORD are only the bootstrap admin; if that account was
  # changed in Keycloak since, ask for working credentials instead.
  _kc_try_login() {
    local base
    for base in ${kc_port:+"http://127.0.0.1:$kc_port"} "https://$kc_domain"; do
      if _kc_login "$base" "$kc_admin_user" "$kc_admin_pass"; then
        KC_API="$base"
        return 0
      fi
    done
    return 1
  }
  if ! _kc_try_login; then
    echo ""
    echo "    Could not log in to the Keycloak admin API with the credentials in"
    echo "    $KC_ENV_FILE (the bootstrap admin may have been changed or removed)."
    _ask_required kc_admin_user "  Keycloak admin username (master realm): "
    read -rsp "  Keycloak admin password: " kc_admin_pass; echo
    _kc_try_login || _die "Keycloak admin login failed at http://127.0.0.1:${kc_port:-?} and https://$kc_domain"
  fi
  echo "==> Logged in to the Keycloak admin API ($KC_API) as $kc_admin_user"

  # ── Realm ──
  echo ""
  read -rp "  Realm name [outline]: " kc_realm
  kc_realm="${kc_realm:-outline}"
  [[ "$kc_realm" =~ ^[A-Za-z0-9._-]+$ ]] || _die "Realm name may only contain A-Z a-z 0-9 . _ -"
  [[ "$kc_realm" != "master" ]] || _die "Do not use the master realm for applications - pick another name."
  _kc GET "/admin/realms/$kc_realm"
  if [[ "$KC_STATUS" == "200" ]]; then
    read -rp "  Realm '$kc_realm' already exists. Use it (its settings are left as they are)? [y/N] " ans_realm
    [[ "$ans_realm" =~ ^[Yy]$ ]] || _die "Aborted - choose another realm name."
    kc_realm_exists=true
  elif [[ "$KC_STATUS" != "404" ]]; then
    _kc_expect "realm lookup" 200 404
  fi

  # ── Client ──
  read -rp "  Client ID [outline]: " kc_client_id
  kc_client_id="${kc_client_id:-outline}"
  [[ "$kc_client_id" =~ ^[A-Za-z0-9._-]+$ ]] || _die "Client ID may only contain A-Z a-z 0-9 . _ -"
  if [[ "$kc_realm_exists" == "true" ]]; then
    _kc GET "/admin/realms/$kc_realm/clients?clientId=$kc_client_id"
    _kc_expect "client lookup" 200
    kc_client_uuid="$(jq -r '.[0].id // empty' <<< "$KC_BODY")"
    if [[ -n "$kc_client_uuid" ]]; then
      echo "  Client '$kc_client_id' already exists in realm '$kc_realm'."
      read -rp "  Overwrite its settings and generate a new secret for this Outline? [y/N] " ans_client
      [[ "$ans_client" =~ ^[Yy]$ ]] || _die "Aborted - choose another client ID."
    fi
  fi

  read -rp "  Sign-in button label [Keycloak]: " kc_display_name
  kc_display_name="${kc_display_name:-Keycloak}"
  [ "${#kc_display_name}" -le 50 ] || _die "Button label must be 50 characters or less (OIDC_DISPLAY_NAME)."

  # ── First user ──
  # Outline has no bootstrap admin: the first person to sign in creates the
  # workspace and becomes its admin. A new realm has no users, so offer to
  # create that person now. Outline requires an email address, and the
  # workspace's domain comes from it.
  echo ""
  read -rp "  Create a Keycloak user for yourself (the first Outline admin)? [Y/n] " ans_user
  if ! [[ "$ans_user" =~ ^[Nn]$ ]]; then
    kc_create_user=true
    _ask_required kc_user_name  "    Username: "
    _ask_required kc_user_email "    Email: "
    _valid_email "$kc_user_email" || _die "'$kc_user_email' is not a valid email address."
    _ask_required kc_user_first "    First name: "
    _ask_required kc_user_last  "    Last name: "
    _ask_password kc_user_pass "  Password"
    kc_user_pass_generated="$_PW_GENERATED"
  fi

  kc_client_secret="$(_gen_secret)"
  KC_ISSUER="https://$kc_domain/realms/$kc_realm"
fi

# ── 6. SMTP ──────────────────────────────────────────────────────────────────
configure_smtp=true
smtp_host=""; smtp_port=""; smtp_username=""; smtp_password=""
smtp_from=""; smtp_reply=""; smtp_secure=""
echo ""
if [[ "$AUTH_METHOD" == "magic" ]]; then
  echo "Email magic-link sign-in needs a custom SMTP server - see"
  echo "outline/temp/SMTP.txt."
else
  echo "SMTP is optional with Keycloak. Configure it and Outline can send"
  echo "notification emails (and magic-link sign-in also becomes available)."
  [[ "$kc_realm_exists" == "false" ]] && \
    echo "The new realm will use the same server for password-reset emails."
  read -rp "Configure SMTP? [Y/n] " ans_smtp
  [[ "$ans_smtp" =~ ^[Nn]$ ]] && configure_smtp=false
fi
echo ""

if [[ "$configure_smtp" == "true" ]]; then
  _ask_required smtp_host     "  SMTP host (e.g. mail.example.com): "
  read -rp     "  SMTP port [465]: " smtp_port
  smtp_port="${smtp_port:-465}"
  _valid_port "$smtp_port" || _die "SMTP port must be a number between 1 and 65535."
  _ask_required smtp_username "  SMTP username: "
  read -rsp    "  SMTP password (leave blank if the server does not require one): " smtp_password; echo
  _ask_required smtp_from     "  SMTP from address (e.g. Outline <noreply@example.com>): "
  _valid_email "$smtp_from" || _die "'$smtp_from' does not look like a valid from address."
  read -rp     "  SMTP reply-to address (optional, blank = same as from): " smtp_reply

  smtp_secure_default="Y"
  smtp_secure_prompt="Y/n"
  if [[ "$smtp_port" == "587" || "$smtp_port" == "25" ]]; then
    smtp_secure_default="N"
    smtp_secure_prompt="y/N"
  fi
  read -rp "  Connect with TLS (SMTP_SECURE)? [$smtp_secure_prompt]: " ans_smtp_secure
  ans_smtp_secure="${ans_smtp_secure:-$smtp_secure_default}"
  if [[ "$ans_smtp_secure" =~ ^[Yy]$ ]]; then smtp_secure="true"; else smtp_secure="false"; fi

  # Compose interpolates $ inside .env, so a literal $ in any of these
  # admin-supplied values (most likely the password) must be escaped as $$ to
  # survive into the container unchanged - see docker-compose.yml's comment on
  # env_file. Generated secrets (hex only) never need this.
  smtp_host_env="${smtp_host//\$/\$\$}"
  smtp_username_env="${smtp_username//\$/\$\$}"
  smtp_password_env="${smtp_password//\$/\$\$}"
  smtp_from_env="${smtp_from//\$/\$\$}"
  smtp_reply_env="${smtp_reply//\$/\$\$}"
fi

# ── Derived values ────────────────────────────────────────────────────────────
PROJECT_NAME="outline-${domain//./-}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

secret_key="$(_gen_secret)"
utils_secret="$(_gen_secret)"
postgres_password="$(_gen_secret)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "URL             : https://$domain"
echo "Install dir     : $INSTALL_DIR"
echo "Host port       : 127.0.0.1:$port  ->  container :3000"
echo "Compose project : $PROJECT_NAME"
if [[ "$AUTH_METHOD" == "magic" ]]; then
  echo "Auth method     : Email magic-link"
else
  echo "Auth method     : Keycloak (OIDC)$( [[ "$configure_smtp" == "true" ]] && echo " + email magic-link" )"
  echo "Keycloak        : https://$kc_domain  ($kc_dir)"
  echo "Realm           : $kc_realm $( [[ "$kc_realm_exists" == "true" ]] && echo "(existing - left as is)" || echo "(will be created)" )"
  echo "Client          : $kc_client_id $( [[ -n "$kc_client_uuid" ]] && echo "(existing - will be overwritten)" || echo "(will be created)" )"
  echo "Redirect URI    : https://$domain/auth/oidc.callback"
  echo "Button label    : $kc_display_name"
  if [[ "$kc_create_user" == "true" ]]; then
    echo "First user      : $kc_user_name <$kc_user_email> ($kc_user_first $kc_user_last)"
    echo "User password   : $( [[ "$kc_user_pass_generated" == "true" ]] && echo "generated, shown at the end, must be changed at first login" || _mask "$kc_user_pass" )"
  fi
fi
echo "File storage    : local disk (docker volume, storage-data)"
if [[ "$configure_smtp" == "true" ]]; then
  echo "SMTP host       : $smtp_host:$smtp_port (TLS: $smtp_secure)"
  echo "SMTP username   : $smtp_username"
  echo "SMTP password   : $(_mask "$smtp_password")"
  echo "SMTP from       : $smtp_from"
  echo "SMTP reply-to   : ${smtp_reply:-(same as from)}"
else
  echo "SMTP            : not configured"
fi
echo "Secrets         : SECRET_KEY, UTILS_SECRET, POSTGRES_PASSWORD - generated"
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Provision Keycloak (realm, client, first user) ───────────────────────────
# Done before anything is written for Outline: the client secret goes into
# .env, and if this fails there is nothing on disk to clean up. Re-running
# is safe - the realm is then reused and the client overwritten.
if [[ "$AUTH_METHOD" == "keycloak" ]]; then
  echo ""
  echo "==> Configuring Keycloak"
  _kc_login "$KC_API" "$kc_admin_user" "$kc_admin_pass" || _die "Keycloak admin login failed."

  if [[ "$kc_realm_exists" == "false" ]]; then
    smtp_json='null'
    if [[ "$configure_smtp" == "true" ]]; then
      # Keycloak wants the bare address and the display name separately.
      kc_from_addr="$smtp_from"; kc_from_name=""
      re='^[[:space:]]*"?([^"<]*[^"<[:space:]])?"?[[:space:]]*<([^>]+)>[[:space:]]*$'
      if [[ "$smtp_from" =~ $re ]]; then
        kc_from_name="${BASH_REMATCH[1]}"
        kc_from_addr="${BASH_REMATCH[2]}"
      fi
      smtp_json="$(jq -n \
        --arg host "$smtp_host" --arg port "$smtp_port" \
        --arg from "$kc_from_addr" --arg name "$kc_from_name" \
        --arg reply "$smtp_reply" --arg user "$smtp_username" --arg pass "$smtp_password" \
        --arg secure "$smtp_secure" '
        {host: $host, port: $port, from: $from,
         ssl: $secure, starttls: (if $secure == "true" then "false" else "true" end),
         auth: (if $user != "" then "true" else "false" end)}
        + (if $name  != "" then {fromDisplayName: $name} else {} end)
        + (if $reply != "" then {replyTo: $reply} else {} end)
        + (if $user  != "" then {user: $user, password: $pass} else {} end)')"
    fi
    realm_json="$(jq -n --arg realm "$kc_realm" --argjson smtp "$smtp_json" '
      {realm: $realm, displayName: "Outline", enabled: true,
       sslRequired: "external",
       registrationAllowed: false,
       loginWithEmailAllowed: true, duplicateEmailsAllowed: false,
       resetPasswordAllowed: ($smtp != null),
       bruteForceProtected: true}
      + (if $smtp != null then {smtpServer: $smtp} else {} end)')"
    _kc POST "/admin/realms" "$realm_json"
    _kc_expect "creating realm '$kc_realm'" 201
    echo "    Realm '$kc_realm' created."
  fi

  # Outline's OIDC plugin: callback ${URL}/auth/oidc.callback; RP-initiated
  # logout sends post_logout_redirect_uri=${URL} (plugins/oidc/server/auth/
  # oidcRouter.ts), so that exact URI has to be allowed too.
  client_json="$(jq -n \
    --arg cid "$kc_client_id" --arg secret "$kc_client_secret" --arg url "https://$domain" '
    {clientId: $cid, name: "Outline", description: "Outline wiki - \($url)",
     protocol: "openid-connect", enabled: true,
     publicClient: false, clientAuthenticatorType: "client-secret", secret: $secret,
     standardFlowEnabled: true, implicitFlowEnabled: false,
     directAccessGrantsEnabled: false, serviceAccountsEnabled: false,
     rootUrl: $url, baseUrl: "/",
     redirectUris: [$url + "/auth/oidc.callback"],
     webOrigins: [$url],
     attributes: {"post.logout.redirect.uris": ($url + "##" + $url + "/*")}}')"
  if [[ -n "$kc_client_uuid" ]]; then
    _kc PUT "/admin/realms/$kc_realm/clients/$kc_client_uuid" \
      "$(jq --arg id "$kc_client_uuid" '. + {id: $id}' <<< "$client_json")"
    _kc_expect "updating client '$kc_client_id'" 204
    echo "    Client '$kc_client_id' updated (new secret)."
  else
    _kc POST "/admin/realms/$kc_realm/clients" "$client_json"
    _kc_expect "creating client '$kc_client_id'" 201
    echo "    Client '$kc_client_id' created."
  fi

  if [[ "$kc_create_user" == "true" ]]; then
    user_json="$(jq -n \
      --arg u "$kc_user_name" --arg e "$kc_user_email" \
      --arg f "$kc_user_first" --arg l "$kc_user_last" \
      --arg p "$kc_user_pass" --argjson t "$kc_user_pass_generated" '
      {username: $u, email: $e, firstName: $f, lastName: $l,
       enabled: true, emailVerified: true,
       credentials: [{type: "password", value: $p, temporary: $t}]}')"
    _kc POST "/admin/realms/$kc_realm/users" "$user_json"
    if [[ "$KC_STATUS" == "409" ]]; then
      echo "    WARNING: user '$kc_user_name' (or that email) already exists in '$kc_realm' - left unchanged."
      kc_create_user=false
    else
      _kc_expect "creating user '$kc_user_name'" 201
      echo "    User '$kc_user_name' created."
    fi
  fi
fi

# ── Create the install directory ─────────────────────────────────────────────
echo ""
echo "==> Creating $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Copy the compose file ────────────────────────────────────────────────────
cp "$COMPOSE_SRC" "$COMPOSE_FILE"
echo "==> docker-compose.yml copied to $COMPOSE_FILE"

# ── Write .env ───────────────────────────────────────────────────────────────
echo "==> Writing .env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<ENV_EOF
# Outline instance configuration - generated by outline-docker-install.sh
# Read by 'docker compose' from this directory (both for \${...} interpolation
# in docker-compose.yml and, via env_file, passed straight into the outline
# container using Outline's own variable names). Keep this file safe. Back it
# up alongside the storage-data and database-data docker volumes.

COMPOSE_PROJECT_NAME=$PROJECT_NAME
NODE_ENV=production

# ── Core ──
URL=https://$domain
PORT=3000
DEFAULT_LANGUAGE=en_US
WEB_CONCURRENCY=1
SECRET_KEY=$secret_key
UTILS_SECRET=$utils_secret

# Loopback host port; the Nginx vhost proxies here. Container is always :3000.
OUTLINE_PORT=$port

# Uncomment to pin the image instead of tracking :latest, e.g. OUTLINE_VERSION=1.2.0
# OUTLINE_VERSION=latest

# ── SSL / reverse proxy ──
# Nginx (outline-nginx.conf) terminates TLS and forwards X-Forwarded-Proto;
# Outline trusts that by default (PROXY_HEADERS_TRUSTED) so this does not
# cause a redirect loop.
FORCE_HTTPS=true

# ── Database ──
# Postgres and Outline only ever talk over the private compose network on
# this host, so PGSSLMODE=disable is correct here - without it Outline's
# production mode always attempts SSL (server/storage/database.ts) and a
# stock postgres image, which has no certificate configured, refuses it and
# the container fails to start.
DATABASE_URL=postgres://outline:${postgres_password}@postgres:5432/outline
PGSSLMODE=disable
POSTGRES_USER=outline
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DB=outline

# ── Redis ──
REDIS_URL=redis://redis:6379

# ── File storage (local disk, not S3) ──
FILE_STORAGE=local
FILE_STORAGE_LOCAL_ROOT_DIR=/var/lib/outline/data
FILE_STORAGE_UPLOAD_MAX_SIZE=262144000

ENV_EOF

if [[ "$configure_smtp" == "true" ]]; then
  cat >> "$ENV_FILE" <<ENV_EOF
# ── Email / SMTP (custom mail server - powers email magic-link sign-in) ──
SMTP_HOST=$smtp_host_env
SMTP_PORT=$smtp_port
SMTP_USERNAME=$smtp_username_env
SMTP_PASSWORD=$smtp_password_env
SMTP_FROM_EMAIL=$smtp_from_env
SMTP_REPLY_EMAIL=$smtp_reply_env
SMTP_SECURE=$smtp_secure

ENV_EOF
fi

if [[ "$AUTH_METHOD" == "keycloak" ]]; then
  cat >> "$ENV_FILE" <<ENV_EOF
# ── OIDC - Keycloak (https://$kc_domain, realm $kc_realm) ──
# Created by this script: client "$kc_client_id" in $kc_dir.
# Endpoints are given explicitly instead of OIDC_ISSUER_URL on purpose: with
# the issuer, Outline runs discovery at boot and exits (Logger.fatal) if
# Keycloak is unreachable at that moment; with explicit endpoints it always
# starts, and Keycloak is contacted only when someone signs in.
OIDC_CLIENT_ID=$kc_client_id
OIDC_CLIENT_SECRET=$kc_client_secret
OIDC_AUTH_URI=$KC_ISSUER/protocol/openid-connect/auth
OIDC_TOKEN_URI=$KC_ISSUER/protocol/openid-connect/token
OIDC_USERINFO_URI=$KC_ISSUER/protocol/openid-connect/userinfo
OIDC_LOGOUT_URI=$KC_ISSUER/protocol/openid-connect/logout
# OIDC_ISSUER_URL=$KC_ISSUER
OIDC_USERNAME_CLAIM=preferred_username
OIDC_DISPLAY_NAME=${kc_display_name//\$/\$\$}
OIDC_SCOPES=openid profile email

ENV_EOF
fi

cat >> "$ENV_FILE" <<ENV_EOF
# ── Logging ──
ENABLE_UPDATES=true
DEBUG=http
LOG_LEVEL=info
ENV_EOF
echo "==> .env written to $ENV_FILE (mode 600)"

# ── Validate the compose file against .env ───────────────────────────────────
echo "==> Validating docker-compose.yml..."
docker compose config >/dev/null || _die "docker-compose.yml did not validate with this .env."
echo "    OK"

# ── Review ──────────────────────────────────────────────────────────────────-
read -rp "Would you like to review/edit .env? [y/N] " ans_env
[[ "$ans_env" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$ENV_FILE"

read -rp "Would you like to review/edit docker-compose.yml? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" "$COMPOSE_FILE"

# ── Start ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Pulling images..."
docker compose pull
echo "==> Starting Outline, Postgres and Redis..."
docker compose up -d

# ── Wait for Outline to answer ───────────────────────────────────────────────
# /_health checks the database and Redis connections, not just "process is up".
echo -n "==> Waiting for Outline to respond on 127.0.0.1:$port"
OUTLINE_UP=false
for _ in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${port}/_health" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    OUTLINE_UP=true
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [[ "$OUTLINE_UP" == "true" ]]; then
  echo "==> Outline is up."
else
  echo "WARNING: Outline did not answer within ~2 minutes."
  echo "         Check the logs: (cd $INSTALL_DIR && docker compose logs -f outline)"
  read -rp "Continue with the Nginx setup anyway? [y/N] " ans_continue
  [[ "$ans_continue" =~ ^[Yy]$ ]] || exit 1
fi

# ── Can Outline reach Keycloak? ──────────────────────────────────────────────
# At sign-in, the outline container calls Keycloak's token and userinfo
# endpoints server-side on https://<keycloak-domain>. If the host cannot reach
# its own public IP (no NAT hairpin, common on home networks), that fails even
# though the browser works. The fix is to resolve the Keycloak name to the
# Docker host inside the container, where host Nginx answers on :443.
_outline_reaches_kc() {
  docker compose exec -T outline node -e '
    fetch(process.argv[1], { signal: AbortSignal.timeout(10000) })
      .then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1));
  ' "$KC_ISSUER/.well-known/openid-configuration" >/dev/null 2>&1
}

if [[ "$AUTH_METHOD" == "keycloak" && "$OUTLINE_UP" == "true" ]]; then
  echo "==> Checking that Outline can reach Keycloak at https://$kc_domain ..."
  if _outline_reaches_kc; then
    echo "    OK"
  else
    echo "WARNING: the outline container cannot fetch"
    echo "         $KC_ISSUER/.well-known/openid-configuration"
    echo "         Common causes: Keycloak's certificate or Nginx vhost is not set up,"
    echo "         or this host cannot reach its own public IP (NAT hairpin)."
    read -rp "Map $kc_domain to the Docker host inside the container (docker-compose.override.yml)? [Y/n] " ans_hosts
    if ! [[ "$ans_hosts" =~ ^[Nn]$ ]]; then
      cat > "$INSTALL_DIR/docker-compose.override.yml" <<OVERRIDE_EOF
# Written by outline-docker-install.sh: resolve the Keycloak hostname to the
# Docker host so the OIDC token/userinfo calls go straight to host Nginx
# instead of out through the public IP. Delete this file if it is not needed.
services:
  outline:
    extra_hosts:
      - "$kc_domain:host-gateway"
OVERRIDE_EOF
      echo "==> Wrote $INSTALL_DIR/docker-compose.override.yml, recreating outline..."
      docker compose up -d outline
      sleep 5
      if _outline_reaches_kc; then
        echo "    OK - Outline reaches Keycloak now."
      else
        echo "WARNING: still unreachable. Check Keycloak's Nginx vhost and certificate:"
        echo "           curl -I $KC_ISSUER/.well-known/openid-configuration"
        echo "         Sign-in will fail until this works."
      fi
    fi
  fi
fi

# ── Let's Encrypt ───────────────────────────────────────────────────────────-
echo ""
read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
fi

# ── Nginx reverse proxy ─────────────────────────────────────────────────────-
read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  NGINX_AVAIL="/etc/nginx/sites-available/$domain"

  sudo cp "$NGINX_CONF_SRC" "$NGINX_AVAIL"
  sudo sed -i \
    -e "s|outline\.example\.com|$domain|g" \
    -e "s|127\.0\.0\.1:3000|127.0.0.1:$port|g" \
    "$NGINX_AVAIL"
  echo "==> Nginx config written to $NGINX_AVAIL (domain + port substituted)"

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

# ── Done ────────────────────────────────────────────────────────────────────-
echo ""
echo "==> Outline installation complete."
echo "    URL          : https://$domain"
if [[ "$AUTH_METHOD" == "magic" ]]; then
  echo "    Sign-in      : email magic-link - the first person to sign in creates"
  echo "                   the workspace and becomes its admin."
else
  echo "    Sign-in      : Keycloak (realm $kc_realm) - the first person to sign in"
  echo "                   creates the workspace and becomes its admin."
  echo "    Keycloak     : https://$kc_domain/admin/master/console/#/$kc_realm"
  echo "                   add more users there (Users -> Add user, with an email)."
  if [[ "$kc_create_user" == "true" ]]; then
    echo "    First user   : $kc_user_name <$kc_user_email>"
    if [[ "$kc_user_pass_generated" == "true" ]]; then
      echo "    Temp password: $kc_user_pass   (must be changed at first sign-in)"
    fi
  fi
  if [[ "$configure_smtp" == "true" ]]; then
    echo "    Magic link   : also enabled (SMTP is set). To allow Keycloak only, turn"
    echo "                   off Email under Settings -> Authentication in Outline."
  fi
fi
echo "    Attachments  : docker volume storage-data (mounted at /var/lib/outline/data)"
echo "    Database     : docker volume database-data (Postgres)"
echo "    Secrets      : $ENV_FILE (mode 600 - back this up)"
echo ""
echo "    Useful commands (run from $INSTALL_DIR):"
echo "    Start   : docker compose up -d"
echo "    Stop    : docker compose down"
echo "    Restart : docker compose restart"
echo "    Logs    : docker compose logs -f outline"
echo "    Status  : docker compose ps"
echo "    Update  : docker compose pull && docker compose up -d"
echo ""
