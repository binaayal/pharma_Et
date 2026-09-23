#!/usr/bin/env bash
# Local PostgreSQL for development and integration tests.
#
# Integration tests run against real PostgreSQL, never a mock: RLS, constraints and
# SET LOCAL scoping are the things under test, and a mocked database exercises none
# of them (docs/05-qa-and-test-strategy.md §5).
set -euo pipefail

CONTAINER=pharmaet-dev-db
IMAGE=postgres:16-alpine
PORT=5433
DB=pharmaet_dev
USER=pharmaet
PASSWORD=pharmaet_dev_password

docker_cmd() { docker "$@"; }

usage() {
  cat <<USAGE
Usage: ./scripts/dev-db.sh <command>

  up      start PostgreSQL 16 on localhost:${PORT} (idempotent)
  down    stop and remove the container (data is discarded)
  reset   down, then up, then wait for readiness
  psql    open a psql shell on ${DB}
  logs    follow container logs
  status  show whether it is running
USAGE
}

wait_ready() {
  printf 'waiting for postgres'
  for _ in $(seq 1 60); do
    if docker_cmd exec "$CONTAINER" pg_isready -U "$USER" -d "$DB" >/dev/null 2>&1; then
      printf ' ready\n'
      return 0
    fi
    printf '.'
    sleep 1
  done
  printf '\ntimed out waiting for postgres\n' >&2
  return 1
}

cmd_up() {
  if docker_cmd ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker_cmd start "$CONTAINER" >/dev/null
    echo "started existing container ${CONTAINER}"
  else
    docker_cmd run -d \
      --name "$CONTAINER" \
      -e POSTGRES_USER="$USER" \
      -e POSTGRES_PASSWORD="$PASSWORD" \
      -e POSTGRES_DB="$DB" \
      -p "${PORT}:5432" \
      "$IMAGE" >/dev/null
    echo "created container ${CONTAINER} (${IMAGE})"
  fi
  wait_ready
  cat <<INFO

  DATABASE_URL=postgres://${USER}:${PASSWORD}@localhost:${PORT}/${DB}

INFO
}

cmd_down() {
  docker_cmd rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo "removed ${CONTAINER}"
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  reset)  cmd_down; cmd_up ;;
  psql)   docker_cmd exec -it "$CONTAINER" psql -U "$USER" -d "$DB" ;;
  logs)   docker_cmd logs -f "$CONTAINER" ;;
  status) docker_cmd ps --filter "name=${CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
  *)      usage; exit 1 ;;
esac
