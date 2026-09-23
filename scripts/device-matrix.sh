#!/usr/bin/env bash
# NFR-3.2 on real hardware (docs/05-qa §7, docs/06 §11).
#
# Runs the on-device latency test against every connected device and prints a markdown table.
# The device matrix is a GA gate, and it was the last thing standing between "we believe the
# offline-first payoff is real" and "we measured it on the hardware people will actually buy".
#
#   ./scripts/device-matrix.sh              # every connected device
#   ./scripts/device-matrix.sh <device-id>  # just one
#
# Paste the table it prints into docs/engineering/device-matrix.md, under the date you ran it.
set -euo pipefail

cd "$(dirname "$0")/.."
MOBILE="$PWD/apps/mobile"
OUT="${TMPDIR:-/tmp}/pharmaet-device-matrix"
mkdir -p "$OUT"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# Physical devices and emulators, but never the desktop or web targets: measuring SQLite on a
# developer's NVMe would answer a question nobody asked and answer it flatteringly.
mapfile -t DEVICES < <(
  cd "$MOBILE" && flutter devices --machine 2>/dev/null \
    | python3 -c "
import json, sys
try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    platform = d.get('targetPlatform', '')
    if platform.startswith('android') or platform.startswith('ios'):
        print('%s\t%s\t%s' % (d['id'], d.get('name', '?'), platform))
"
)

if [ "${1:-}" != "" ]; then
  DEVICES=("$(printf '%s\n' "${DEVICES[@]}" | grep "^$1	" || true)")
  [ -n "${DEVICES[0]}" ] || { echo "no such device: $1"; exit 1; }
fi

if [ "${#DEVICES[@]}" -eq 0 ] || [ -z "${DEVICES[0]}" ]; then
  warn "No Android or iOS device is connected."
  warn "NFR-3.2 is a device figure — docs/05-qa §7 asks for real low-end Android hardware,"
  warn "not an emulator on a fast machine. Connect a handset and run this again."
  exit 1
fi

RESULTS="$OUT/results.md"
{
  echo "| Device | Platform | add item p50/p95 | commit sale p50/p95 | loaded p95 | Verdict |"
  echo "|---|---|---|---|---|---|"
} > "$RESULTS"

FAILED=0
for entry in "${DEVICES[@]}"; do
  IFS=$'\t' read -r id name platform <<< "$entry"
  say "$name  ($platform, $id)"

  log="$OUT/$(echo "$id" | tr -c 'a-zA-Z0-9' '_').log"
  if (cd "$MOBILE" && flutter test integration_test/nfr3_local_latency_test.dart \
        -d "$id" --no-pub) > "$log" 2>&1; then
    verdict='**pass**'
  else
    verdict='**FAIL**'
    FAILED=1
  fi

  # The test prints one `NFR3 <op> n=.. p50=..ms p95=..ms max=..ms` line per operation.
  field() { grep -oE "NFR3 $1 .*" "$log" | grep -oE "$2=[0-9.]+ms" | head -1 | cut -d= -f2; }
  row="| $name | $platform "
  row+="| $(field add_item p50)/$(field add_item p95) "
  row+="| $(field commit_sale p50)/$(field commit_sale p95) "
  row+="| $(field commit_sale_loaded p95) "
  row+="| $verdict |"
  echo "$row" >> "$RESULTS"

  grep -E '^NFR3 ' "$log" | sed 's/^/  /' || warn "no NFR3 lines — see $log"
done

say "Device matrix (NFR-3.2 budget: < 100 ms)"
cat "$RESULTS"
echo
echo "Logs: $OUT"
echo "Record this table in docs/engineering/device-matrix.md with today's date."

# A failing handset is a real result, not a broken script. It means the offline-first payoff
# does not hold on hardware this product is meant to run on, and that is a GA blocker.
exit "$FAILED"
