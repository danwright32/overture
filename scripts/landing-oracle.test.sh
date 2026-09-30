#!/usr/bin/env bash
set -uo pipefail

# #4328: the two refusals scripts/landing-oracle.sh makes before it builds anything. The overlay it copies
# onto a worktree of the oracle commit may ADD test code and nothing else, because the expected values are
# only 6d3453d8's if every line of APP code that produced them is 6d3453d8's (L70). And real data may only be
# written outside every git work tree.

# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
FAILURES=0
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./landing-oracle.sh
source "${SCRIPTS_DIR}/landing-oracle.sh"

ORACLE="$(git -C "${REPO_ROOT}" rev-parse 6d3453d8)"

assert_empty "a new test file under mac/OvertureTests may be overlaid" \
  "$(oracle_overlay_refusal "${ORACLE}" mac/OvertureTests/LandingOracleTests.swift)"
assert_contains "app code may not" \
  "$(oracle_overlay_refusal "${ORACLE}" mac/Overture/Integration/ScoutService.swift)" "is not test code"
assert_contains "a script may not" \
  "$(oracle_overlay_refusal "${ORACLE}" scripts/landing-oracle.sh)" "is not test code"
assert_contains "a path climbing out may not" \
  "$(oracle_overlay_refusal "${ORACLE}" mac/OvertureTests/../Overture/App/RootView.swift)" "climbs out"
assert_contains "a test file the oracle commit already has may not be REPLACED" \
  "$(oracle_overlay_refusal "${ORACLE}" mac/OvertureTests/Phase0Corpus.swift)" "already exists"

SCRATCH="$(fixture_scratch_dir)"
trap 'rm -rf "${SCRATCH}"' EXIT
if outside_every_work_tree "${SCRATCH}/archive/not-yet"; then
  pass "a directory under the temp folder is outside every work tree"
else
  fail "a directory under the temp folder was read as inside a work tree"
fi
if outside_every_work_tree "${REPO_ROOT}/nothing-here-yet"; then
  fail "a path inside this checkout was read as outside every work tree"
else
  pass "a path inside this checkout is refused, even before it exists"
fi

# A git that cannot answer (here, no git on the PATH at all) is a refusal, never a pass (L42).
if PATH="/nonexistent" outside_every_work_tree "${SCRATCH}/archive"; then
  fail "with no git to ask, a directory was read as outside every work tree"
else
  pass "with no git to ask, the directory is refused"
fi

# The whole script refuses before building anything when the real arm would write inside a checkout.
out="$(main --inputs "${SCRATCH}/archive" --out "${REPO_ROOT}/real-arm-out" 2>&1)"
assert_equals "the real arm's output inside a checkout is refused before any build" "2" "$?"
assert_contains "and says why" "${out}" "inside a git work tree"
out="$(main --inputs "${SCRATCH}/archive" 2>&1)"
assert_equals "the real arm with nowhere to write is refused" "2" "$?"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all landing-oracle checks passed"
