#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.external-cert.yml"
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${KEYCLOAK_USER:?KEYCLOAK_USER is not set}"
: "${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD is not set}"
: "${KEYCLOAK_URL:?KEYCLOAK_URL is not set}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: apt install jq"
  exit 1
fi

DOMAIN_SLUG=$(echo "$KEYCLOAK_URL" | tr '.' '_')

CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format "{{.Name}}" keycloak 2>/dev/null | head -n1)

if [ -z "$CONTAINER" ]; then
  echo "Error: keycloak service is not running."
  exit 1
fi

DEFAULT_DIR="$PROJECT_DIR/backup/keycloak"
read -rp "Enter backup directory [$DEFAULT_DIR]: " BACKUP_DIR
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_DIR}"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Directory not found: $BACKUP_DIR"
  exit 1
fi

mapfile -t FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name "${DOMAIN_SLUG}_*.json" | sort -r)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No backups found for domain '$KEYCLOAK_URL' in $BACKUP_DIR"
  exit 1
fi

echo ""
echo "Domain    : $KEYCLOAK_URL"
echo "Container : $CONTAINER"
echo ""
echo "Available backups:"
for i in "${!FILES[@]}"; do
  echo "  [$((i+1))] $(basename "${FILES[$i]}")"
done
echo ""

read -rp "Select backup (1-${#FILES[@]}): " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt ${#FILES[@]} ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED="${FILES[$((SELECTION-1))]}"
REALM=$(jq -r '.realm' "$SELECTED")

if [ "$REALM" = "master" ]; then
  echo ""
  echo "The master realm cannot be restored via realm import."
  echo "Use restore-postgres.sh to do a full database restore instead."
  exit 1
fi

echo ""
echo "Backup    : $(basename "$SELECTED") (realm: $REALM)"
read -rp "This will delete and reimport realm '$REALM'. Continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

BASE_URL="https://${KEYCLOAK_URL}"

echo "Fetching admin token..."
TOKEN=$(curl -sf -X POST "${BASE_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
  | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Error: Failed to obtain access token. Check credentials and that Keycloak is running."
  exit 1
fi

# Delete existing realm if it exists
HTTP_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/admin/realms/${REALM}" \
  -H "Authorization: Bearer $TOKEN")

if [ "$HTTP_CHECK" = "200" ]; then
  echo "Deleting existing realm '$REALM'..."
  curl -sf -X DELETE "${BASE_URL}/admin/realms/${REALM}" \
    -H "Authorization: Bearer $TOKEN"
fi

echo "Importing realm..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/admin/realms" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$SELECTED")

if [ "$HTTP_STATUS" = "201" ]; then
  echo "Realm '$REALM' restored successfully."
else
  echo "Import failed with HTTP status $HTTP_STATUS."
  exit 1
fi
