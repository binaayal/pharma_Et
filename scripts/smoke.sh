#!/usr/bin/env bash
# Staging smoke test — the walking skeleton, exercised over HTTP against a deployed API.
#
# It is the same journey the Flutter integration test drives, reduced to what can be checked
# from outside: sign in, pull reference data, push a batch of sales, replay that batch and
# get `duplicate` back, read them on the dashboard endpoint, and confirm the second tenant
# sees none of it.
#
# Run it against anything: a container, CI, or the real staging URL.
#   ./scripts/smoke.sh https://pharmaet-staging.fly.dev/api
set -euo pipefail

API="${1:-${API_BASE_URL:-http://localhost:3000/api}}"
PASS=0
FAIL=0

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $3, got $2)"; fi; }

jqp() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

say "1. health"
HEALTH=$(curl -fsS "$API/health")
check "status is ok" "$(printf '%s' "$HEALTH" | jqp "d['status']")" "ok"
CONTRACT=$(printf '%s' "$HEALTH" | jqp "d['contractVersion']")
ok "serving contract v$CONTRACT"

say "2. sign in (abay cashier)"
LOGIN=$(curl -fsS -X POST "$API/auth/login" -H 'content-type: application/json' \
  -d '{"tenantCode":"abay","username":"cashier","secret":"1234","terminalId":"01930000-0000-7000-8000-00000000d00a"}')
TOKEN=$(printf '%s' "$LOGIN" | jqp "d['accessToken']")
TENANT=$(printf '%s' "$LOGIN" | jqp "d['scope']['tenantId']")
CASHIER=$(printf '%s' "$LOGIN" | jqp "d['scope']['userId']")
BRANCH=$(printf '%s' "$LOGIN" | jqp "d['scope']['branchIds'][0]")
[ -n "$TOKEN" ] && ok "issued an access token" || bad "no access token"

say "3. pull reference data"
PULL=$(curl -fsS "$API/sync/pull?cursor=0" -H "authorization: Bearer $TOKEN")
PRODUCTS=$(printf '%s' "$PULL" | jqp "len(d['products'])")
[ "$PRODUCTS" -gt 0 ] && ok "$PRODUCTS products, $(printf '%s' "$PULL" | jqp "len(d['stockBatches'])") stock batches" \
                      || bad "pull returned no products"
PRODUCT=$(printf '%s' "$PULL" | jqp "[p for p in d['products'] if not p['isControlled']][0]['id']")
PRICE=$(printf '%s'   "$PULL" | jqp "[p for p in d['products'] if not p['isControlled']][0]['currentPriceSantim']")
BATCH=$(printf '%s'   "$PULL" | jqp "(lambda b: b[0]['id'] if b else None)(sorted([x for x in d['stockBatches'] if x['productId']=='$PRODUCT'], key=lambda x: x['expiryDate']))")

say "4. push three sales"
PUSH=$(python3 - "$TENANT" "$BRANCH" "$CASHIER" "$PRODUCT" "$BATCH" "$PRICE" <<'PY'
import json, sys, time, os
tenant, branch, cashier, product, batch, price = sys.argv[1:7]
price = int(price)
stamp = int(time.time())
def u7(n):
    return '01a0%04x-%04x-7%03x-8000-%012x' % (stamp % 0xffff, os.getpid() % 0xffff, n, n)
ops = []
for i in range(3):
    ops.append({
        "opId": u7(400 + i), "terminalId": "01930000-0000-7000-8000-00000000d00a",
        "terminalSeq": stamp * 10 + i, "entityId": u7(100 + i), "opType": "create",
        "baseVersion": None, "tenantId": tenant, "branchId": branch, "actorId": cashier,
        "clientTs": "2026-09-23T08:30:0%d.000Z" % i,
        "entityType": "sale",
        "payload": {
            "shiftId": None, "cashierId": cashier,
            "soldAt": "2026-09-23T08:30:0%d.000Z" % i,
            "totalSantim": price * 2,
            "lines": [{"id": u7(200 + i), "productId": product,
                       "batchId": None if batch in ("None", "") else batch,
                       "qty": 2, "unitPriceSantim": price, "lineTotalSantim": price * 2}],
            "payments": [{"id": u7(300 + i), "method": "cash", "amountSantim": price * 2}],
        },
    })
print(json.dumps({"terminalId": "01930000-0000-7000-8000-00000000d00a", "operations": ops}))
PY
)
ACKS=$(curl -fsS -X POST "$API/sync/push" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d "$PUSH")
check "all three applied" "$(printf '%s' "$ACKS" | jqp "','.join(a['status'] for a in d['acks'])")" "applied,applied,applied"

