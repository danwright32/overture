#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #2302: the wiring for the branch backlog advisory, which is a separate claim from the sentence
# itself (L3). checkout-tidy.test.sh proves the sentence; this proves the script COUNTS, prints on
# the checkouts that have gone past the threshold, stays quiet on the ones that have not, and can
# never block a push whatever it finds.
#
# Driven against a THROWAWAY repository built here, never the real one: a fixture that counted this
# checkout's branches would assert about whatever this Mac happened to be holding that day, and
# would pass or fail for a reason unrelated to the code (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-branch-backlog.sh"

FAILURES=0

# A repository with <n> local branches beside main, and nothing else. Committed with the identity
# passed inline so it never depends on this Mac's git config being set.
make_repo_with_branches() {
  local count="$1" repo i
  repo="$(fixture_scratch_dir)"
  git -C "${repo}" init -q -b main >/dev/null 2>&1
  git -C "${repo}" -c user.name=fixture -c user.email=fixture@example.com \
    commit -q --allow-empty -m "root" >/dev/null 2>&1
  for ((i = 1; i <= count; i++)); do
    git -C "${repo}" branch "fixture-branch-${i}" >/dev/null 2>&1
  done
  echo "${repo}"
}

run_check() {
  local repo="$1" threshold="$2" out code
  out="$(BRANCH_BACKLOG_REPO_ROOT="${repo}" BRANCH_BACKLOG_THRESHOLD="${threshold}" "${CHECK}" 2>&1)"
  code=$?
  printf '%s\nexit=%s\n' "${out}" "${code}"
}

BUSY_REPO="$(make_repo_with_branches 4)"

# Five refs in all (main plus four), so a threshold of 3 is past and a threshold of 50 is not.
BUSY_RUN="$(run_check "${BUSY_REPO}" 3)"

assert_contains "a checkout past the threshold says how many branches it counted" \
  "${BUSY_RUN}" "5 local branches"

assert_contains "and names the command that decides which of them can go" \
  "${BUSY_RUN}" "scripts/tidy-checkout.sh"

# THE property. This rides along inside scripts/test-all.sh, and a cluttered checkout is not a
# defect in the change being pushed, so it must never be able to fail a run (the same reasoning
# prune-stale-registrations.sh already rides along under).
assert_contains "and it still exits 0, because it may never block a push" \
  "${BUSY_RUN}" "exit=0"

QUIET_RUN="$(run_check "${BUSY_REPO}" 50)"

assert_not_contains "an ordinary checkout says nothing at all about branches" \
  "${QUIET_RUN}" "local branches"

assert_contains "and exits 0 too" "${QUIET_RUN}" "exit=0"

# A count that could not be read is not a count of zero. Reporting a clean checkout on the strength
# of a git that never answered is the empty-result-reads-as-success defect (L98, L11).
NOT_A_REPO="$(fixture_scratch_dir)"
BROKEN_RUN="$(run_check "${NOT_A_REPO}" 3)"

assert_contains "somewhere it cannot count says so, rather than reporting a clean checkout" \
  "${BROKEN_RUN}" "could not read"

assert_not_contains "and never states a count it did not make" \
  "${BROKEN_RUN}" "0 local branches"

assert_contains "and is still not a reason to fail a push" "${BROKEN_RUN}" "exit=0"

rm -rf "${BUSY_REPO}" "${NOT_A_REPO}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All check-branch-backlog.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} check-branch-backlog.sh fixture(s) failed." >&2
exit 1
