#!/usr/bin/env bash

# The ONE implementation of "merge this PR and only then do the things that follow a merge", shared by
# every merge path in this repo: verify-and-merge-branch.sh, verify-and-merge-batch.sh and
# merge-when-green.sh.
#
# WHY IT IS SHARED. The sequence has four steps that must happen in order and must not happen at all if
# the merge did not: delete the local branch (#2234), record the shipped commit (#1808), report the
# installed build's freshness (#1345). Two scripts each carried their own copy of it, which is the
# two-near-copies-drifting shape #1073 and #982 are about, and the fix below was needed in both.
#
# WHY IT VERIFIES. Measured 2026-08-13, the first real run of verify-and-merge-batch.sh:
# `gh pr merge 2609` exited 1 with `GraphQL: Something went wrong while executing your query` (a transient
# GitHub fault, reproduced by hand a minute later), and the run printed `merged   PR #2609`, deleted the
# local branch of a PR that was still open, and exited 0. Two separate reasons it read as success:
#
#  1. Nothing looked at the merge command's status. The three steps after it ran unconditionally, and the
#     last two end in `|| true`, so the function's status was whatever `|| true` produced. Errexit could
#     not save it either, because callers invoke it from a place where errexit is suspended (an `if`
#     condition, an `||` list).
#  2. Even a zero status from the merge command is only a claim that the command worked. The claim a
#     caller acts on is that the PR reached MERGED, and only GitHub can answer that (L12: report what
#     verifiably happened).
#
# Nothing destructive happens until that answer is in, because deleting the local branch of an unmerged
# PR destroys good state before its replacement exists (L5). In the measured case the work survived only
# because the branch was already on origin.
#
# REQUIRES from the sourcing script: gh_as_danwright32 and REPO (scripts/ci-config.sh),
# delete_merged_local_branch (scripts/lib/checkout-tidy.sh), record_pr_decision
# (scripts/lib/pr-body-claims.sh), and REPO_ROOT.

# merge_pr <pr-number> [local-branch-name]
#
# Returns 0 only when GitHub confirms the PR is MERGED. Prints the reason and returns 1 otherwise,
# having changed nothing else.
merge_pr() {
  local pr_number="$1" merged_branch="${2:-}"

  if ! gh_as_danwright32 pr merge "${pr_number}" -R "${REPO}" --squash --delete-branch; then
    echo "gh refused to merge PR #${pr_number}; its message is above. Nothing else was done to it," >&2
    echo "so the branch is untouched and this can be rerun once the cause is dealt with." >&2
    return 1
  fi

  local state
  state="$(gh_as_danwright32 pr view "${pr_number}" -R "${REPO}" --json state --jq .state 2>/dev/null || echo "")"
  if [[ "${state}" != "MERGED" ]]; then
    echo "gh reported success, but PR #${pr_number} reads as ${state:-unreadable} rather than MERGED." >&2
    echo "Treating it as NOT merged: nothing was deleted and no shipped commit was recorded." >&2
    return 1
  fi

  # #2234: --delete-branch only removes the branch on GitHub. Without this the local ref survives
  # every merge, which is how the checkout reached 496 branches. Never fatal: the merge is confirmed,
  # and failing here would report a landed change as a failure.
  delete_merged_local_branch "${merged_branch}" || true
  # #1808: something shipped, so record it for the app to compare its own build against, and say the
  # same thing in the terminal (which is what finally gives #1345's freshness check a caller). Neither
  # is fatal, for the same reason.
  "${REPO_ROOT}/scripts/record-shipped-commit.sh" || true
  "${REPO_ROOT}/mac/scripts/check-release-freshness.sh" || true
  # #3187: a decision this body quotes that no comment on its issues carries lives only here, in a merged
  # PR body, which is not somewhere anybody looks. Written to the issue now, after the merge is
  # confirmed and never before, because a call recorded for a PR that did not land is a decision nobody
  # made sitting where one somebody made would sit. Here rather than in either caller so all three merge
  # paths get it from one place, and never fatal for the same reason as the two lines above.
  PR_BODY_CLAIMS_GH=gh_as_danwright32 record_pr_decision "${pr_number}" || true
  # Explicit, so neither of those `|| true` lines can be mistaken for this function's verdict again.
  return 0
}
