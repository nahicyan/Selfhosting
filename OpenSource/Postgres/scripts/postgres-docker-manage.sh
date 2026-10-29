#!/bin/bash
set -euo pipefail
# =============================================================================
# PostgreSQL (shared) Docker Manage Script
# =============================================================================
# Day-to-day work on an instance installed by postgres-docker-install.sh:
#   1) Add an app                 - login role + a database it owns, closed to
#                                   every other role, and its connection strings
#   2) Issue a client certificate - clients/<role>/ for remote logins (CN = role)
#   3) Reset a role's password    - generates a new one (postgres: .env as well)
#   4) Allow a remote address     - ufw rule for the Postgres port
#   5) Remove a remote address    - deletes that ufw rule
#   6) Status                     - databases, roles, certificates, ufw rules
#
# One role and one database per app, named the same: apps cannot read each
# other's data, and each one can be restored on its own.
# =============================================================================

PG_BASE="/var/www/docker/postgres"
CLIENT_DAYS=825    # keep in step with postgres-docker-install.sh

# ── Helpers ───────────────────────────────────────────────────────────────────

_die() { echo "ERROR: $*" >&2; exit 1; }

_env_get() {  # _env_get <file> <key>
  local v
  v="$(sed -n "s/^${2}=//p" "$1" | tail -n1)"
  if [[ "$v" == \'*\' || "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

_valid_source() { [[ "$1" == any || "$1" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; }

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
  echo "==> $d"
  echo "    ca.crt, client.crt, client.key (libpq/psql), client.pk8 (Java/DBeaver)"
  echo "    Expires: $(openssl x509 -noout -enddate -in "$d/client.crt" | cut -d= -f2)"
  echo "    Copy it to the client: scp -r $(id -un)@$DOMAIN:$d ./pg-$1"
}

_ask_role() {  # _ask_role <prompt> - sets ROLE
  read -rp "$1" ROLE
  [[ "$ROLE" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
    || _die "use lowercase letters, digits and _, starting with a letter or _ (max 63)."
}

_exists() {  # _exists pg_roles|pg_database <name>
  local col=rolname
  [[ "$1" == pg_database ]] && col=datname
  [[ "$(echo "SELECT 1 FROM $1 WHERE $col = :'n';" | sql -At -v n="$2")" == 1 ]]
}

# ── Instance ──────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || _die "docker is required."
command -v openssl >/dev/null 2>&1 || _die "openssl is required."

mapfile -t INSTANCES < <(find "$PG_BASE" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' 2>/dev/null | sort)
[ ${#INSTANCES[@]} -gt 0 ] || _die "no instances found in $PG_BASE."
if [ ${#INSTANCES[@]} -eq 1 ]; then
  INSTALL_DIR="${INSTANCES[0]}"
else
  for i in "${!INSTANCES[@]}"; do echo "  $((i+1))) $(basename "${INSTANCES[$i]}")"; done
  read -rp "Select instance number: " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#INSTANCES[@]} ] || _die "Invalid selection."
  INSTALL_DIR="${INSTANCES[$((n-1))]}"
fi
ENV_FILE="$INSTALL_DIR/.env"
CA_DIR="$INSTALL_DIR/ca"
[ -f "$ENV_FILE" ] || _die "$ENV_FILE not found."
DOMAIN="$(_env_get "$ENV_FILE" PG_DOMAIN)"
PORT="$(_env_get "$ENV_FILE" PG_PORT)"
NETWORK="$(_env_get "$ENV_FILE" PG_NETWORK)"
GATEWAY="$(_env_get "$ENV_FILE" PG_GATEWAY)"
CLIENT_CERT="$(_env_get "$ENV_FILE" PG_CLIENT_CERT)"

dc() { docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
pg()  { dc exec -T -u postgres postgres "$@" </dev/null; }
sql() { dc exec -T -u postgres postgres psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }

[ -n "$(dc ps -q --status running postgres 2>/dev/null)" ] || _die "the postgres service of $DOMAIN is not running."

echo ""
echo "=====> PostgreSQL Manage - $DOMAIN:$PORT"
echo "========================================"
echo "  1) Add an app (database + role)"
echo "  2) Issue a client certificate"
echo "  3) Reset a role's password"
echo "  4) Allow a remote address through ufw"
echo "  5) Remove a remote address from ufw"
echo "  6) Status"
read -rp "Select [1-6]: " ACTION
echo ""

case "$ACTION" in
  # ── Add an app ──────────────────────────────────────────────────────────────
  1)
    _ask_role "App name (becomes both the role and the database): "
    _exists pg_roles "$ROLE" && _die "role '$ROLE' already exists."
    _exists pg_database "$ROLE" && _die "database '$ROLE' already exists."
    pw="$(openssl rand -hex 24)"
    # The password goes in on stdin, never on a command line that ps can see.
    { printf '\\set pw %s\n' "$pw"; cat <<'SQL'
CREATE ROLE :"name" LOGIN PASSWORD :'pw';
CREATE DATABASE :"name" OWNER :"name";
REVOKE ALL ON DATABASE :"name" FROM PUBLIC;
SQL
    } | sql -v name="$ROLE"
    remote="postgres://$ROLE:$pw@$DOMAIN:$PORT/$ROLE?sslmode=verify-full&sslrootcert=ca.crt"
    [[ "$CLIENT_CERT" == yes ]] && remote+="&sslcert=client.crt&sslkey=client.key"
    cat <<EOF
==> App '$ROLE' created. Its password is shown once - put it in the app's own .env:
    $pw

    Docker app on this host - in its docker-compose.yml:
      services:
        app:
          environment:
            DATABASE_URL: postgres://$ROLE:$pw@postgres:$PORT/$ROLE
          extra_hosts:
            - "postgres:$GATEWAY"
          networks: [default, $NETWORK]
      networks:
        $NETWORK:
          external: true

    Process on this host : postgres://$ROLE:$pw@127.0.0.1:$PORT/$ROLE
    Remote               : $remote

EOF
    if [[ "$CLIENT_CERT" == yes ]]; then
      read -rp "Issue a client certificate for remote logins as '$ROLE' now? [y/N] " ans
      if [[ "$ans" =~ ^[Yy]$ ]]; then _client "$ROLE"; fi
    else
      echo "    Remote clients need $INSTALL_DIR/certs/ca.crt to verify the server."
    fi
    ;;

  # ── Client certificate ──────────────────────────────────────────────────────
  2)
    _ask_role "Role the certificate logs in as: "
    _exists pg_roles "$ROLE" || _die "role '$ROLE' does not exist."
    if [ -f "$INSTALL_DIR/clients/$ROLE/client.crt" ]; then
      read -rp "clients/$ROLE already has a certificate. Replace it? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
    _client "$ROLE"
    echo ""
    echo "    psql \"host=$DOMAIN port=$PORT dbname=$ROLE user=$ROLE sslmode=verify-full sslrootcert=pg-$ROLE/ca.crt sslcert=pg-$ROLE/client.crt sslkey=pg-$ROLE/client.key\""
    echo ""
    echo "    There is no revocation list: the old certificate stays valid until it"
    echo "    expires. To lock someone out, reset the role's password (option 3) -"
    echo "    remote logins need both."
    ;;

  # ── Password ────────────────────────────────────────────────────────────────
  3)
    _ask_role "Role: "
    _exists pg_roles "$ROLE" || _die "role '$ROLE' does not exist."
    read -rp "Every app logging in as '$ROLE' needs the new password. Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    pw="$(openssl rand -hex 24)"
    { printf '\\set pw %s\n' "$pw"; echo "ALTER ROLE :\"name\" PASSWORD :'pw';"; } | sql -v name="$ROLE"
    if [[ "$ROLE" == postgres ]]; then
      # GNU sed -i keeps the file's 600 mode.
      sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD='$pw'/" "$ENV_FILE"
      echo "==> Updated POSTGRES_PASSWORD in $ENV_FILE"
    fi
    echo "==> New password for '$ROLE': $pw"
    ;;

  # ── Firewall ────────────────────────────────────────────────────────────────
  4|5)
    command -v ufw >/dev/null 2>&1 || _die "ufw is not installed."
    read -rp "IP or CIDR ('any' = everyone): " src
    _valid_source "$src" || _die "'$src' is not an IP, CIDR or 'any'."
    if [[ "$src" == any ]]; then rule=("$PORT/tcp"); else rule=(from "$src" to any port "$PORT" proto tcp); fi
    if [[ "$ACTION" == 4 ]]; then
      sudo ufw allow "${rule[@]}" comment "postgres $DOMAIN - remote"
    else
      sudo ufw delete allow "${rule[@]}"
    fi
    ;;

  # ── Status ──────────────────────────────────────────────────────────────────
  6)
    pg psql -X -d postgres -c "SELECT d.datname AS database, pg_get_userbyid(d.datdba) AS owner,
        pg_size_pretty(pg_database_size(d.datname)) AS size,
        (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname) AS connections
      FROM pg_database d WHERE NOT d.datistemplate ORDER BY 1"
    pg psql -X -d postgres -c "SELECT rolname AS role, rolcanlogin AS login, rolsuper AS superuser
      FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1"
    echo "Server certificate expires: $(openssl x509 -noout -enddate -in "$INSTALL_DIR/certs/server.crt" | cut -d= -f2)"
    echo "Client certificates:"
    for crt in "$INSTALL_DIR"/clients/*/client.crt; do
      [ -f "$crt" ] || { echo "  none"; break; }
      printf "  %-24s expires %s\n" "$(basename "$(dirname "$crt")")" "$(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)"
    done
    echo "ufw rules for port $PORT:"
    if command -v ufw >/dev/null 2>&1; then
      sudo ufw status | grep -E "(^|[^0-9])$PORT(/tcp)?[[:space:]]" || echo "  none"
    else
      echo "  ufw is not installed"
    fi
    ;;

  *) _die "Invalid selection." ;;
esac
