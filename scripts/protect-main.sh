#!/usr/bin/env bash
# Applies branch protection to `main`.
#
# Requires GitHub Pro, Team, or a public repository — on a free private repo the API answers
# 403 "Upgrade to GitHub Pro or make this repository public". Until then, the local pre-push
# hook (scripts/install-hooks.sh) is the substitute, and it is a tripwire, not a gate.
#
# Settings come from docs/06 §4 as amended by ADR-011:
#   - every change through a PR
#   - required approvals: 0, because a single maintainer cannot approve their own PR and a
#     rule that has to be switched off to ship is worse than no rule
#   - the four required checks, with "strict" so a branch must be up to date with main
#   - linear history, no force pushes, no deletions
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
echo "applying protection to ${REPO}:main"

if ! gh api -X PUT "repos/${REPO}/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "CI gate",
      "controlled-artifact requirements",
      "dependency audit",
      "no secrets in the diff"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
then
  cat >&2 <<'MSG'

  Protection was not applied.

  If the error mentions GitHub Pro: this repository is private on a free plan, where branch
  protection is unavailable. Either make it public (note that the ADRs and
  docs/compliance-sign-off.md become public reading) or upgrade the plan, then re-run this.

  Meanwhile: ./scripts/install-hooks.sh  — a local pre-push tripwire, not a gate.

MSG
  exit 1
fi

echo "protection applied. enforce_admins is off, so you cannot lock yourself out."
