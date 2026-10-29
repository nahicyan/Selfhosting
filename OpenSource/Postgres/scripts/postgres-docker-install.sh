#!/bin/bash
set -euo pipefail
# =============================================================================
# PostgreSQL (shared) Docker Install Script
# =============================================================================
# One PostgreSQL server that many apps share, reachable remotely over TLS:
#
#   /var/www/docker/postgres/<domain>/
#     |-- docker-compose.yml   copied from ../docker-compose.yml
#     |-- .env                 written here (mode 600)
#     |-- conf/pg_hba.conf     who may connect, and how
#     |-- certs/               server.crt, server.key, ca.crt (mounted read-only)
#     |-- ca/                  the private CA - ca.key never enters the container
#     `-- clients/<role>/      certificate bundles for remote logins
#
# Who gets in:
#   Docker apps on this host  join the "postgres" network, connect to its
#                             gateway IP. Password.
#   Processes on this host    127.0.0.1:<port>. Password.
#   Everyone else             TLS only, password, and (unless turned off below)
#                             a client certificate whose CN is the login role.
#                             ufw decides which addresses get that far.
#
# Postgres runs on the host network: ports Docker publishes bypass ufw, so this
# is what makes the ufw rules below the real gate.
#
# Two modes:
#   1) New instance   - generates the CA, certificates and superuser password.
#   2) From a backup  - reuses the CA, client bundles and superuser password of
#                       a postgres-docker-backup.sh snapshot, so certificates
#                       already handed out keep working. Follow it with
#                       postgres-docker-restore.sh, option 2 (everything).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_SRC="$SCRIPT_DIR/../docker-compose.yml"

PG_BASE="/var/www/docker/postgres"
DEFAULT_BACKUP_ROOT="/home/backup"
DEFAULT_IMAGE="postgres:18"
DEFAULT_PORT="5432"
DEFAULT_NETWORK="postgres"
DEFAULT_SUBNET="10.254.254.0/24"
CA_DAYS=3650       # CA and server certificate
CLIENT_DAYS=825    # client certificates - re-issue with postgres-docker-manage.sh

STAGE=""
trap 'if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

