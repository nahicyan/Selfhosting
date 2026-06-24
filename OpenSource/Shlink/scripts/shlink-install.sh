#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_CONF_SRC="$SCRIPT_DIR/../shlink-backend-nginx.conf"
FRONTEND_CONF_SRC="$SCRIPT_DIR/../shlink-frontend-nginx.conf"
SHLINK_BASE="/var/www/docker/shlink"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Ask for a value only if the named variable is currently empty
_fill() {
  local -n _ref="$1"
  local prompt="$2"
  if [[ -z "${_ref:-}" ]]; then
    read -rp "$prompt" _ref
  fi
}

_fill_secret() {
  local -n _ref="$1"
  local prompt="$2"
  if [[ -z "${_ref:-}" ]]; then
    read -rsp "$prompt" _ref
    echo
  fi
}

# Print [✓] or [✗] status for a named variable
_status() {
  if [[ -n "${!1:-}" ]]; then
    echo "  [✓] $1 = ${!1}"
  else
    echo "  [✗] $1  (missing — will ask)"
  fi
}

# ── Mode selection ────────────────────────────────────────────────────────────
echo ""
echo "=====> Shlink Install"
echo "========================================"
echo "  1) New instance"
echo "  2) Restore from backup"
echo ""
read -rp "Select [1/2]: " mode_choice
echo ""

case "$mode_choice" in
  1) IS_NEW=true  ;;
  2) IS_NEW=false ;;
  *) echo "ERROR: Invalid selection."; exit 1 ;;
esac

# ── Initialize all variables ──────────────────────────────────────────────────
backend_domain=""
frontend_domain=""
backend_port=""
frontend_port=""
tz=""
geolite_key=""
db_name=""
db_user=""
db_password=""
db_root_password=""
server_name=""
api_key=""
selected_sql=""

