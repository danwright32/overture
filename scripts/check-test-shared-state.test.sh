#!/usr/bin/env bash
set -uo pipefail

# Fixture for scripts/check-test-shared-state.sh (#3270), auto-run by scripts/run-shell-fixtures.sh.
#
# Driven against a THROWAWAY tree of Swift files rather than against mac/OvertureTests, deliberately.
# A fixture that asserted about the real tree would be asserting about today's declarations, so it would
# go red the day somebody adds a legitimate one and green the day somebody deletes the last of them,
# which is a test of the corpus rather than of the check. The seams (OVERTURE_SHARED_STATE_REPO, ROOTS,
# BASELINE) exist for exactly this.

# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

FAILURES=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-test-shared-state.sh"

TMP_DIR="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REPO="${TMP_DIR}/repo"
mkdir -p "${REPO}/tests"
BASELINE="${TMP_DIR}/baseline.txt"

run_check() {
  OVERTURE_SHARED_STATE_REPO="${REPO}" \
  OVERTURE_SHARED_STATE_ROOTS="tests" \
  OVERTURE_SHARED_STATE_BASELINE="${BASELINE}" \
    bash "${CHECK}" "$@" 2>&1
}

# --- a stored mutable static nobody has accounted for is reported -------------------------------------

cat > "${REPO}/tests/StubTests.swift" <<'SWIFT'
import Testing

final class SomeStub {
    nonisolated(unsafe) static var callCount = 0
}
SWIFT
: > "${BASELINE}"

RC=0
OUT="$(run_check)" || RC=$?
assert_equals "an unrecorded stored static is something to triage" "1" "${RC}"
assert_contains "and it is named by file" "${OUT}" "tests/StubTests.swift"
assert_contains "and by declaration" "${OUT}" "callCount"

# --- recording it accounts for it ---------------------------------------------------------------------

printf 'tests/StubTests.swift:callCount  # held by .sharesSomething\n' > "${BASELINE}"
RC=0
OUT="$(run_check)" || RC=$?
assert_equals "a recorded declaration is accounted for" "0" "${RC}"
assert_contains "and the count is stated rather than left to silence" "${OUT}" "1"

# --- a COMPUTED static holds no state and is not a subject --------------------------------------------
#
# This is most of the `static var` declarations in the real test targets (a liveStoreURL, a source root,
# a lazily derived fixture), so a check that reported them would fire on the common case and be switched
# off within a day (L93).

cat > "${REPO}/tests/ComputedTests.swift" <<'SWIFT'
import Testing

enum Roots {
    static var macRoot: URL { RepoRoot.mac }
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: "/nowhere")
    }
    static let fixed = 3
    nonisolated(unsafe) static let alsoFixed = 4
}
SWIFT
RC=0
OUT="$(run_check)" || RC=$?
assert_equals "a computed static, and a let, are not shared mutable state" "0" "${RC}"
assert_not_contains "so the computed one is not reported" "${OUT}" "macRoot"
assert_not_contains "nor the immutable one" "${OUT}" "fixed"

# --- a static var NAMED IN A COMMENT is not a declaration ---------------------------------------------
#
# Three files in the real tree explain in prose why they are NOT a `static var`, and a reader that
# counted those would report the very files that fixed this defect as instances of it.

cat > "${REPO}/tests/CommentaryTests.swift" <<'SWIFT'
import Testing

// A class behind a lock rather than a `static var`, so this stays correct when tests run at once.
enum Memo {
    // nonisolated(unsafe) static var wasHereOnce = 0
    static let real = 1
}
SWIFT
RC=0
OUT="$(run_check)" || RC=$?
assert_equals "prose about a static var is not a static var" "0" "${RC}"
assert_not_contains "so nothing in the commentary is reported" "${OUT}" "wasHereOnce"

# --- a stored static initialised by a closure is still stored -----------------------------------------
#
# The rule that tells computed from stored is the brace, so a closure initialiser is the one stored shape
# that looks computed. It holds state exactly like a plain one.

cat > "${REPO}/tests/ClosureInitTests.swift" <<'SWIFT'
import Testing

