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
FILES=$(find lib test -name '*.dart' -not -path 'lib/contracts/*')

if [ "${1:-}" = "--check" ]; then
  # shellcheck disable=SC2086
  dart format --output=none --set-exit-if-changed $FILES
else
  # shellcheck disable=SC2086
  dart format $FILES
fi