# A key from .env with one layer of quotes removed. Read, never sourced.
_env_get() {  # _env_get <file> <key>
  local v
  v="$(sed -n "s/^${2}=//p" "$1" | tail -n1)"
  if [[ "$v" == \'*\' || "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

_nice_date() {
  local yr mo dy hr mn sc
  IFS='-' read -r yr mo dy hr mn sc <<< "$1"
  date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$1"
}

_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}
_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
_valid_source() { [[ "$1" == any || "$1" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; }

# openssl, quiet unless it fails.
_ssl() {
  local out
  out="$(openssl "$@" 2>&1)" || _die "openssl $1 failed: $out"
}

# _issue <dir> <name> <CN> <days> <extensions> - <dir>/<name>.key + .crt, signed by the CA.
_issue() {
  _ssl req -new -newkey rsa:3072 -nodes -subj "/CN=$3" -keyout "$1/$2.key" -out "$1/$2.csr"
  _ssl x509 -req -sha256 -days "$4" -in "$1/$2.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -extfile <(printf '%b\n' "$5") -out "$1/$2.crt"
  rm -f "$1/$2.csr"
  chmod 600 "$1/$2.key"
}

# _client <role> - clients/<role>/ holds everything a remote client needs.
_client() {
  local d="$INSTALL_DIR/clients/$1"
  mkdir -p "$d" && chmod 700 "$d"
  _issue "$d" client "$1" "$CLIENT_DAYS" \
    'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth'
  # Java clients (pgjdbc: DBeaver, DataGrip, Java apps) only read DER PKCS#8 keys.
  _ssl pkcs8 -topk8 -nocrypt -outform DER -in "$d/client.key" -out "$d/client.pk8"
  chmod 600 "$d/client.pk8"
  cp "$CA_DIR/ca.crt" "$d/ca.crt"
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 \
  || _die "Docker is not installed. Install Docker Engine (https://docs.docker.com/engine/install/), then run this script again."
docker compose version >/dev/null 2>&1 \
  || _die "the Docker Compose plugin ('docker compose') is not installed. Install it (https://docs.docker.com/compose/install/linux/), then run this script again."
docker info >/dev/null 2>&1 \
  || _die "cannot talk to Docker - is it running, and is $(id -un) in the docker group?"
for cmd in openssl tar sed awk mktemp sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || _die "'$cmd' is required but not installed."
done
[ -f "$COMPOSE_SRC" ] || _die "compose template not found at $COMPOSE_SRC"

echo ""
echo "=====> PostgreSQL (shared) Install"
echo "========================================"
echo "  1) New instance"
echo "  2) From a backup  (reuse its CA, client certificates and superuser password)"
echo ""
read -rp "Select [1/2]: " MODE
[[ "$MODE" == 1 || "$MODE" == 2 ]] || _die "Invalid selection."

domain="" port="" cert_ip="" client_cert="" network="" subnet="" image="" password=""

# ── Mode 2: unpack the snapshot's config ──────────────────────────────────────
if [[ "$MODE" == 2 ]]; then
  echo ""
  echo "Choose the directory where your backups are located:"
  echo "  1) Default: $DEFAULT_BACKUP_ROOT"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " ans
  if [ "$ans" = "2" ]; then
    read -rep "Enter custom backup base path: " BACKUP_ROOT
    BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"
  else
    BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
  fi
  BACKUPS_DIR="${BACKUP_ROOT%/}/postgres"
  [ -d "$BACKUPS_DIR" ] || _die "'$BACKUPS_DIR' not found."

  mapfile -t DOMAIN_DIRS < <(find "$BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
  [ ${#DOMAIN_DIRS[@]} -gt 0 ] || _die "No backups found in '$BACKUPS_DIR'."
  if [ ${#DOMAIN_DIRS[@]} -eq 1 ]; then
    DOMAIN_DIR="${DOMAIN_DIRS[0]}"
  else
    echo ""
    for i in "${!DOMAIN_DIRS[@]}"; do echo "  $((i+1))) $(basename "${DOMAIN_DIRS[$i]}")"; done
    read -rp "Select domain number: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#DOMAIN_DIRS[@]} ] || _die "Invalid selection."
    DOMAIN_DIR="${DOMAIN_DIRS[$((n-1))]}"
  fi

  mapfile -t SNAPS < <(find "$DOMAIN_DIR" -mindepth 2 -maxdepth 2 -name config.tar.gz -printf '%h\n' | sort -r)
  [ ${#SNAPS[@]} -gt 0 ] || _die "No snapshots with a config.tar.gz in '$DOMAIN_DIR'."
  echo ""
  echo "Snapshots for $(basename "$DOMAIN_DIR"):"
  for i in "${!SNAPS[@]}"; do
    count=$(find "${SNAPS[$i]}/databases" -name '*.sql.gz' 2>/dev/null | wc -l || true)
    printf "  %-4s %-30s %s database(s)\n" "$((i+1)))" "$(_nice_date "$(basename "${SNAPS[$i]}")")" "$count"
  done
  read -rp "Select snapshot number: " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#SNAPS[@]} ] || _die "Invalid selection."
  SNAP="${SNAPS[$((n-1))]}"

  (cd "$SNAP" && sha256sum --quiet -c SHA256SUMS) || _die "$SNAP failed its checksum test - pick another snapshot."
  STAGE="$(mktemp -d)"
  tar xzf "$SNAP/config.tar.gz" -C "$STAGE"
  [[ -f "$STAGE/ca/ca.key" && -f "$STAGE/.env" ]] || _die "$SNAP/config.tar.gz has no CA or no .env."

  domain="$(_env_get "$STAGE/.env" PG_DOMAIN)"
  port="$(_env_get "$STAGE/.env" PG_PORT)"
  cert_ip="$(_env_get "$STAGE/.env" PG_CERT_IP)"
  client_cert="$(_env_get "$STAGE/.env" PG_CLIENT_CERT)"
  network="$(_env_get "$STAGE/.env" PG_NETWORK)"
  subnet="$(_env_get "$STAGE/.env" PG_SUBNET)"
  image="$(_env_get "$STAGE/.env" POSTGRES_IMAGE)"
  password="$(_env_get "$STAGE/.env" POSTGRES_PASSWORD)"
  [[ -n "$password" ]] || _die "the snapshot's .env has no POSTGRES_PASSWORD."
  echo "==> Loaded the CA, client certificates and settings from $SNAP"
fi

# ── Questions ─────────────────────────────────────────────────────────────────
echo ""
read -rp "Domain clients connect to, e.g. db.example.com${domain:+ [$domain]}: " ans
domain="${ans:-$domain}"
_valid_domain "$domain" || _die "'$domain' is not a valid domain name."
domain="${domain,,}"

read -rp "Port [${port:-$DEFAULT_PORT}]: " ans
port="${ans:-${port:-$DEFAULT_PORT}}"
_valid_port "$port" || _die "Port must be a number between 1 and 65535."
if command -v ss >/dev/null 2>&1 && ss -ltnH | awk '{print $4}' | grep -qE "[:.]${port}$"; then
  ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  _die "port $port is already in use on this host. Postgres binds it directly, so pick another."
fi

read -rp "Server IP to add to the certificate, for clients that connect by IP (optional)${cert_ip:+ [$cert_ip]}: " ans
cert_ip="${ans:-$cert_ip}"
[[ -z "$cert_ip" || "$cert_ip" =~ ^[0-9A-Fa-f:.]+$ ]] || _die "'$cert_ip' is not an IP address."

echo ""
echo "Which remote addresses may reach port $port? IPs or CIDRs separated by spaces,"
echo "'any' for everyone, blank for none yet (add later with postgres-docker-manage.sh)."
read -rp "Allowed sources: " remote
for src in $remote; do _valid_source "$src" || _die "'$src' is not an IP, CIDR or 'any'."; done

read -rp "Require a client certificate for remote logins, on top of the password? [Y/n] " ans
if [[ "$ans" =~ ^[Nn]$ ]]; then client_cert=no
elif [[ "$ans" =~ ^[Yy]$ ]]; then client_cert=yes
else client_cert="${client_cert:-yes}"
fi

read -rp "Docker network apps join to reach Postgres [${network:-$DEFAULT_NETWORK}]: " ans
network="${ans:-${network:-$DEFAULT_NETWORK}}"
[[ "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || _die "'$network' is not a valid network name."
if docker network inspect "$network" >/dev/null 2>&1; then
  NET_EXISTS=true
  subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$network" | tr ' ' '\n' | grep -m1 '\.' || true)"
  [[ -n "$subnet" ]] || _die "network '$network' exists but has no IPv4 subnet."
  echo "    Network '$network' already exists ($subnet) - reusing it."
else
  NET_EXISTS=false
  read -rp "Subnet for it [${subnet:-$DEFAULT_SUBNET}]: " ans
  subnet="${ans:-${subnet:-$DEFAULT_SUBNET}}"
  [[ "$subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || _die "'$subnet' is not an IPv4 CIDR."
fi

image="${image:-$DEFAULT_IMAGE}"
password="${password:-$(openssl rand -hex 24)}"

INSTALL_DIR="$PG_BASE/$domain"
CA_DIR="$INSTALL_DIR/ca"
ENV_FILE="$INSTALL_DIR/.env"
PROJECT_NAME="postgres-${domain//./-}"
if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  _die "$INSTALL_DIR already exists and is not empty - remove that instance first, or use another domain."
fi

echo ""
echo "==================== SUMMARY ===================="
echo "Mode            : $([[ "$MODE" == 1 ]] && echo "New instance" || echo "From backup $SNAP")"
echo "Domain          : $domain${cert_ip:+ (+ IP $cert_ip)}"
echo "Port            : $port (all interfaces, filtered by ufw)"
echo "Remote sources  : ${remote:-none yet}"
echo "Remote login    : TLS + password$([[ "$client_cert" == yes ]] && echo " + client certificate")"
echo "Docker network  : $network ($subnet)$($NET_EXISTS && echo ", existing")"
echo "Image           : $image"
echo "Install dir     : $INSTALL_DIR"
echo "================================================="
read -rp "Proceed? [Y/n] " ans
[[ "$ans" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Instance directory ────────────────────────────────────────────────────────
echo ""
echo "==> Creating $INSTALL_DIR"
sudo mkdir -p "$PG_BASE"
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$INSTALL_DIR"
cp "$COMPOSE_SRC" "$INSTALL_DIR/docker-compose.yml"
mkdir -p "$INSTALL_DIR"/{conf,certs,ca,clients}
# conf/ and certs/ are read inside the container by the postgres user.
chmod 755 "$INSTALL_DIR/conf" "$INSTALL_DIR/certs"
chmod 700 "$CA_DIR" "$INSTALL_DIR/clients"

# ── Certificates ──────────────────────────────────────────────────────────────
if [[ -n "$STAGE" ]]; then
  cp -a "$STAGE/ca/." "$CA_DIR/"
  [ -d "$STAGE/clients" ] && cp -a "$STAGE/clients/." "$INSTALL_DIR/clients/"
  echo "==> Restored the CA and $(find "$INSTALL_DIR/clients" -mindepth 1 -maxdepth 1 -type d | wc -l) client bundle(s)"
else
  echo "==> Creating the certificate authority"
  _ssl req -x509 -new -newkey rsa:4096 -nodes -sha256 -days "$CA_DAYS" \
    -subj "/CN=PostgreSQL CA $domain" -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" \
    -config <(printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
  chmod 600 "$CA_DIR/ca.key"
fi

# Always issued fresh, so the domain and IP can change between rebuilds while
# clients keep trusting it - they trust the CA, not this certificate.
echo "==> Issuing the server certificate"
san="DNS:$domain"
[[ -n "$cert_ip" ]] && san+=",IP:$cert_ip"
_issue "$INSTALL_DIR/certs" server "$domain" "$CA_DAYS" \
  "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=$san"
cp "$CA_DIR/ca.crt" "$INSTALL_DIR/certs/ca.crt"
chmod 644 "$INSTALL_DIR/certs/server.crt" "$INSTALL_DIR/certs/ca.crt"

if [ ! -f "$INSTALL_DIR/clients/postgres/client.crt" ]; then
  echo "==> Issuing the client certificate for the postgres superuser"
  _client postgres
fi

# ── Docker network for apps ───────────────────────────────────────────────────
# enable_icc=false: apps share Postgres through it but cannot reach each other.
if ! $NET_EXISTS; then
  echo "==> Creating Docker network '$network' ($subnet)"
  docker network create --driver bridge --subnet "$subnet" \
    --opt com.docker.network.bridge.name="br-${network:0:12}" \
    --opt com.docker.network.bridge.enable_icc=false \
    --label "postgres.instance=$domain" "$network" >/dev/null \
    || _die "could not create network '$network' - if the subnet overlaps another network, run again and pick another."
fi
iface="$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$network")"
[[ -n "$iface" ]] || iface="br-$(docker network inspect -f '{{.Id}}' "$network" | cut -c1-12)"
gateway="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$network" | tr ' ' '\n' | grep -m1 '\.' || true)"
[[ -n "$gateway" ]] || _die "could not read the gateway address of network '$network'."

# ── pg_hba.conf and .env ──────────────────────────────────────────────────────
remote_auth="scram-sha-256"
[[ "$client_cert" == yes ]] && remote_auth+=" clientcert=verify-full"
cat > "$INSTALL_DIR/conf/pg_hba.conf" <<EOF
# Generated by postgres-docker-install.sh. The first matching line wins.
# Apply edits with: docker compose exec -u postgres postgres psql -c 'SELECT pg_reload_conf()'
#
# TYPE   DATABASE  USER  ADDRESS            METHOD
# Admin scripts (docker compose exec -u postgres) over the container's socket.
local    all       all                      peer
# Processes on this host.
host     all       all   127.0.0.1/32       scram-sha-256
host     all       all   ::1/128            scram-sha-256
# Apps on the "$network" Docker network.
host     all       all   $subnet  scram-sha-256
# Everyone else: TLS only. ufw limits who gets this far.
hostssl  all       all   0.0.0.0/0          $remote_auth
hostssl  all       all   ::/0               $remote_auth
EOF
chmod 644 "$INSTALL_DIR/conf/pg_hba.conf"

( umask 077; cat > "$ENV_FILE" <<EOF
# Shared PostgreSQL - generated by postgres-docker-install.sh
# Read by docker compose (--env-file) and by the backup, restore and manage scripts.
COMPOSE_PROJECT_NAME=$PROJECT_NAME
POSTGRES_IMAGE=$image
PG_DOMAIN=$domain
PG_CERT_IP=$cert_ip
PG_PORT=$port
PG_NETWORK=$network
PG_SUBNET=$subnet
PG_GATEWAY=$gateway
PG_CLIENT_CERT=$client_cert

# Superuser "postgres". Only applied when the data volume is first created;
# postgres-docker-manage.sh option 3 changes it in the database and here.
POSTGRES_PASSWORD='$password'
EOF
)

dc() { docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
dc config -q || _die "docker-compose.yml did not validate with this .env."

# ── Image, and the server key's owner ─────────────────────────────────────────
echo "==> Pulling $image"
dc pull -q
# Postgres only accepts a key owned by itself (0600) or by root (0640, group
# readable). Root plus the image's own postgres group, set from inside the
# image, so the group id is always the one the server runs as.
docker run --rm --entrypoint sh -v "$INSTALL_DIR/certs:/certs" "$image" \
  -c 'chown root:postgres /certs/server.key && chmod 640 /certs/server.key'

# ── Firewall ──────────────────────────────────────────────────────────────────
echo "==> ufw rules for port $port"
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow in on "$iface" from "$subnet" to any port "$port" proto tcp comment "postgres $domain - docker apps"
  for src in $remote; do
    if [[ "$src" == any ]]; then
      sudo ufw allow "$port/tcp" comment "postgres $domain - remote"
    else
      sudo ufw allow from "$src" to any port "$port" proto tcp comment "postgres $domain - remote"
    fi
  done
  if ! sudo ufw status | grep -q '^Status: active'; then
    echo "WARNING: ufw is inactive - the rules are saved but port $port is open to everyone."
    echo "         Allow SSH first, then turn it on: sudo ufw allow OpenSSH && sudo ufw enable"
  fi
else
  echo "WARNING: ufw is not installed, so nothing on this host filters port $port."
  echo "         Remote logins still need TLS + password$([[ "$client_cert" == yes ]] && echo " + client certificate")."
fi

# ── Start ─────────────────────────────────────────────────────────────────────
echo "==> Starting PostgreSQL"
dc up -d
echo -n "==> Waiting for it to become healthy"
status=""
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q postgres)" 2>/dev/null || true)"
  [[ "$status" == healthy ]] && break
  echo -n "."
  sleep 3
done
echo ""
[[ "$status" == healthy ]] || _die "PostgreSQL did not become healthy. Check: cd $INSTALL_DIR && docker compose logs postgres"

# The remote path end to end - TLS, the server certificate checked against the
# domain, the client certificate and the password - from this host's outward
# address, which pg_hba treats like any remote client.
host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i == "src") {print $(i+1); exit}}' || true)"
if [[ -n "$host_ip" ]]; then
  if out="$(PGPASSWORD="$password" docker run --rm --network host -e PGPASSWORD --user "$(id -u):$(id -g)" \
      -v "$INSTALL_DIR/clients/postgres:/client:ro" "$image" psql -X -At \
      "host=$domain hostaddr=$host_ip port=$port dbname=postgres user=postgres sslmode=verify-full sslrootcert=/client/ca.crt sslcert=/client/client.crt sslkey=/client/client.key" \
      -c 'SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()' 2>&1)"; then
    echo "==> Remote login check passed ($out, certificate verified for $domain)"
  else
    echo "WARNING: the remote login check against $host_ip failed:"
    echo "$out" | sed 's/^/         /'
  fi
fi

# ── Nightly backup ────────────────────────────────────────────────────────────
echo ""
read -rp "Add a nightly backup (02:30, keeps 7) to your crontab? [Y/n] " ans
if [[ ! "$ans" =~ ^[Nn]$ ]]; then
  [ -d "$DEFAULT_BACKUP_ROOT" ] || sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$DEFAULT_BACKUP_ROOT"
  [ -w "$DEFAULT_BACKUP_ROOT" ] || echo "WARNING: $DEFAULT_BACKUP_ROOT is not writable by $(id -un) - the job will fail until it is."
  line="30 2 * * * POSTGRES_BACKUP_ROOT=$DEFAULT_BACKUP_ROOT POSTGRES_INSTANCE_DIR=$INSTALL_DIR $SCRIPT_DIR/postgres-docker-backup.sh >> $HOME/postgres-backup.log 2>&1"
  { crontab -l 2>/dev/null | grep -vF "POSTGRES_INSTANCE_DIR=$INSTALL_DIR " || true; echo "$line"; } | crontab -
  echo "==> Scheduled. Log: $HOME/postgres-backup.log"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> PostgreSQL is running."
echo "    Install dir  : $INSTALL_DIR"
echo "    Superuser    : postgres / $password   (kept in .env, mode 600)"
echo "    This host    : 127.0.0.1:$port"
echo "    Docker apps  : join network '$network', connect to $gateway:$port"
echo "    Remote       : $domain:$port, TLS + password$([[ "$client_cert" == yes ]] && echo " + client certificate")"
echo ""
echo "    Log in from your machine - copy the superuser's bundle there first:"
echo "      scp -r $(id -un)@$domain:$INSTALL_DIR/clients/postgres ./pg-postgres"
echo "      psql \"host=$domain port=$port dbname=postgres user=postgres sslmode=verify-full sslrootcert=pg-postgres/ca.crt sslcert=pg-postgres/client.crt sslkey=pg-postgres/client.key\""
echo ""
echo "    Add an app (database, role, connection strings, certificate):"
echo "      $SCRIPT_DIR/postgres-docker-manage.sh"
echo "    Back up / restore:"
echo "      $SCRIPT_DIR/postgres-docker-backup.sh"
echo "      $SCRIPT_DIR/postgres-docker-restore.sh"
if [[ "$MODE" == 2 ]]; then
  echo ""
  echo "    The database is still empty. Bring the data back with"
  echo "    postgres-docker-restore.sh, option 2 (roles + every database)."
fi
echo ""
