#!/bin/bash
set -euo pipefail
# =============================================================================
# Nextcloud AIO Docker Install Script
# =============================================================================
# Deploys Nextcloud All-in-One behind the host's Nginx, following AIO's
# reverse proxy guide:
#   https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
#
#   <install-dir>/              default /var/www/docker/nextcloud/<domain>
#     |-- compose.yaml          upstream compose.yaml with the changes chosen below
#     |-- compose.yaml.orig     upstream compose.yaml as downloaded
#     `-- data/                 Nextcloud's datadir (NEXTCLOUD_DATADIR)
#
# compose.yaml is downloaded fresh from AIO's main branch (override with
# AIO_COMPOSE_URL). The changes from EOL-README.md are offered one by one -
# yes applies a change, no keeps upstream's line as it is:
#   - ports 80 and 8443 removed: Nginx owns 80/443 and the certificate
#   - the AIO interface published on <aio-port>:8080
#   - environment: APACHE_PORT, APACHE_IP_BINDING=127.0.0.1, NEXTCLOUD_DATADIR,
#     TALK_PORT (asked only if Talk will be used), upload/time/memory limits,
#     borg retention, startup apps, imagemagick + imagick, docker socket path
# The result is checked with `docker compose config`, so a change in the
# upstream file's layout stops the script instead of starting a wrong setup.
#
# IPv6: Nginx and the published ports serve it either way. When chosen, the
# script also creates AIO's internal "nextcloud-aio" network with --ipv6 before
# the first start (AIO's docker-ipv6-support.md). The mastercontainer would
# otherwise create it IPv4-only, and a network cannot be switched afterwards.
#
# Only the mastercontainer is started here. Nextcloud itself is set up in the
# AIO interface (domain, optional containers, backups), which then creates the
# other containers. AIO also updates and backs itself up (borg), so this repo
# has no update/backup scripts for it.
#
# AIO runs one instance per host: the container name
# (nextcloud-aio-mastercontainer), its volume (nextcloud_aio_mastercontainer)
# and the Compose project (nextcloud-aio) are fixed upstream.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_SRC="$SCRIPT_DIR/../nextcloud-aio-nginx.conf"
AIO_COMPOSE_URL="${AIO_COMPOSE_URL:-https://raw.githubusercontent.com/nextcloud/all-in-one/refs/heads/main/compose.yaml}"

DEFAULT_BASE="/var/www/docker/nextcloud"
MASTER="nextcloud-aio-mastercontainer"         # container + service name, fixed by AIO
MASTER_VOLUME="nextcloud_aio_mastercontainer"  # fixed by AIO, built-in backups rely on it
AIO_NETWORK="nextcloud-aio"                    # fixed by AIO, created by the mastercontainer if missing

