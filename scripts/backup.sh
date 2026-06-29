#!/usr/bin/env bash
#
# backup.sh — snapshot the n8n stack's state to ./backups/<timestamp>/
#   - Postgres logical dump (workflows, credentials, execution history)
#   - n8n data volume tarball (config, encryption key file)
#
# NOTE: The N8N_ENCRYPTION_KEY itself should ALSO live in your password
# manager / vault, independent of these backups. A dump without the matching
# key is undecryptable.
set -euo pipefail

cd "$(dirname "$0")/.."          # run from repo root regardless of cwd
set -a; source .env; set +a      # load POSTGRES_* etc.

TS="$(date +%Y%m%d-%H%M%S)"
DEST="backups/${TS}"
mkdir -p "$DEST"

echo "[1/2] Dumping Postgres -> ${DEST}/n8n-postgres.dump"
docker compose exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
  > "${DEST}/n8n-postgres.dump"

echo "[2/2] Archiving n8n data volume -> ${DEST}/n8n-data.tar.gz"
# Mount the named volume into a throwaway container and tar its contents.
docker run --rm \
  -v n8n-stack_n8n_data:/data:ro \
  -v "$(pwd)/${DEST}:/backup" \
  alpine \
  tar czf /backup/n8n-data.tar.gz -C /data .

echo "Done. Backup at ${DEST}"
echo "Reminder: confirm N8N_ENCRYPTION_KEY is stored in your vault."