say "5. replay the identical batch (idempotency, AC-9.2)"
REPLAY=$(curl -fsS -X POST "$API/sync/push" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d "$PUSH")
check "all three duplicate, none re-applied" \
  "$(printf '%s' "$REPLAY" | jqp "','.join(a['status'] for a in d['acks'])")" "duplicate,duplicate,duplicate"

say "6. owner reads them back"
OWNER=$(curl -fsS -X POST "$API/auth/login" -H 'content-type: application/json' \
  -d '{"tenantCode":"abay","username":"owner","secret":"owner-dev-password","terminalId":"01930000-0000-7000-8000-00000000d00b"}')
OTOKEN=$(printf '%s' "$OWNER" | jqp "d['accessToken']")
SALES=$(curl -fsS "$API/reports/sales" -H "authorization: Bearer $OTOKEN")
COUNT=$(printf '%s' "$SALES" | jqp "len(d)")
[ "$COUNT" -ge 3 ] && ok "$COUNT sales visible to the owner" || bad "owner sees only $COUNT sales"

say "7. tenant isolation (G1)"
TANA=$(curl -fsS -X POST "$API/auth/login" -H 'content-type: application/json' \
  -d '{"tenantCode":"tana","username":"owner","secret":"owner-dev-password","terminalId":"01930000-0000-7000-8000-00000000d00c"}')
TTOKEN=$(printf '%s' "$TANA" | jqp "d['accessToken']")
check "the other tenant sees none of them" \
  "$(curl -fsS "$API/reports/sales" -H "authorization: Bearer $TTOKEN" | jqp "len(d)")" "0"

say "8. authorization (FR-2 matrix)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API/reports/sales" -H "authorization: Bearer $TOKEN")
check "cashier denied the tenant-wide report" "$CODE" "403"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API/sync/pull?cursor=0")
check "unauthenticated pull refused" "$CODE" "401"

say "9. contract compatibility (ADR-009)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API/sync/pull?cursor=0" \
  -H "authorization: Bearer $TOKEN" -H "x-contract-version: $CONTRACT")
check "current contract accepted" "$CODE" "200"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API/sync/pull?cursor=0" \
  -H "authorization: Bearer $TOKEN" -H "x-contract-version: 99.0.0")
check "unknown contract refused loudly" "$CODE" "400"

say "10. security response headers (NFR-4.3)"
HEADERS=$(curl -sI "$API/health")
for H in "x-content-type-options: nosniff" "x-frame-options: DENY" \
         "referrer-policy: no-referrer" "cross-origin-opener-policy: same-origin"; do
  if printf '%s' "$HEADERS" | tr 'A-Z' 'a-z' | grep -qi "^${H%%:*}:"; then
    ok "${H%%:*} present"
  else
    bad "${H%%:*} missing"
  fi
done

say "11. login throttling (NFR-4.2, ADR-017)"
# Six attempts against a username that does NOT exist — which is the case worth smoking.
# Counting attempts on names that are not real is what stops "throttled" meaning "this
# account exists" (ADR-017). Five are answered; the sixth is refused.
for i in 1 2 3 4 5 6; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/auth/login" \
    -H 'content-type: application/json' \
    -d "{\"tenantCode\":\"abay\",\"username\":\"smoke-throttle\",\"secret\":\"000$i\",\"terminalId\":\"01930000-0000-7000-8000-00000000d00d\"}")
done
check "a sixth attempt is throttled" "$CODE" "429"
# And the shop is still open — the property ADR-017 exists to protect.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/auth/login" \
  -H 'content-type: application/json' \
  -d '{"tenantCode":"abay","username":"owner","secret":"owner-dev-password","terminalId":"01930000-0000-7000-8000-00000000d00e"}')
check "another user signs in regardless (no tenant lockout)" "$CODE" "200"

printf '\n\033[1m%s\033[0m\n' "smoke: $PASS passed, $FAIL failed  ($API)"
[ "$FAIL" -eq 0 ]
