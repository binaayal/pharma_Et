#!/usr/bin/env bash
# Points git at the tracked hooks in .githooks/.
#
# Run once per clone:  ./scripts/install-hooks.sh
#
# Hooks live in the repository rather than in .git/hooks so they are reviewable and travel
# with the project. git does not install them automatically — by design, since a repository
# that could silently run code on clone would be a supply-chain problem.
set -euo pipefail

cd "$(dirname "$0")/.."
git config core.hooksPath .githooks

echo "hooks installed from .githooks/"
echo
git config --get core.hooksPath
ls -1 .githooks | sed 's/^/  /'
echo
echo "pre-push now refuses a direct push to main (docs/engineering/workflow.md §3)."
