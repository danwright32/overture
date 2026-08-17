#!/usr/bin/env bash
set -uo pipefail

# Says when this checkout has silently filled up with local branches again (#2302).
#
# The accumulation is continuous and nothing counted it. It reached 496 local branches by 2026-08-06
# and the obvious check agreed all was well the whole way up, because this repo squash-merges and
# `git branch --merged main -d` recognised 39 of them. What made it visible in the end was a
# repo-wide search returning ten copies of every hit.
#
# ADVISORY ONLY, and it can never fail a run: a cluttered checkout is not a defect in the change
# being pushed, which is the same reasoning mac/scripts/prune-stale-registrations.sh already rides
# along under.
#
# What it deliberately does NOT do is run the tidy's full counting pass. That pass reads every merged
# PR head branch in the repo from GitHub and then computes a patch-id per commit for whatever is
# left, which is minutes of work; this runs inside every scripts/test-all.sh, so it counts REFS,
# which is one cheap git call, and hands the expensive question to scripts/tidy-checkout.sh. The
# message says which of the two it measured, because the difference is the whole reason #2234 exists.
#
# Usage: scripts/check-branch-backlog.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the fixture drives the real script against a THROWAWAY repository. A fixture that
# counted this checkout's own branches would assert about whatever this Mac happened to be holding
# that day (L2). Defaulted to this script's own checkout, so every ordinary invocation is unchanged.
REPO_ROOT="${BRANCH_BACKLOG_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Chosen against a measurement rather than as a round number: this checkout held 27 local branches
# across 15 registered worktrees on 2026-08-16, all of it ordinary, so a threshold at roughly double
# that says "go and look" long before hundreds without firing on the everyday state. A guard that
# fires on the common case is one that gets switched off (L93).
THRESHOLD="${BRANCH_BACKLOG_THRESHOLD:-50}"

# shellcheck source=./lib/checkout-tidy.sh
source "${SCRIPT_DIR}/lib/checkout-tidy.sh"

main() {
  local refs count report

  # A count that could not be read is not a count of zero. Piping straight into `grep -c` would
  # report a clean checkout on the strength of a git that never answered, which is the empty result
  # reading as success (L98, L11), so the status is captured before anything counts.
  if ! refs="$(git -C "${REPO_ROOT}" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"; then
    echo "check-branch-backlog: could not read the local branches at ${REPO_ROOT}, so nothing was measured."
    return 0
  fi

  count="$(printf '%s' "${refs}" | grep -c . || true)"
  report="$(branch_backlog_report "${count}" "${THRESHOLD}")"
  [[ -n "${report}" ]] && echo "check-branch-backlog: ${report}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
