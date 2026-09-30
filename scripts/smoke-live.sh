#!/usr/bin/env bash
# Read-only smoke test for the LIVE environment (docs/engineering/hosting.md).
#
#   ./scripts/smoke-live.sh https://pharmaet.onrender.com [expected-commit]
#
# scripts/smoke.sh signs in as the demo pharmacy and pushes sales — right for the CD
# verification stack, wrong for a server holding real pharmacies' books. This one writes
# nothing: every request is a GET, or a request the server must refuse.
set -euo pipefail

SITE="${1:?usage: smoke-live.sh <site-url> [expected-commit]}"
SITE="${SITE%/}"
API="$SITE/api"
EXPECT="${2:-}"
FAILED=0

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

say "1. health and version"
HEALTH=$(curl -fsS "$API/health")
echo "  $HEALTH"
printf '%s' "$HEALTH" | grep -q '"status":"ok"' && ok "healthy" || bad "not healthy"
if [ -n "$EXPECT" ]; then
  printf '%s' "$HEALTH" | grep -q "\"commit\":\"$EXPECT\"" \
    && ok "serving $EXPECT" || bad "not serving $EXPECT"
fi

say "2. HTTPS and headers"
HEADERS=$(curl -sI "$API/health" | tr 'A-Z' 'a-z')
for H in strict-transport-security content-security-policy x-content-type-options x-frame-options; do
  printf '%s' "$HEADERS" | grep -q "^$H:" && ok "$H" || bad "$H missing"
done
printf '%s' "$HEADERS" | grep -q "^x-powered-by:" && bad "x-powered-by present" || ok "no x-powered-by"

say "3. the API refuses what it should"
[ "$(code "$API/reports/sales")" = "401" ] && ok "tenant route needs a token" || bad "tenant route not protected"
[ "$(code "$API/platform/tenants")" = "401" ] && ok "platform route needs a session" || bad "platform route not protected"
[ "$(code "$API/nope")" = "404" ] && ok "unknown API route 404s" || bad "unknown API route did not 404"

say "4. the console and the public pages"
curl -fsS "$SITE/" | grep -q '<div id="root">' && ok "console served" || bad "console missing"
for P in privacy delete-account; do
  [ "$(code "$SITE/$P")" = "200" ] && ok "/$P" || bad "/$P missing"
done

[ "$FAILED" = "0" ] && printf '\n\033[32mlive smoke passed\033[0m\n' || { printf '\n\033[31mlive smoke FAILED\033[0m\n'; exit 1; }
