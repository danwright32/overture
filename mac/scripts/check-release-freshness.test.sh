#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #1345: coverage for check-release-freshness.sh's freshness_verdict, the pure comparison at its core. The
# installed Release app is STALE if it was built BEFORE the latest commit (it may be missing merged work),
# and FRESH if it was built at or after it. main()'s I/O (reading the app mtime and the git commit time) is
# not unit-tested here; the comparison is, mirroring run-tests-locked.test.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-release-freshness.sh
source "${SCRIPT_DIR}/check-release-freshness.sh"
set +e

FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Built well before the latest commit: the app predates merged work, so it is stale (the exact case #1345
# was filed for, an app from an earlier day and commits merged after).
assert_equals "an app built before the latest commit is stale" \
  "stale" "$(freshness_verdict 1000 2000)"

# Built after the latest commit: nothing newer has been committed, so it is fresh.
assert_equals "an app built after the latest commit is fresh" \
  "fresh" "$(freshness_verdict 2000 1000)"

# Built at the same second as the latest commit: up to date, not stale (a build carries the commit it was
# built from, so equal times must not read as behind).
assert_equals "an app built at the same time as the latest commit is fresh" \
  "fresh" "$(freshness_verdict 1500 1500)"

# --- #3929: judged against what SHIPPED, never against the checkout running it ------------------------
#
# The incident's exact shape, in REAL throwaway repositories rather than a stubbed git (L52): the checkout
# running this is behind origin/main, and the installed app was built between the two. Judged against the
# checkout's HEAD it read "up to date"; judged against the shipped code it is behind. Dates are PINNED
# with GIT_COMMITTER_DATE and `touch -t`, so real time cannot walk the three apart (L130).
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT
commit_at() {
  local repo="$1" when="$2" message="$3"
  echo "${message}" >> "${repo}/file"
  git -C "${repo}" add file
  GIT_AUTHOR_DATE="${when}" GIT_COMMITTER_DATE="${when}" \
    git -C "${repo}" -c user.name=fixture -c user.email=fixture@example.com commit --quiet -m "${message}"
}
git init --quiet --bare "${WORK}/origin.git"
git clone --quiet "${WORK}/origin.git" "${WORK}/seed" 2>/dev/null
git -C "${WORK}/seed" checkout --quiet -b main
commit_at "${WORK}/seed" "2026-09-15T12:18:00" "before the fix"
git -C "${WORK}/seed" push --quiet origin main
# The checkout that runs the check is cloned HERE, at the older commit, and never pulls again.
git clone --quiet --branch main "${WORK}/origin.git" "${WORK}/checkout"
# Then the fix merges on the remote, after the app was built.
commit_at "${WORK}/seed" "2026-09-15T15:42:00" "the send path fix"
git -C "${WORK}/seed" push --quiet origin main
SHIPPED_SHA="$(git -C "${WORK}/seed" rev-parse --short HEAD)"
APP="${WORK}/Overture"
: > "${APP}"
touch -t 202609151437 "${APP}"

OUT="$(OVERTURE_INSTALLED_APP_BIN="${APP}" OVERTURE_FRESHNESS_REPO="${WORK}/checkout" \
  "${SCRIPT_DIR}/check-release-freshness.sh" 2>&1)"
STATUS=$?
assert_contains "an app built before the merged fix is behind, though the checkout is older still" \
  "${OUT}" "Installed Release is BEHIND the code"
assert_contains "and the line names the revision it was judged against" "${OUT}" "on origin/main is ${SHIPPED_SHA}"
assert_equals "and it exits 1, so a caller can gate on it" "1" "${STATUS}"

# The refresh failing is SAID, never passed off as a comparison against the shipped code: the verdict is
# then against origin/main as last fetched, which may be missing exactly the merge in question.
git -C "${WORK}/checkout" remote set-url origin "${WORK}/nowhere.git"
OUT="$(OVERTURE_INSTALLED_APP_BIN="${APP}" OVERTURE_FRESHNESS_REPO="${WORK}/checkout" \
  "${SCRIPT_DIR}/check-release-freshness.sh" 2>&1)"
assert_contains "a refresh that failed is named in the verdict line" "${OUT}" "the refresh FAILED"

# And a checkout with no origin/main at all says its comparison is NOT the shipped code.
git init --quiet "${WORK}/lonely"
commit_at "${WORK}/lonely" "2026-09-15T12:18:00" "only commit"
OUT="$(OVERTURE_INSTALLED_APP_BIN="${APP}" OVERTURE_FRESHNESS_REPO="${WORK}/lonely" \
  "${SCRIPT_DIR}/check-release-freshness.sh" 2>&1)"
assert_contains "no origin/main says the comparison is not against shipped code" "${OUT}" "NOT the shipped code"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All check-release-freshness.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} check-release-freshness.sh fixture(s) failed."
  exit 1
fi