enum Lazy {
    nonisolated(unsafe) static var table: [String: Int] = { ["a": 1] }()
}
SWIFT
RC=0
OUT="$(run_check)" || RC=$?
assert_equals "a closure initialised stored static is reported" "1" "${RC}"
assert_contains "and named" "${OUT}" "table"
rm "${REPO}/tests/ClosureInitTests.swift"

# --- a baseline line whose declaration is gone is reported too ----------------------------------------
#
# A log that still describes a tree it no longer matches hides a re-introduction behind a line that looks
# already answered.

printf 'tests/StubTests.swift:callCount  # held by .sharesSomething\ntests/Deleted.swift:vanished  # was accounted for\n' > "${BASELINE}"
RC=0
OUT="$(run_check)" || RC=$?
assert_equals "a stale baseline line is something to triage" "1" "${RC}"
assert_contains "and it is named" "${OUT}" "vanished"

# --- nothing extracted at all is UNMEASURED, never clean ----------------------------------------------
#
# A tree with no Swift in it and a tree with no shared state in it leave the same empty result, and the
# emptiest possible failure must not read as the cleanest possible pass (L98, L11).

EMPTY_REPO="${TMP_DIR}/empty"
mkdir -p "${EMPTY_REPO}"
RC=0
OUT="$(OVERTURE_SHARED_STATE_REPO="${EMPTY_REPO}" OVERTURE_SHARED_STATE_ROOTS="tests" \
      OVERTURE_SHARED_STATE_BASELINE="${BASELINE}" bash "${CHECK}" 2>&1)" || RC=$?
assert_equals "a root that is not there is unmeasured" "2" "${RC}"
assert_contains "and says so in its own word" "${OUT}" "UNMEASURED"
assert_not_contains "rather than claiming everything is accounted for" "${OUT}" "already recorded"

# A root that EXISTS and holds no Swift file at all is the same answer, and it is a different way in:
# a renamed target, a bad root, a checkout that did not finish.
mkdir -p "${EMPTY_REPO}/tests"
RC=0
OUT="$(OVERTURE_SHARED_STATE_REPO="${EMPTY_REPO}" OVERTURE_SHARED_STATE_ROOTS="tests" \
      OVERTURE_SHARED_STATE_BASELINE="${BASELINE}" bash "${CHECK}" 2>&1)" || RC=$?
assert_equals "an empty root is unmeasured too" "2" "${RC}"
assert_contains "and says which root it read" "${OUT}" "tests"

# --- --record writes the tree's declarations and KEEPS the reasons already written --------------------
#
# The reason is the whole value of the file: which named lock accounts for this declaration. A record
# that dropped it would turn a triage log into a bare count, and a count driven to zero stops being read
# as a measurement (L182).

printf 'tests/StubTests.swift:callCount  # held by .sharesSomething\n' > "${BASELINE}"
RC=0
OUT="$(run_check --record)" || RC=$?
assert_equals "--record succeeds" "0" "${RC}"
BASELINE_TEXT="$(cat "${BASELINE}")"
assert_contains "the existing reason survives being re-recorded" "${BASELINE_TEXT}" "held by .sharesSomething"
assert_contains "and the declaration is still there" "${BASELINE_TEXT}" "tests/StubTests.swift:callCount"
assert_not_contains "and the line that named nothing in the tree is dropped" "${BASELINE_TEXT}" "vanished"

# A newly recorded declaration says out loud that nobody has given it a reason, rather than sitting in
# the file looking as considered as the lines around it.
cat > "${REPO}/tests/FreshTests.swift" <<'SWIFT'
import Testing

final class FreshStub {
    nonisolated(unsafe) static var seen: [String] = []
}
SWIFT
RECORD_OUT="$(run_check --record)"
assert_contains "--record prints what it is adding" "${RECORD_OUT}" "tests/FreshTests.swift:seen"
assert_contains "and the new line asks for a reason" "$(cat "${BASELINE}")" "NOT YET EXPLAINED"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-test-shared-state.sh: all assertions passed."
  exit 0
else
  echo "${FAILURES} check-test-shared-state.sh assertion(s) failed."
  exit 1
fi
