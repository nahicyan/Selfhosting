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
BACKUP_DIR="$PROJECT_DIR/backup/postgres"

CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format "{{.Name}}" keycloak_postgres 2>/dev/null | head -n1)

if [ -z "$CONTAINER" ]; then
  echo "Error: keycloak_postgres service is not running."
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
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${DOMAIN_SLUG}_${TIMESTAMP}.sql.gz"

echo "Starting PostgreSQL backup..."
docker compose -f "$COMPOSE_FILE" exec -T keycloak_postgres pg_dump -U "$POSTGRES_USER" keycloak | gzip > "$BACKUP_FILE"

# Retain last 7 days
find "$BACKUP_DIR" -name "${DOMAIN_SLUG}_*.sql.gz" -mtime +7 -delete

echo "Backup saved: $BACKUP_FILE"
