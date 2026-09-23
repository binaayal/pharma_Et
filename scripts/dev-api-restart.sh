#!/usr/bin/env bash
# Rebuild and restart the API detached, for scripted verification.
# Kills by listening port rather than by command pattern: `pkill -f dist/main.js` also
# matches the shell that is running the pkill, which makes it quietly suicidal.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=${PORT:-3000}
PID=$(ss -lptn "sport = :${PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)
[ -n "${PID}" ] && kill "${PID}" && sleep 1
# Build through the workspace script, not `npx nest build` from here: the Nest CLI
# resolves nest-cli.json relative to the current directory and silently exits 0 having
# built nothing when it cannot find one.
pnpm --filter @pharmaet/api build >/dev/null
LOG=${API_LOG:-/tmp/pharmaet-api.log}
(cd apps/api && setsid node dist/main.js > "${LOG}" 2>&1 < /dev/null &)
for _ in $(seq 1 30); do
  sleep 1
  curl -sf "http://localhost:${PORT}/api/health" >/dev/null 2>&1 && { echo "api up on :${PORT}"; exit 0; }
done
echo "api failed to start; see ${LOG}" >&2
tail -20 "${LOG}" >&2
exit 1
