#!/usr/bin/env bash
# Formats the Flutter sources, skipping generated code.
#
# `dart format lib` is the obvious command and it is wrong here: it reformats
# lib/contracts/, whose canonical form is whatever the emitter produces. CI compares those
# bytes against a fresh `pnpm gen:contracts`, so formatting them turns the next contract
# check red for a reason that has nothing to do with the contract (ADR-010, ADR-014).
#
# This exists so the safe invocation is the short one.
set -euo pipefail

cd "$(dirname "$0")/../apps/mobile"
# `integration_test` is included explicitly. It is a real source directory — the on-device
# NFR-3.2 measurement lives there — but it is not `lib` or `test`, so a glob that named only
# those two would leave it unformatted AND unchecked, which is the worse half: CI would go
# green over a directory it never looked at.
# Only directories that exist: `find` on a missing one fails, and under `set -e` that would
# kill the whole script — turning a deleted directory into "formatting is broken".
DIRS=()
for d in lib test integration_test; do [ -d "$d" ] && DIRS+=("$d"); done
FILES=$(find "${DIRS[@]}" -name '*.dart' -not -path 'lib/contracts/*')

if [ "${1:-}" = "--check" ]; then
  # shellcheck disable=SC2086
  dart format --output=none --set-exit-if-changed $FILES
else
  # shellcheck disable=SC2086
  dart format $FILES
fi
