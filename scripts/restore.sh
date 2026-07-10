#!/usr/bin/env bash
#
# restore.sh <backup-dir> — rehydrate the stack from a backup made by backup.sh
#
# Usage:  ./scripts/restore.sh backups/20260629-101500
#
# PRECONDITION: the .env on THIS host must contain the SAME N8N_ENCRYPTION_KEY
# that was in use when the backup was taken. Without it, restored credentials
# decrypt to garbage. This script checks that the key is at least set.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:?Usage: ./scripts/restore.sh <backup-dir>}"
set -a; source .env; set +a

# Derive the Compose volume name exactly as Compose does (see backup.sh). On a
# fresh host the volume may not exist yet — that's fine, the restore below (and
# the later `docker compose up`) create it under this same name.
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"
N8N_VOL="${PROJECT}_n8n_data"

if [[ -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
  echo "ERROR: N8N_ENCRYPTION_KEY is not set in .env."
  echo "Retrieve the original key from your vault before restoring."
  exit 1
fi

echo "Bringing up Postgres only..."
docker compose up -d postgres
# Wait for health
until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  sleep 1
done

echo "[1/2] Restoring Postgres from ${SRC}/n8n-postgres.dump"
docker compose exec -T postgres \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  < "${SRC}/n8n-postgres.dump"

echo "[2/2] Restoring n8n data volume (${N8N_VOL}) from ${SRC}/n8n-data.tar.gz"
docker run --rm \
  -v "${N8N_VOL}:/data" \
  -v "$(pwd)/${SRC}:/backup:ro" \
  alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/n8n-data.tar.gz -C /data"

echo "Starting full stack..."
docker compose up -d
echo "Restore complete."
