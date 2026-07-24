#!/usr/bin/env bash
set -uo pipefail

# Pure-function coverage for check-pbxproj-fresh.sh's pbxproj_freshness_verdict (Phase 1 of #1251,
# closes #1368). The real gate runs xcodegen and asks git whether the committed project.pbxproj changed;
# this fixture drives the DECISION over those two facts (does the installed xcodegen match the pinned
# version, and does a fresh regen match the committed file) so it runs anywhere, including CI where no
# xcodegen or Xcode exists.
#
# The load-bearing case is `stale`: a committed pbxproj that a fresh regen would change MUST BLOCK (exit
# 1) with a message that says "stale", never pass. That is the exact #1368 hole (the merge scripts
# regenerated the stale file and shipped it). If the verdict stops blocking that, this fixture goes red,
# which is the mutation this guard must survive. The version-mismatch case must emit its OWN distinct
# "cannot verify" verdict (exit 2), never a false "stale", so cross-machine byte drift can't masquerade
# as staleness.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-pbxproj-fresh.sh
source "${SCRIPT_DIR}/check-pbxproj-fresh.sh"
# check-pbxproj-fresh.sh's own `set -euo pipefail` is now active. Turn errexit off so one failing
# assertion (or a non-zero verdict return we are asserting ON) doesn't abort the rest of the run.
set +e

FAILURES=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected NOT to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Runs the verdict, capturing its stderr message in MSG and its exit code in CODE. The fourth argument
# (whether the working tree already held the fresh regen) is optional so the version-mismatch and absent
# cases can omit it, matching how the real gate calls the verdict on its early-return paths.
run_verdict() {
  MSG="$(pbxproj_freshness_verdict "$1" "$2" "$3" "${4:-false}" 2>&1)"
  CODE=$?
}

# FRESH: installed matches pinned and a fresh regen matches the committed file. Passes silently (exit 0).
run_verdict "2.45.3" "2.45.3" "true"
assert_eq "fresh: exit 0" "0" "${CODE}"

# STALE (the mutation this guard exists to catch): versions match, a fresh regen would change the committed
# pbxproj, and the working tree did NOT already hold that regen (the genuinely-stale commit). MUST block
# with exit 1 and a message that says stale and tells the operator to regenerate and commit.
run_verdict "2.45.3" "2.45.3" "false" "false"
assert_eq "stale: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "stale: message says stale" "${MSG}" "stale"
assert_contains "stale: message says to regenerate" "${MSG}" "xcodegen generate"

# REGENERATED-BUT-NOT-COMMITTED (#1480): versions match and a fresh regen still differs from the COMMITTED
# file, but the working tree already held exactly that fresh output before this check ran. HEAD is behind
# either way, so it MUST still block (exit 1); but the operator already regenerated, and this check restores
# the tree, so it has just reverted their regen. The message must say that (not the bare "regenerate and
# commit", which sends them in a loop: the regen they are told to make is the one just thrown away) and must
# NOT tell them the committed file is stale as if they had never touched it.
run_verdict "2.45.3" "2.45.3" "false" "true"
assert_eq "not-committed: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "not-committed: message says not committed" "${MSG}" "not committed"
assert_contains "not-committed: message names the revert" "${MSG}" "reverted"
assert_not_contains "not-committed: does NOT call the file stale" "${MSG}" "is stale"
assert_contains "not-committed: still points at a commit" "${MSG}" "git commit"

# VERSION MISMATCH: the installed xcodegen is not the pinned one, so freshness cannot be verified at all
# (byte drift between versions would look like staleness). MUST be its own outcome (exit 2) with a
# "cannot verify" message, and MUST NOT claim the file is stale, regardless of the regen-match flag.
run_verdict "2.44.1" "2.45.3" "false"
assert_eq "mismatch: exit 2 (cannot verify)" "2" "${CODE}"
assert_contains "mismatch: message says cannot verify" "${MSG}" "cannot verify"
assert_contains "mismatch: message names version mismatch" "${MSG}" "version mismatch"
assert_not_contains "mismatch: does NOT masquerade as stale" "${MSG}" "is stale"

# A missing xcodegen ("absent") is a version mismatch too: it cannot verify, exit 2, never a false stale.
run_verdict "absent" "2.45.3" "true"
assert_eq "absent: exit 2 (cannot verify)" "2" "${CODE}"
assert_contains "absent: message says cannot verify" "${MSG}" "cannot verify"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-pbxproj-fresh.test.sh: all assertions passed"
  exit 0
else
  echo "check-pbxproj-fresh.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
