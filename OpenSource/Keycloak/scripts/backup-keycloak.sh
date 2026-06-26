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
BACKUP_DIR="$PROJECT_DIR/backup/keycloak"

CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format "{{.Name}}" keycloak 2>/dev/null | head -n1)

if [ -z "$CONTAINER" ]; then
  echo "Error: keycloak service is not running."
  exit 1
fi

echo ""
echo "Domain    : $KEYCLOAK_URL"
echo "Container : $CONTAINER"
read -rp "Proceed with backup? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
BASE_URL="https://${KEYCLOAK_URL}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "Fetching admin token..."
TOKEN=$(curl -sf -X POST "${BASE_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
  | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Error: Failed to obtain access token. Check credentials and that Keycloak is running."
  exit 1
fi

echo "Fetching realm list..."
REALMS=$(curl -sf "${BASE_URL}/admin/realms" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[].realm')

for REALM in $REALMS; do
  BACKUP_FILE="$BACKUP_DIR/${DOMAIN_SLUG}_${REALM}_${TIMESTAMP}.json"
  echo "Exporting realm: $REALM"
  curl -sf -X POST "${BASE_URL}/admin/realms/${REALM}/partial-export?exportClients=true&exportGroupsAndRoles=true" \
    -H "Authorization: Bearer $TOKEN" \
    | jq . > "$BACKUP_FILE"
  echo "  Saved: $BACKUP_FILE"
done

# Retain last 7 days
find "$BACKUP_DIR" -name "${DOMAIN_SLUG}_*.json" -mtime +7 -delete

echo "Keycloak backup complete."
