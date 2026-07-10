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

# Derive the Docker Compose volume name the SAME way Compose does: honour an
# explicit COMPOSE_PROJECT_NAME, else lower-case the project directory and strip
# anything outside [a-z0-9_-]. (Hardcoding a name here silently breaks the moment
# the directory is renamed — which is exactly the bug this replaces.)
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"
N8N_VOL="${PROJECT}_n8n_data"
if ! docker volume inspect "$N8N_VOL" >/dev/null 2>&1; then
  echo "ERROR: expected n8n data volume '$N8N_VOL' does not exist." >&2
  echo "Has the stack been started (docker compose up -d)? Volumes present:" >&2
  docker volume ls --format '  {{.Name}}' | grep -iE 'n8n|postgres' >&2 || true
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
DEST="backups/${TS}"
mkdir -p "$DEST"

echo "[1/2] Dumping Postgres -> ${DEST}/n8n-postgres.dump"
docker compose exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
  > "${DEST}/n8n-postgres.dump"

echo "[2/2] Archiving n8n data volume (${N8N_VOL}) -> ${DEST}/n8n-data.tar.gz"
# Mount the named volume into a throwaway container and tar its contents.
docker run --rm \
  -v "${N8N_VOL}:/data:ro" \
  -v "$(pwd)/${DEST}:/backup" \
  alpine \
  tar czf /backup/n8n-data.tar.gz -C /data .

echo "Done. Backup at ${DEST}"
echo "Reminder: confirm N8N_ENCRYPTION_KEY is stored in your vault."
