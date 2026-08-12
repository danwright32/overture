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

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All check-release-freshness.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} check-release-freshness.sh fixture(s) failed."
  exit 1
fi