STARTED=false         # true from creating the install dir until the interface is up
VOLUME_EXISTED=false  # an earlier instance's volume is reused - never suggest deleting it
INSTALL_DIR=""
datadir=""

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$STARTED" == "true" ]]; then
    local down="docker compose down -v"
    [[ "$VOLUME_EXISTED" == "true" ]] && down="docker compose down"
    echo "" >&2
    echo "The install did not finish. To start over:" >&2
    echo "  (cd $INSTALL_DIR && $down); sudo rm -rf $INSTALL_DIR" >&2
    [[ -z "$datadir" || "$datadir" == "$INSTALL_DIR"/* ]] || echo "  sudo rmdir $datadir" >&2
  fi
}
trap _on_exit EXIT
trap 'exit 130' INT    # so Ctrl-C still runs _on_exit
trap 'exit 143' TERM

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Paths go into compose.yaml unquoted and through sed, so keep them plain.
_valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]]
}

_port_in_use() {  # TCP or UDP - AIO publishes Apache and Talk on both
  [[ -n "$(ss -ltunH "sport = :$1" 2>/dev/null)" ]]
}

# _check_port_free <port> - warn and ask if something already listens on it
_check_port_free() {
  local answer
  if _port_in_use "$1"; then
    echo "WARNING: something is already listening on port $1:"
    ss -ltunp "sport = :$1" 2>/dev/null || true
    read -rp "Continue anyway? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || _die "Aborted - pick a free port."
  fi
}

# _ask_port <var-name> <label> <default>
_ask_port() {
  local -n _port="$1"
  local answer
  read -rp "$2 [$3]: " answer
  _port="${answer:-$3}"
  _valid_port "$_port" || _die "$2 must be a number between 1 and 65535."
  _check_port_free "$_port"
}

# _ask_change <Y|N> <question> - yes/no with the given default, true on yes
_ask_change() {
  local answer
  if [[ "$1" == "Y" ]]; then
    read -rp "$2 [Y/n] " answer
    [[ ! "$answer" =~ ^[Nn]$ ]]
  else
    read -rp "$2 [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

# _offer_env KEY VALUE <Y|N> DESCRIPTION - offer one environment change;
# queued in ENV_VARS on yes, upstream's line is kept on no.
_offer_env() {
  echo ""
  echo "$1: $4"
  if _ask_change "$3" "Set $1=$2?"; then
    ENV_VARS+=("$1=$2")
  else
    KEPT+=("$1 not set")
  fi
}

# _queued KEY - true if KEY is among the accepted environment changes
_queued() {
  [[ " ${ENV_VARS[*]%%=*} " == *" $1 "* ]]
}

# _set_env KEY VALUE - set KEY in the mastercontainer's environment: uncomment
# upstream's example line in place (its doc comment stays), or add the key
# under "environment:" if upstream has no line for it.
_set_env() {
  if grep -qE "^[[:space:]]*#?[[:space:]]*$1:" "$COMPOSE_FILE"; then
    sed -i -E -e "s|^[[:space:]]*#?[[:space:]]*$1:[^#]*(#.*)?\$|      $1: $2 \1|" \
              -e "s|^(      $1: .*[^ ]) +\$|\1|" "$COMPOSE_FILE"
  else
    sed -i -E "/^[[:space:]]*environment:/a\\      $1: $2" "$COMPOSE_FILE"
  fi
}

# _cfg_env KEY - KEY's value in the effective (normalized) compose config.
_cfg_env() {
  docker compose config 2>/dev/null | sed -nE "s/^      $1: \"?([^\"]*)\"?\$/\1/p"
}

# ── Dependency check ──────────────────────────────────────────────────────────
# Docker first: every step below runs through it.
command -v docker >/dev/null 2>&1 \
  || _die "Docker is not installed. Install Docker Engine (https://docs.docker.com/engine/install/), then run this script again."
docker compose version >/dev/null 2>&1 \
  || _die "the Docker Compose plugin ('docker compose') is not installed. Install it (https://docs.docker.com/compose/install/linux/), then run this script again."
docker info >/dev/null 2>&1 \
  || _die "cannot reach the Docker daemon - is it running, and is $(id -un) in the docker group?"
for cmd in curl ss ip getent awk sed grep sort; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
# Both checks are from AIO's install guide.
if docker info --format '{{.DockerRootDir}}' 2>/dev/null | grep -q '^/var/snap/docker/'; then
  _die "snap-based Docker is not supported by AIO. Install Docker from https://docs.docker.com/engine/install/ instead."
fi
[ -S /var/run/docker.sock ] || _die "/var/run/docker.sock not found. compose.yaml mounts it; rootless Docker needs the changes in AIO's docker-rootless.md."
[ -f "$NGINX_CONF_SRC" ] || _die "nextcloud-aio-nginx.conf not found at $NGINX_CONF_SRC"

echo ""
echo "=====> Nextcloud AIO Install"
echo "========================================"
echo "compose.yaml source: $AIO_COMPOSE_URL"
echo ""

# ── Existing AIO instance ─────────────────────────────────────────────────────
existing="$(docker ps -a --format '{{.Names}}' | grep -E '^nextcloud-aio-' || true)"
if [[ -n "$existing" ]]; then
  sed 's/^/  /' <<< "$existing"
  echo "AIO runs one instance per host. To change that instance, edit its compose.yaml"
  echo "and run 'docker compose up -d'. To remove it, see:"
  echo "  https://github.com/nextcloud/all-in-one#how-to-properly-reset-the-instance"
  _die "Nextcloud AIO containers already exist on this host (above)."
fi
mapfile -t OLD_VOLUMES < <(docker volume ls -q | grep -E '^nextcloud_aio_' || true)
if [ ${#OLD_VOLUMES[@]} -gt 0 ]; then
  printf '  %s\n' "${OLD_VOLUMES[@]}"
  echo "WARNING: these volumes are left from an earlier AIO instance. The new"
  echo "         mastercontainer resumes that instance (its domain, passphrase and"
  echo "         database) instead of starting a fresh setup. To start fresh, see:"
  echo "         https://github.com/nextcloud/all-in-one#how-to-properly-reset-the-instance"
  read -rp "Continue and reuse them? [y/N] " ans_reuse
  [[ "$ans_reuse" =~ ^[Yy]$ ]] || _die "Aborted."
  [[ " ${OLD_VOLUMES[*]} " == *" $MASTER_VOLUME "* ]] && VOLUME_EXISTED=true
fi

# ── Prerequisites ────────────────────────────────────────────────────────────
# Confirmed by the person running this: the Nginx site expects the certificate
# in /etc/letsencrypt/live/<domain>/, and certbot only issues it once the DNS
# record points here.
echo "Before you continue, make sure that:"
echo "  1. A DNS record for the Nextcloud domain points at this server."
echo "  2. A Let's Encrypt certificate for the Nextcloud domain exists in"
echo "     /etc/letsencrypt/live/<domain>/."
echo ""
read -rp "Type 'yes' to confirm both and continue: " ans_prereq
[[ "${ans_prereq,,}" == "yes" ]] || _die "Aborted - set these up first, then run this script again."
echo ""

# ── 1. Domain ─────────────────────────────────────────────────────────────────
read -rp "Enter domain name (e.g. cloud.example.com): " domain
[[ -n "$domain" ]] || _die "Domain cannot be empty."
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"

# ── 2. Install directory ──────────────────────────────────────────────────────
echo ""
read -rp "Install directory [$DEFAULT_BASE/$domain]: " answer
INSTALL_DIR="${answer:-$DEFAULT_BASE/$domain}"
INSTALL_DIR="${INSTALL_DIR%/}"
_valid_path "$INSTALL_DIR" || _die "Install directory must be an absolute path of letters, digits and . _ - /"
if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  _die "$INSTALL_DIR already exists and is not empty - remove it first, or choose another path."
fi

# ── 3. compose.yaml changes ───────────────────────────────────────────────────
# One question per change from EOL-README.md. Yes applies it, no keeps
# upstream's line. The defaults give the EOL-README.md setup: yes to each
# change with its values, and no to Talk, which EOL-README.md does not use.
CHANGES=()   # accepted changes, for the summary
KEPT=()      # declined changes - upstream's lines stay as they are
ENV_VARS=()  # accepted KEY=VALUE environment changes
echo ""
echo "──── compose.yaml changes ────"
echo "Each change is asked separately: yes applies it, no keeps upstream's line."

echo ""
echo "Port 80:80: redirects to Nextcloud and gets the certificate for the AIO interface"
echo "on 8443. Not needed behind Nginx, which owns port 80."
if _ask_change Y "Remove port 80:80?"; then
  rm_80=true; CHANGES+=("port 80:80 removed")
else
  rm_80=false; KEPT+=("port 80:80"); _check_port_free 80
fi

echo ""
echo "Port 8443:8443: the AIO interface with the domain's certificate. Not needed"
echo "behind Nginx - the interface stays reachable by IP on the port below."
if _ask_change Y "Remove port 8443:8443?"; then
  rm_8443=true; CHANGES+=("port 8443:8443 removed")
else
  rm_8443=false; KEPT+=("port 8443:8443"); _check_port_free 8443
fi

echo ""
echo "Port 8080:8080: the AIO interface (self-signed certificate, opened by IP)."
echo "EOL-README.md moved it to 8081. Only the host side can change."
if _ask_change Y "Publish the AIO interface on another host port?"; then
  _ask_port aio_port "AIO interface port" 8081
  CHANGES+=("port 8080:8080 -> $aio_port:8080")
else
  aio_port=8080; KEPT+=("port 8080:8080"); _check_port_free 8080
fi

echo ""
echo "APACHE_PORT: the port Nginx proxies to - required behind a reverse proxy."
echo "Without it AIO serves Nextcloud on 443 itself, which Nginx already uses."
if _ask_change Y "Set APACHE_PORT?"; then
  _ask_port apache_port "Apache port" 11000
  ENV_VARS+=("APACHE_PORT=$apache_port")
else
  apache_port=""; KEPT+=("APACHE_PORT not set")
  echo "    No APACHE_PORT: the certificate and Nginx steps will be skipped."
fi

_offer_env APACHE_IP_BINDING 127.0.0.1 Y \
  "Apache only on 127.0.0.1, so it is reachable through Nginx only (upstream: all interfaces)."

echo ""
echo "NEXTCLOUD_DATADIR: Nextcloud's files in a host directory instead of the Docker"
echo "volume nextcloud_aio_nextcloud_datadir. It cannot be moved after the first"
echo "start, so pick a big disk now."
if _ask_change Y "Set NEXTCLOUD_DATADIR?"; then
  read -rp "Data directory [$INSTALL_DIR/data]: " answer
  datadir="${answer:-$INSTALL_DIR/data}"
  datadir="${datadir%/}"
  _valid_path "$datadir" || _die "Data directory must be an absolute path of letters, digits and . _ - /"
  [[ "$datadir" != "$INSTALL_DIR" ]] || _die "The data directory must not be the install directory itself."
  if [ -e "$datadir" ] && [ -n "$(sudo ls -A "$datadir" 2>/dev/null)" ]; then
    _die "$datadir already exists and is not empty - AIO needs an empty data directory."
  fi
  ENV_VARS+=("NEXTCLOUD_DATADIR=$datadir")
else
  KEPT+=("NEXTCLOUD_DATADIR not set")
fi

# Talk itself is switched on or off in the AIO interface (on by default), not in
# compose.yaml. TALK_PORT is only read when the Talk container is enabled.
echo ""
echo "Nextcloud Talk (chat, calls): an optional AIO container, ticked by default in"
echo "the AIO interface. Its TURN server publishes TALK_PORT on all interfaces."
if _ask_change N "Will you use Nextcloud Talk?"; then
  use_talk=true
  echo ""
  echo "TALK_PORT: Talk's TURN port, TCP+UDP (upstream: 3478). AIO recommends a port"
  echo "above 1024."
  if _ask_change Y "Set TALK_PORT?"; then
    _ask_port talk_port "Talk port" 3478
    (( talk_port > 1024 )) || _die "Talk port must be above 1024."
    ENV_VARS+=("TALK_PORT=$talk_port")
  else
    talk_port=3478; KEPT+=("TALK_PORT not set"); _check_port_free 3478
  fi
else
  use_talk=false; talk_port=""; KEPT+=("TALK_PORT not set (Talk not used)")
fi

_offer_env NEXTCLOUD_UPLOAD_LIMIT 128G Y \
  "max size of non-chunked uploads, e.g. into public shares (upstream: 1G)."
_offer_env NEXTCLOUD_MAX_TIME 604800 Y \
  "PHP max execution time in seconds; Nginx's timeout follows it (upstream: 3600)."
_offer_env NEXTCLOUD_MEMORY_LIMIT 2048M Y \
  "PHP memory limit per process (upstream: 512M)."
_offer_env BORG_RETENTION_POLICY "--keep-within=7d --keep-weekly=4 --keep-monthly=6" Y \
  "how long borg keeps backups - upstream's default, made explicit."
_offer_env NEXTCLOUD_STARTUP_APPS "deck twofactor_totp tasks calendar contacts notes" Y \
  "apps installed on the first start - upstream's default, made explicit."
_offer_env NEXTCLOUD_ADDITIONAL_APKS imagemagick Y \
  "extra packages in the Nextcloud container - upstream's default, made explicit."
_offer_env NEXTCLOUD_ADDITIONAL_PHP_EXTENSIONS imagick Y \
  "extra PHP extensions - upstream's default, made explicit."
_offer_env AIO_DISABLE_BACKUP_SECTION false Y \
  "keeps the backup section in the AIO interface - upstream's default, made explicit."
_offer_env WATCHTOWER_DOCKER_SOCKET_PATH /var/run/docker.sock Y \
  "Docker socket for mastercontainer updates - upstream's default, made explicit."

CHANGES+=("${ENV_VARS[@]}")
used_ports=("$aio_port")
[[ "$use_talk" == "true" ]] && used_ports+=("$talk_port")
[[ -n "$apache_port" ]] && used_ports+=("$apache_port")
[[ "$rm_80" == "true" ]] || used_ports+=(80)
[[ "$rm_8443" == "true" ]] || used_ports+=(8443)
[[ "$(printf '%s\n' "${used_ports[@]}" | sort -u | wc -l)" -eq ${#used_ports[@]} ]] \
  || _die "the ports must all be different (${used_ports[*]})."

# ── 4. IPv6 ───────────────────────────────────────────────────────────────────
# On an IPv4-only nextcloud-aio network, IPv6 clients still get in through
# docker-proxy but arrive as the gateway address, Talk's TURN server has no IPv6
# relay address, and the containers have no outbound IPv6. Creating the network
# with --ipv6 is AIO's per-network alternative to enabling IPv6 for every new
# Docker network in daemon.json. Docker 27.0.1+ picks the ULA subnet itself.
host_ipv6s="$(ip -6 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | xargs || true)"
host_ipv6="${host_ipv6s%% *}"
docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
net_ipv6="$(docker network inspect -f '{{.EnableIPv6}}' "$AIO_NETWORK" 2>/dev/null || true)"
ipv6_net=""   # keep | create | recreate - empty for IPv4 only
echo ""
if [[ "$net_ipv6" == "true" ]]; then
  echo "IPv6: the $AIO_NETWORK network already exists with IPv6 - AIO will use it."
  ipv6_net=keep
elif [ ! -e /proc/net/if_inet6 ]; then
  echo "IPv6: disabled in this host's kernel - AIO runs IPv4 only."
elif [[ "$(printf '%s\n' 27.0.1 "$docker_ver" | sort -V | head -n1)" != "27.0.1" ]]; then
  echo "IPv6: needs Docker 27.0.1 or newer (this is ${docker_ver:-unknown}) - AIO runs IPv4 only."
else
  echo "IPv6: makes AIO's internal network dual-stack, so Talk works for IPv6 callers"
  echo "and Nextcloud can reach IPv6-only servers. Cannot be switched after the first start."
  if [[ -n "$host_ipv6" ]]; then
    read -rp "Enable IPv6? [Y/n] " answer
    [[ "$answer" =~ ^[Nn]$ ]] || ipv6_net=create
  else
    read -rp "This host has no global IPv6 address yet. Enable IPv6 anyway? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] && ipv6_net=create
  fi
  if [[ "$ipv6_net" == create && "$net_ipv6" == "false" ]]; then
    # Left from an earlier instance. No AIO containers exist (checked above).
    attached="$(docker network inspect -f '{{range .Containers}} {{.Name}}{{end}}' "$AIO_NETWORK")"
    [[ -z "$attached" ]] \
      || _die "the $AIO_NETWORK network exists without IPv6 and these containers use it:$attached. Disconnect them, or answer n to stay IPv4 only."
    ipv6_net=recreate
  fi
fi
case "$ipv6_net" in
  keep)     ipv6_info="yes - existing $AIO_NETWORK network" ;;
  create)   ipv6_info="yes - $AIO_NETWORK network created with --ipv6" ;;
  recreate) ipv6_info="yes - empty IPv4-only $AIO_NETWORK network recreated with --ipv6" ;;
  *)        ipv6_info="no - IPv4 only inside Docker (Nginx still serves IPv6)" ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ -z "$apache_port" ]]; then
  apache_info="443 on all interfaces - AIO without a reverse proxy (upstream)"
elif _queued APACHE_IP_BINDING; then
  apache_info="127.0.0.1:$apache_port  (Nginx upstream)"
else
  apache_info="0.0.0.0:$apache_port  (Nginx upstream, also reachable from outside)"
fi
echo ""
echo "==================== SUMMARY ===================="
echo "Domain          : $domain"
echo "Install dir     : $INSTALL_DIR"
echo "Data dir        : ${datadir:-Docker volume nextcloud_aio_nextcloud_datadir (upstream)}"
echo "AIO interface   : 0.0.0.0:$aio_port  ->  mastercontainer :8080"
echo "Apache          : $apache_info"
if [[ "$use_talk" == "true" ]]; then
  echo "Talk            : $talk_port/tcp+udp"
else
  echo "Talk            : not used - untick it in the AIO interface"
fi
echo "IPv6            : $ipv6_info"
echo "compose.yaml changes:"
if [ ${#CHANGES[@]} -gt 0 ]; then printf '  + %s\n' "${CHANGES[@]}"; else echo "  (none - upstream's file as is)"; fi
if [ ${#KEPT[@]} -gt 0 ]; then
  echo "Kept as upstream:"
  printf '  = %s\n' "${KEPT[@]}"
fi
echo "================================================="
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Create the directories ────────────────────────────────────────────────────
# sudo only when the parent is not writable (/var/www/docker is usually root's).
# AIO's Nextcloud container chowns the data directory to www-data on start.
echo ""
echo "==> Creating $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
if [ "$(stat -c %u "$INSTALL_DIR")" != "$(id -u)" ]; then
  sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
fi
chmod 750 "$INSTALL_DIR"
STARTED=true
if [[ -n "$datadir" ]]; then
  mkdir -p "$datadir" 2>/dev/null || sudo mkdir -p "$datadir"
fi
cd "$INSTALL_DIR"

# ── compose.yaml ──────────────────────────────────────────────────────────────
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
ORIG_FILE="$INSTALL_DIR/compose.yaml.orig"

echo "==> Downloading compose.yaml"
curl -fsSL --max-time 30 --retry 3 "$AIO_COMPOSE_URL" -o "$ORIG_FILE" \
  || _die "could not download $AIO_COMPOSE_URL"
grep -q "container_name: $MASTER" "$ORIG_FILE" \
  || _die "$AIO_COMPOSE_URL does not look like AIO's compose.yaml."

how="to run behind the host's Nginx"
[[ -n "$apache_port" ]] || how="with the changes chosen at install"
{
  echo "# Nextcloud AIO - upstream compose.yaml from $AIO_COMPOSE_URL ($(date +%F)),"
  echo "# changed by nextcloud-aio-docker-install.sh $how."
  echo "# Changes: diff -u compose.yaml.orig compose.yaml"
  cat "$ORIG_FILE"
} > "$COMPOSE_FILE"

echo "==> Applying the accepted changes (${#CHANGES[@]})"
sed_args=()
[[ "$rm_80" == "true" ]] && sed_args+=(-e 's|^([[:space:]]*)(- "?80:80"?)|\1# \2|')
[[ "$rm_8443" == "true" ]] && sed_args+=(-e 's|^([[:space:]]*)(- "?8443:8443"?)|\1# \2|')
[[ "$aio_port" != "8080" ]] && sed_args+=(-e "s|^([[:space:]]*- )\"?8080:8080\"?|\1\"$aio_port:8080\"|")
[ ${#ENV_VARS[@]} -gt 0 ] && sed_args+=(-e 's|^([[:space:]]*)#[[:space:]]*environment:|\1environment:|')
if [ ${#sed_args[@]} -gt 0 ]; then
  sed -i -E "${sed_args[@]}" "$COMPOSE_FILE"
fi
for kv in "${ENV_VARS[@]}"; do
  _set_env "${kv%%=*}" "${kv#*=}"
done

# Check what Compose will actually run, not the text.
cfg="$(docker compose config 2>&1)" || { echo "$cfg" >&2; _die "compose.yaml does not validate after patching."; }
for kv in "${ENV_VARS[@]}"; do
  k="${kv%%=*}" v="${kv#*=}"
  grep -qxF -e "      $k: $v" -e "      $k: \"$v\"" <<< "$cfg" \
    || _die "patching failed: $k is not '$v' in 'docker compose config'. Upstream's compose.yaml layout may have changed - compare $ORIG_FILE with EOL-README.md and edit $COMPOSE_FILE by hand."
done
want_ports=("$aio_port")
[[ "$rm_80" == "true" ]] || want_ports+=(80)
[[ "$rm_8443" == "true" ]] || want_ports+=(8443)
want="$(printf '%s\n' "${want_ports[@]}" | sort -n | xargs)"
published="$(sed -nE 's/^ +published: "?([0-9]+)"?$/\1/p' <<< "$cfg" | sort -n | xargs)"
[[ "$published" == "$want" ]] \
  || _die "patching failed: published ports are '$published', expected '$want'. Check the ports: section of $COMPOSE_FILE."
echo "    OK - $COMPOSE_FILE"

read -rp "Would you like to review/edit compose.yaml? [y/N] " ans_compose
if [[ "$ans_compose" =~ ^[Yy]$ ]]; then
  "${EDITOR:-vim}" "$COMPOSE_FILE"
  docker compose config --quiet || _die "compose.yaml does not validate after your edit."
fi

# Read back from the file Compose will run, so edits made above carry over to Nginx.
apache_port="$(_cfg_env APACHE_PORT)"
max_time="$(_cfg_env NEXTCLOUD_MAX_TIME)"; max_time="${max_time:-3600}"
talk_port="$(_cfg_env TALK_PORT)"; talk_port="${talk_port:-3478}"
datadir="$(_cfg_env NEXTCLOUD_DATADIR)"

# ── Start the mastercontainer ─────────────────────────────────────────────────
echo ""
if [[ "$ipv6_net" == create || "$ipv6_net" == recreate ]]; then
  echo "==> Creating the $AIO_NETWORK network with IPv6"
  if [[ "$ipv6_net" == recreate ]]; then docker network rm "$AIO_NETWORK" >/dev/null; fi
  docker network create --ipv6 "$AIO_NETWORK" >/dev/null \
    || _die "could not create the $AIO_NETWORK network with IPv6. See https://github.com/nextcloud/all-in-one/blob/main/docker-ipv6-support.md"
fi
echo "==> Pulling the AIO image..."
docker compose pull
echo "==> Starting $MASTER..."
docker compose up -d

published="$(docker compose port "$MASTER" 8080 2>/dev/null || true)"
published="${published%%$'\n'*}"
aio_port="${published##*:}"
[[ -n "$aio_port" ]] || _die "port 8080 of $MASTER is not published - check the ports: section of compose.yaml."

# The interface answers 403 to requests without a browser's Sec-Fetch-* headers
# (AIO PR #8786), so the probe sends them. Any 2xx-4xx answer is the interface
# itself; Caddy gives 5xx until PHP is ready.
echo -n "==> Waiting for the AIO interface"
IFACE_UP=false restarts=0 code=""
for _ in $(seq 1 36); do   # 3 minutes
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
            -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' \
            "https://127.0.0.1:$aio_port/" 2>/dev/null || true)"
  if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then IFACE_UP=true; break; fi
  # AIO's start script exits on invalid settings, and restart: always loops it.
  restarts="$(docker inspect -f '{{.RestartCount}}' "$MASTER" 2>/dev/null || echo 0)"
  [[ "$restarts" -lt 2 ]] || break
  echo -n "."
  sleep 5
done
echo ""
STARTED=false   # running: a failure from here on leaves an instance to fix, not to delete
if [[ "$IFACE_UP" == "true" ]]; then
  echo "==> AIO interface is up on port $aio_port."
else
  # The steps below don't need the interface, so carry on and say so.
  echo "---- last 40 lines of the $MASTER log ----"
  docker logs --tail 40 "$MASTER" 2>&1 || true
  echo "-------------------------------------------------------------"
  if [[ "$restarts" -ge 2 ]]; then
    IFACE_WARN="$MASTER is restarting in a loop: AIO rejected a setting (see its log). Fix it in compose.yaml, then from $INSTALL_DIR: docker compose up -d"
  else
    [[ "$code" =~ ^[0-9]{3}$ && "$code" != 000 ]] && last="HTTP $code" || last="no connection"
    IFACE_WARN="the AIO interface did not answer on https://127.0.0.1:$aio_port/ within 3 minutes ($last). Open it in a browser; if it doesn't load, check: docker logs $MASTER"
  fi
  echo "WARNING: $IFACE_WARN"
  echo "         Continuing with the remaining steps."
fi

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
# Let's Encrypt and most clients try IPv6 first, so an AAAA record that leads
# elsewhere breaks the certificate and the site even when IPv4 works.
echo ""
aaaa="$(getent ahostsv6 "$domain" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | xargs || true)"
if [[ -n "$aaaa" ]]; then
  aaaa_here=false
  for a in $aaaa; do [[ " $host_ipv6s " == *" $a "* ]] && aaaa_here=true; done
  if [[ "$aaaa_here" != true ]]; then
    echo "WARNING: the AAAA record of $domain ($aaaa) is not an address of this"
    echo "         host (${host_ipv6s:-none}). Let's Encrypt and IPv6 clients use it first:"
    echo "         fix or remove it, unless a proxy such as Cloudflare is in front."
  fi
elif [[ -n "$host_ipv6" ]]; then
  echo "Note: $domain has no AAAA record. Add one for $host_ipv6 to serve IPv6 clients."
fi
# Without APACHE_PORT, AIO gets its own certificate and serves 443 itself.
ans_cert="n" ans_nginx="n"
if [[ -z "$apache_port" ]]; then
  echo "APACHE_PORT is not set: AIO serves Nextcloud on 443 and gets its own certificate,"
  echo "so the certificate and Nginx steps are skipped. Port 443 must be free for it."
else
  read -rp "Would you like to obtain a Let's Encrypt certificate now? [y/N] " ans_cert
fi
if [[ "$ans_cert" =~ ^[Yy]$ ]]; then
  sudo certbot certonly --nginx -d "$domain"
fi

# ── Nginx reverse proxy ───────────────────────────────────────────────────────
NGINX_AVAIL=""
[[ -z "$apache_port" ]] || read -rp "Would you like to set up the Nginx reverse proxy? [y/N] " ans_nginx
if [[ "$ans_nginx" =~ ^[Yy]$ ]]; then
  # Debian/Ubuntu layout, else the nginx.org/RHEL one.
  if [ -d /etc/nginx/sites-available ]; then
    NGINX_AVAIL="/etc/nginx/sites-available/$domain"
    NGINX_LINK="/etc/nginx/sites-enabled/$domain"
  else
    NGINX_AVAIL="/etc/nginx/conf.d/$domain.conf"
    NGINX_LINK=""
  fi
  if sudo test -e "$NGINX_AVAIL"; then
    read -rp "$NGINX_AVAIL already exists. Overwrite it? [y/N] " ans_over
    [[ "$ans_over" =~ ^[Yy]$ ]] || _die "Aborted - left $NGINX_AVAIL untouched. AIO itself is running."
  fi
  sudo test -f "/etc/letsencrypt/live/$domain/fullchain.pem" \
    || echo "WARNING: no certificate in /etc/letsencrypt/live/$domain/ yet - the Nginx test below will fail without it."

  vhost="$(mktemp)"
  sed -e "s|cloud\.example\.com|$domain|g" \
      -e "s|server 127\.0\.0\.1:11000;|server 127.0.0.1:$apache_port;|" \
      -e "s|proxy_read_timeout 3610s;|proxy_read_timeout $((max_time + 10))s;|" \
      "$NGINX_CONF_SRC" > "$vhost"
  grep -q "server 127.0.0.1:$apache_port;" "$vhost" && grep -q "server_name $domain;" "$vhost" \
    || _die "substitution in the Nginx template failed - check nextcloud-aio-nginx.conf's placeholders."

  # The official file's version notes, applied for this host.
  ngx_build="$(sudo nginx -V 2>&1)"
  ngx_ver="$(grep -oE 'nginx/[0-9]+\.[0-9]+\.[0-9]+' <<< "$ngx_build" | cut -d/ -f2 || true)"
  [[ -n "$ngx_ver" ]] || _die "could not read the nginx version from 'nginx -V'."
  if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -n1)" != "1.25.1" ]]; then
    echo "==> nginx $ngx_ver is older than 1.25.1: using 'listen ... ssl http2' instead of 'http2 on'"
    sed -i -E -e '/# for nginx v1\.25\.1\+/ s/^( *)([^ #])/\1#\2/' \
              -e '/# for nginx versions below v1\.25\.1/ s/^( *)#/\1/' "$vhost"
  fi
  # Socket options can be set once per address:port across all vhosts. On a
  # shared host they would also make the next vhost that sets its own (certbot
  # adds "ipv6only=on") fail nginx -t, so they are kept only when Nextcloud is
  # the sole enabled site on 80/443.
  if sudo grep -RqsE --exclude="$(basename "$NGINX_AVAIL")" \
       '^[[:space:]]*listen[[:space:]]+([^;#]*[[:space:]:])?(80|443)([[:space:];]|$)' \
       /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled; then
    echo "==> Other vhosts listen on 80/443: leaving out the listen socket options"
    sed -i -E '/^ *listen/ s/ bind reuseport deferred( multipath)? so_keepalive=on;/;/' "$vhost"
  fi
  if [[ "$ngx_build" != *--with-threads* ]]; then
    echo "==> nginx is built without thread support: leaving out 'aio threads'"
    sed -i -E 's/^( *)(aio(_write)? )/\1#\2/' "$vhost"
  fi
  if [ ! -e /proc/net/if_inet6 ]; then
    echo "==> IPv6 is disabled in this host's kernel: leaving out the [::] listen lines"
    sed -i -E 's/^( *)(listen \[::\])/\1#\2/' "$vhost"
  fi

  sudo install -m 644 "$vhost" "$NGINX_AVAIL"
  rm -f "$vhost"
  echo "==> Nginx config written to $NGINX_AVAIL"

  if [[ -n "$NGINX_LINK" ]]; then
    read -rp "Would you like to enable the site (link to sites-enabled)? [y/N] " ans_link
    if [[ "$ans_link" =~ ^[Yy]$ ]]; then
      sudo ln -sf "$NGINX_AVAIL" "$NGINX_LINK"
      echo "==> Symlink created."
    fi
  fi

  # A failing vhost left enabled would also break every later reload and
  # certbot renewal, so take it out again rather than leave it.
  echo "==> Testing Nginx configuration..."
  if ! sudo nginx -t; then
    if [[ -n "$NGINX_LINK" ]]; then
      sudo rm -f "$NGINX_LINK"
    else
      sudo mv "$NGINX_AVAIL" "$NGINX_AVAIL.disabled"
    fi
    _die "the Nginx test failed, so the Nextcloud vhost was disabled again and Nginx keeps its current config. AIO itself is running. Fix the error above (no certificate yet: sudo certbot certonly --nginx -d $domain), re-enable the vhost, then: sudo nginx -t && sudo systemctl reload nginx"
  fi
  echo "==> Reloading Nginx..."
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
public_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$public_ip" ]] || public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ "$public_ip" != *:* ]] || public_ip="[$public_ip]"   # IPv6-only host

echo ""
if [[ "$IFACE_UP" == "true" ]]; then
  echo "==> Nextcloud AIO mastercontainer is running."
else
  echo "==> Nextcloud AIO mastercontainer was started, but its interface was not confirmed."
  echo "WARNING: $IFACE_WARN"
fi
echo ""
echo "    Finish the setup in the AIO interface:"
echo "    1. Open https://${public_ip:-<server-ip>}:$aio_port/ by IP address, not by domain:"
echo "       HSTS on the domain would block the interface later. Accept the"
echo "       self-signed certificate."
echo "    2. Note the passphrase it shows, log in, enter $domain and submit."
if [[ -n "$apache_port" ]]; then
  echo "       AIO checks the domain through Nginx, so the certificate and the"
  echo "       vhost must be live first."
else
  echo "       AIO checks the domain on port 443, which must be free and open."
fi
echo "    3. Choose the optional containers and the time zone, then \"Download and"
echo "       start containers\". Note the initial Nextcloud admin password."
[[ "$use_talk" == "true" ]] || echo "       Untick Nextcloud Talk there - it is ticked by default."
echo "    4. Set up backups in the interface's Backup section."
echo ""
fw="80/tcp + 443/tcp, $aio_port/tcp (AIO interface)"
[[ "$rm_8443" == "true" ]] || fw+=", 8443/tcp"
echo "    Firewall/router, for IPv4 and IPv6: $fw"
[[ "$use_talk" == "true" ]] && echo "                     $talk_port/tcp + $talk_port/udp (Talk)"
echo "                     Ports Docker publishes bypass ufw."
echo ""
echo "    Install dir  : $INSTALL_DIR"
echo "    Compose file : $COMPOSE_FILE  (changes: diff -u compose.yaml.orig compose.yaml)"
echo "    Data dir     : ${datadir:-Docker volume nextcloud_aio_nextcloud_datadir}"
[[ -n "$NGINX_AVAIL" ]] && echo "    Nginx vhost  : $NGINX_AVAIL  (upstream 127.0.0.1:$apache_port)"
echo ""
echo "    Useful commands:"
echo "    Logs     : docker logs -f $MASTER"
echo "    Settings : edit compose.yaml, stop the containers in the AIO interface,"
echo "               then from $INSTALL_DIR: docker compose up -d"
echo "    occ      : docker exec --user www-data -it nextcloud-aio-nextcloud php occ <command>"
echo ""
