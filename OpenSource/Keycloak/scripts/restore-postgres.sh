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

: "${POSTGRES_USER:?POSTGRES_USER is not set}"
: "${KEYCLOAK_URL:?KEYCLOAK_URL is not set}"

DOMAIN_SLUG=$(echo "$KEYCLOAK_URL" | tr '.' '_')

CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format "{{.Name}}" keycloak_postgres 2>/dev/null | head -n1)

if [ -z "$CONTAINER" ]; then
  echo "Error: keycloak_postgres service is not running."
  exit 1
fi

DEFAULT_DIR="$PROJECT_DIR/backup/postgres"
read -rp "Enter backup directory [$DEFAULT_DIR]: " BACKUP_DIR
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_DIR}"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Directory not found: $BACKUP_DIR"
  exit 1
fi

mapfile -t FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name "${DOMAIN_SLUG}_*.sql.gz" | sort -r)

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

echo ""
echo "Backup    : $(basename "$SELECTED")"
echo ""
echo "WARNING: This will stop Keycloak, wipe and restore the database, then restart Keycloak."
read -rp "Continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "Stopping Keycloak..."
docker compose -f "$COMPOSE_FILE" stop keycloak

echo "Dropping and recreating database..."
docker compose -f "$COMPOSE_FILE" exec -T keycloak_postgres psql -U "$POSTGRES_USER" postgres \
  -c "DROP DATABASE IF EXISTS keycloak;" \
  -c "CREATE DATABASE keycloak;"

echo "Restoring..."
gunzip -c "$SELECTED" | docker compose -f "$COMPOSE_FILE" exec -T keycloak_postgres psql -U "$POSTGRES_USER" keycloak

echo "Starting Keycloak..."
docker compose -f "$COMPOSE_FILE" start keycloak

echo "Restore complete."