# ── Restore path: load backup folder ─────────────────────────────────────────
if [[ "$IS_NEW" == "false" ]]; then
  # ── 1. Choose backup base directory ────────────────────────
  echo "Choose the directory where your backup files are located:"
  echo "  1) Default: /home/backup"
  echo "  2) Custom path"
  read -rp "Select [1/2]: " backup_base_choice

  if [ "$backup_base_choice" = "2" ]; then
    read -rep "Enter custom backup base path: " backup_base
    backup_base="${backup_base/#\~/$HOME}"
  else
    backup_base="/home/backup"
  fi

  [[ -d "$backup_base" ]] || { echo "ERROR: '$backup_base' not found."; exit 1; }
  echo ""

  # ── 2. Select domain ───────────────────────────────────────
  mapfile -t shlink_domain_dirs < <(find "$backup_base" -maxdepth 1 -type d -name "shlink-*" | sort)

  if [ ${#shlink_domain_dirs[@]} -eq 0 ]; then
    echo "ERROR: No shlink-* backup folders found in '$backup_base'."
    exit 1
  fi

  if [ ${#shlink_domain_dirs[@]} -eq 1 ]; then
    shlink_domain_dir="${shlink_domain_dirs[0]}"
    echo "Using backup folder: $(basename "$shlink_domain_dir")"
  else
    echo "Found backup folders:"
    for i in "${!shlink_domain_dirs[@]}"; do
      echo "  $((i+1))) $(basename "${shlink_domain_dirs[$i]}")"
    done
    echo ""
    read -rp "Select domain number: " dom_num
    if ! [[ "$dom_num" =~ ^[0-9]+$ ]] || [ "$dom_num" -lt 1 ] || [ "$dom_num" -gt "${#shlink_domain_dirs[@]}" ]; then
      echo "Invalid selection."
      exit 1
    fi
    shlink_domain_dir="${shlink_domain_dirs[$((dom_num-1))]}"
  fi

  # ── 3. List available backups ──────────────────────────────
  _nice_date() {
    local stamp="$1"
    IFS='-' read -r yr mo dy hr mn sc <<< "$stamp"
    date -d "${yr}-${mo}-${dy} ${hr}:${mn}:${sc}" "+%B %-d, %Y, %I:%M %p" 2>/dev/null || echo "$stamp"
  }

  mapfile -t timestamps < <(find "$shlink_domain_dir" -maxdepth 1 -mindepth 1 -type d | sort -r)

  if [ ${#timestamps[@]} -eq 0 ]; then
    echo "ERROR: No backup snapshots found in '$(basename "$shlink_domain_dir")'."
    exit 1
  fi

  echo ""
  printf "  %-4s %-33s %-8s %-8s\n" "#" "Date" "SQL" "Config"
  printf "  %-4s %-33s %-8s %-8s\n" "----" "---------------------------------" "--------" "--------"

  for i in "${!timestamps[@]}"; do
    stamp=$(basename "${timestamps[$i]}")
    nice=$(_nice_date "$stamp")
    sql_c=$(find "${timestamps[$i]}" -maxdepth 1 -name "*.sql" | head -1)
    txt_c=$(find "${timestamps[$i]}" -maxdepth 1 -name "shlink-*.txt" | head -1)
    sql_s=$( [ -n "$sql_c" ] && echo "ok" || echo "--" )
    txt_s=$( [ -n "$txt_c" ] && echo "ok" || echo "--" )
    printf "  %-4s %-33s %-8s %-8s\n" "$((i+1)))" "$nice" "$sql_s" "$txt_s"
  done

  echo ""
  read -rp "Select backup number to restore: " ts_num

  if ! [[ "$ts_num" =~ ^[0-9]+$ ]] || [ "$ts_num" -lt 1 ] || [ "$ts_num" -gt "${#timestamps[@]}" ]; then
    echo "Invalid selection."
    exit 1
  fi

  backup_folder="${timestamps[$((ts_num-1))]}"

  # ── Validate selected backup ───────────────────────────────
  config_file=$(find "$backup_folder" -maxdepth 1 -name "shlink-*.txt" | sort | head -1 || true)
  mapfile -t sql_files < <(find "$backup_folder" -maxdepth 1 -name "*.sql" | sort)

  if [ ${#sql_files[@]} -eq 0 ]; then
    echo "ERROR: No .sql file found in the selected backup. Cannot restore."
    exit 1
  fi

  if [[ -z "$config_file" ]]; then
    echo ""
    echo "WARNING: No shlink-*.txt config file found in this backup."
    echo "         All configuration values will need to be entered manually."
    read -rp "Proceed without config file? [y/N]: " ans_no_config
    [[ "$ans_no_config" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    echo ""
  fi

  # ── Source config file and report variable status ──────────
  if [[ -n "$config_file" ]]; then
    echo "==> Loading config: $(basename "$config_file")..."
    # shellcheck disable=SC1090
    source "$config_file"
    echo ""
    echo "    Variable status:"
    _status backend_domain
    _status frontend_domain
    _status backend_port
    _status frontend_port
    _status tz
    _status geolite_key
    _status db_name
    _status db_user
    _status db_password
    _status db_root_password
    _status server_name
    _status api_key
    echo ""
  else
    echo "WARNING: No shlink-*.txt config file found — all variables will be asked."
    echo ""
  fi

  # ── Select SQL file ────────────────────────────────────────
  if [[ ${#sql_files[@]} -eq 1 ]]; then
    selected_sql="${sql_files[0]}"
    sql_size=$(du -sh "$selected_sql" | cut -f1)
    echo "==> SQL file: $(basename "$selected_sql")  [$sql_size]"
    echo ""
  else
    echo "Multiple SQL files found — select one to restore:"
    for i in "${!sql_files[@]}"; do
      sql_size=$(du -sh "${sql_files[$i]}" | cut -f1)
      echo "  $((i+1))) $(basename "${sql_files[$i]}")  [$sql_size]"
    done
    echo ""
    read -rp "Select SQL file number: " sql_num
    [[ "$sql_num" =~ ^[0-9]+$ ]] || { echo "Invalid selection."; exit 1; }
    [[ "$sql_num" -ge 1 && "$sql_num" -le "${#sql_files[@]}" ]] || { echo "Invalid selection."; exit 1; }
    selected_sql="${sql_files[$((sql_num-1))]}"
    echo ""
  fi
fi

# ── Collect any missing variables ─────────────────────────────────────────────
if [[ "$IS_NEW" == "true" ]]; then
  echo "==> Enter configuration for the new instance:"
else
  echo "==> Fill in any missing values (pre-filled from backup where available):"
fi
echo ""

_fill        backend_domain   "Backend (short-URL) domain      (e.g. go.example.com): "
_fill        frontend_domain  "Frontend (Web UI) domain         (e.g. ui.example.com): "
_fill        backend_port     "Backend host port                (default 8282): "
backend_port="${backend_port:-8282}"
_fill        frontend_port    "Frontend host port               (default 8280): "
frontend_port="${frontend_port:-8280}"
_fill        tz               "Timezone                         (e.g. America/Denver): "
_fill        geolite_key      "GeoLite2 license key             (leave blank to skip): "
_fill        db_name          "Database name                    (e.g. shlink): "
_fill        db_user          "Database user                    (e.g. shlink): "
_fill_secret db_password      "Database password: "
_fill_secret db_root_password "Database ROOT password: "
_fill        server_name      "Shlink server name               (e.g. My Shlink): "

# API key: restore only — ask if missing (new instance generates it later)
if [[ "$IS_NEW" == "false" && -z "${api_key:-}" ]]; then
  echo ""
  echo "  API key not found in backup config."
  read -rp "  Enter API key from the original instance: " api_key
fi

# ── Validation ────────────────────────────────────────────────────────────────
echo ""
[[ -n "$backend_domain" ]]   || { echo "ERROR: Backend domain is required.";  exit 1; }
[[ -n "$frontend_domain" ]]  || { echo "ERROR: Frontend domain is required."; exit 1; }
[[ -n "$tz" ]]               || { echo "ERROR: Timezone is required.";        exit 1; }
[[ -n "$db_name" ]]          || { echo "ERROR: Database name is required.";   exit 1; }
[[ -n "$db_user" ]]          || { echo "ERROR: Database user is required.";   exit 1; }
[[ -n "$db_password" ]]      || { echo "ERROR: Database password is required.";     exit 1; }
[[ -n "$db_root_password" ]] || { echo "ERROR: Database root password is required.";exit 1; }
[[ -n "$server_name" ]]      || { echo "ERROR: Server name is required.";     exit 1; }
[[ "$backend_port"  =~ ^[0-9]+$ ]] || { echo "ERROR: Backend port must be a number.";  exit 1; }
[[ "$frontend_port" =~ ^[0-9]+$ ]] || { echo "ERROR: Frontend port must be a number."; exit 1; }
if [[ "$IS_NEW" == "false" ]]; then
  [[ -n "$api_key" ]] || { echo "ERROR: API key is required for restore."; exit 1; }
fi

# ── Confirm before proceeding ─────────────────────────────────────────────────
echo "==> Configuration:"
echo "    Mode            : $( [[ "$IS_NEW" == "true" ]] && echo "New instance" || echo "Restore from backup" )"
echo "    Backend domain  : $backend_domain  (port $backend_port)"
echo "    Frontend domain : $frontend_domain (port $frontend_port)"
echo "    Timezone        : $tz"
echo "    GeoLite key     : ${geolite_key:-(none)}"
echo "    DB name / user  : $db_name / $db_user"
echo "    Server name     : $server_name"
if [[ "$IS_NEW" == "false" ]]; then
  echo "    API key         : $api_key"
  echo "    SQL restore     : $(basename "$selected_sql")"
fi
echo ""
read -rp "Proceed? [Y/n] " ans_proceed
[[ "$ans_proceed" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Prepare install directory ─────────────────────────────────────────────────
echo ""
INSTALL_DIR="${SHLINK_BASE}/$backend_domain"
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Write docker-compose.yaml ─────────────────────────────────────────────────
echo "==> Writing docker-compose.yaml..."
cat > docker-compose.yaml << EOF
services:
  shlink:
    image: shlinkio/shlink:stable
    restart: always
    container_name: shlink-backend
    environment:
      - TZ=${tz}
      - DEFAULT_DOMAIN=${backend_domain}
      - IS_HTTPS_ENABLED=true
      - GEOLITE_LICENSE_KEY=${geolite_key}
      - DB_DRIVER=maria
      - DB_USER=${db_user}
      - DB_NAME=${db_name}
      - DB_PASSWORD=${db_password}
      - DB_HOST=database
      - CORS_ALLOW_ORIGIN=https://${frontend_domain}
    depends_on:
      - database
    ports:
      - ${backend_port}:8080
    networks:
      - shlink-network

  database:
    image: mariadb:10.8
    restart: always
    container_name: shlink-database
    environment:
      - MARIADB_ROOT_PASSWORD=${db_root_password}
      - MARIADB_DATABASE=${db_name}
      - MARIADB_USER=${db_user}
      - MARIADB_PASSWORD=${db_password}
    volumes:
      - ./data:/var/lib/mysql
    networks:
      - shlink-network

  shlink-web-client:
    image: shlinkio/shlink-web-client
    restart: always
    container_name: shlink-web-client
    depends_on:
      - shlink
    ports:
      - ${frontend_port}:8080
    environment:
      - SHLINK_SERVER_URL=https://${backend_domain}
      - SHLINK_SERVER_API_KEY=PLACEHOLDER
      - SHLINK_SERVER_NAME=${server_name}
    networks:
      - shlink-network

networks:
  shlink-network:
    driver: bridge
EOF

read -rp "Review docker-compose.yaml before starting? [y/N] " ans_compose
[[ "$ans_compose" =~ ^[Yy]$ ]] && "${EDITOR:-vim}" docker-compose.yaml

# ── Start database + backend ──────────────────────────────────────────────────
echo ""
echo "==> Starting database and backend..."
docker compose up -d database shlink

echo "==> Waiting for database to be ready..."
until docker exec shlink-database mysqladmin ping \
      -u root -p"${db_root_password}" --silent 2>/dev/null; do
  echo "    Not ready yet, retrying in 3s..."
  sleep 3
done
echo "==> Database is ready."

# ── Restore SQL (restore mode only) ──────────────────────────────────────────
if [[ "$IS_NEW" == "false" ]]; then
  echo ""
  echo "==> Restoring database from: $(basename "$selected_sql")..."
  docker exec -i shlink-database \
    sh -c "exec mysql -u root -p\"${db_root_password}\" ${db_name}" < "$selected_sql"
  echo "==> Restore complete."
fi

# ── Restart backend (applies migrations) ─────────────────────────────────────
echo ""
echo "==> Restarting backend for migrations..."
docker compose restart shlink
echo "    Waiting for backend..."
sleep 8
echo "==> Backend ready."

# ── API key ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$IS_NEW" == "true" ]]; then
  echo "==> Generating API key..."
  keygen_output=$(docker exec shlink-backend shlink api-key:generate)
  echo ""
  echo "$keygen_output"
  echo ""
  api_key=$(echo "$keygen_output" | grep -oP '(?<=Generated API key: ")[^"]+' || true)

  if [[ -z "$api_key" ]]; then
    echo "WARNING: Could not auto-parse API key from the output above."
    read -rp "Enter the API key manually: " api_key
    [[ -n "$api_key" ]] || { echo "ERROR: API key cannot be empty."; exit 1; }
  fi
  echo "==> API key: $api_key"
else
  echo "==> Using API key from backup: $api_key"
fi

# ── Inject API key and bring up web client ────────────────────────────────────
echo "==> Updating compose file with API key..."
sed -i "s|SHLINK_SERVER_API_KEY=.*|SHLINK_SERVER_API_KEY=${api_key}|" docker-compose.yaml

echo "==> Starting web client..."
docker compose up -d shlink-web-client
echo "==> All containers running."

# ── Let's Encrypt ─────────────────────────────────────────────────────────────
echo ""
read -rp "Obtain Let's Encrypt cert for BACKEND  ($backend_domain)? [y/N] " ans_cert_be
[[ "$ans_cert_be" =~ ^[Yy]$ ]] && sudo certbot certonly --nginx -d "$backend_domain"

read -rp "Obtain Let's Encrypt cert for FRONTEND ($frontend_domain)? [y/N] " ans_cert_fe
[[ "$ans_cert_fe" =~ ^[Yy]$ ]] && sudo certbot certonly --nginx -d "$frontend_domain"

# ── Nginx ─────────────────────────────────────────────────────────────────────
NGINX_CHANGED=false

read -rp "Set up Nginx for BACKEND  ($backend_domain)? [y/N] " ans_nginx_be
if [[ "$ans_nginx_be" =~ ^[Yy]$ ]]; then
  BE_AVAIL="/etc/nginx/sites-available/$backend_domain"
  [[ -f "$BACKEND_CONF_SRC" ]] || { echo "ERROR: $BACKEND_CONF_SRC not found."; exit 1; }
  sudo cp "$BACKEND_CONF_SRC" "$BE_AVAIL"
  sudo sed -i \
    -e "s|go\.example\.com|$backend_domain|g" \
    -e "s|127\.0\.0\.1:8282|127.0.0.1:$backend_port|g" \
    "$BE_AVAIL"
  echo "==> Backend nginx config written to $BE_AVAIL"
  read -rp "Enable site (symlink to sites-enabled)? [y/N] " ans_link_be
  if [[ "$ans_link_be" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$BE_AVAIL" "/etc/nginx/sites-enabled/$backend_domain"
    echo "==> Symlink created."
  fi
  NGINX_CHANGED=true
fi

read -rp "Set up Nginx for FRONTEND ($frontend_domain)? [y/N] " ans_nginx_fe
if [[ "$ans_nginx_fe" =~ ^[Yy]$ ]]; then
  FE_AVAIL="/etc/nginx/sites-available/$frontend_domain"
  [[ -f "$FRONTEND_CONF_SRC" ]] || { echo "ERROR: $FRONTEND_CONF_SRC not found."; exit 1; }
  sudo cp "$FRONTEND_CONF_SRC" "$FE_AVAIL"
  sudo sed -i \
    -e "s|frontend-UI\.example\.com|$frontend_domain|g" \
    -e "s|127\.0\.0\.1:8280|127.0.0.1:$frontend_port|g" \
    "$FE_AVAIL"
  echo "==> Frontend nginx config written to $FE_AVAIL"
  read -rp "Enable site (symlink to sites-enabled)? [y/N] " ans_link_fe
  if [[ "$ans_link_fe" =~ ^[Yy]$ ]]; then
    sudo ln -sf "$FE_AVAIL" "/etc/nginx/sites-enabled/$frontend_domain"
    echo "==> Symlink created."
  fi
  NGINX_CHANGED=true
fi

if [[ "$NGINX_CHANGED" == "true" ]]; then
  echo "==> Testing Nginx configuration..."
  sudo nginx -t
  echo "==> Reloading Nginx..."
  sudo systemctl reload nginx
  echo "==> Nginx reloaded."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Shlink installation complete."
echo "    Backend  (short URLs) : https://$backend_domain"
echo "    Frontend (Web UI)     : https://$frontend_domain"
echo "    API key               : $api_key"
echo "    Compose directory     : $INSTALL_DIR"
