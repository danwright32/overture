#!/usr/bin/env bash
set -uo pipefail

# #4343 (E0): the release-like run's switch, its overrides, and the build log check that decides whether
# the run may be believed. The runner level cases (what the switch passes, which scheme it builds, that a
# refused check fails the run) are in mac/scripts/run-tests-locked.test.sh.

# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./optimised-build.sh
source "${SCRIPT_DIR}/optimised-build.sh"
# shellcheck source=./release-like-build.sh
source "${SCRIPT_DIR}/release-like-build.sh"

FAILURES=0

expect_in() { assert_contains "$1" "$3" "$2"; }

# The shape this Mac's xcodebuild prints (measured 2026-09-27 for the optimised run): each module's flags
# on the swiftc line under its SwiftDriver task.
driver() {
  printf '    builtin-SwiftDriver -- /X/usr/bin/swiftc -module-name %s %s @/X/%s.SwiftFileList\n' "$1" "$2" "$1"
}

# --- the switch ---------------------------------------------------------------------------------
assert_equals "unset is off" "off" "$(unset OVERTURE_TEST_RELEASE_LIKE; release_like_build_switch)"
assert_equals "empty is off" "off" "$(OVERTURE_TEST_RELEASE_LIKE= release_like_build_switch)"
assert_equals "1 is on" "on" "$(OVERTURE_TEST_RELEASE_LIKE=1 release_like_build_switch)"
TYPO_OUT="$(OVERTURE_TEST_RELEASE_LIKE=yes release_like_build_switch 2>&1)"
TYPO_CODE=$?
assert_equals "anything else is refused, not read as off" "2" "${TYPO_CODE}"
expect_in "and the refusal names the value" "OVERTURE_TEST_RELEASE_LIKE is 'yes'" "${TYPO_OUT}"

# --- the overrides ------------------------------------------------------------------------------
OVERRIDES="$(release_like_build_overrides)"
expect_in "the optimiser is Release's" "SWIFT_OPTIMIZATION_LEVEL=-O" "${OVERRIDES}"
expect_in "whole module, as Release compiles" "SWIFT_COMPILATION_MODE=wholemodule" "${OVERRIDES}"
expect_in "testability stays on" "ENABLE_TESTABILITY=YES" "${OVERRIDES}"
# DEBUG reaches the compiler through one project variable (mac/project.yml), so replacing that variable
# removes it from every target at once while a target's own additions are kept.
expect_in "the DEBUG condition is replaced by the release-like marker" \
  "OVERTURE_DEBUG_CONDITION=OVERTURE_RELEASE_LIKE" "${OVERRIDES}"
expect_in "and the C side's DEBUG=1 with it" "GCC_PREPROCESSOR_DEFINITIONS=OVERTURE_RELEASE_LIKE=1" "${OVERRIDES}"
assert_not_contains "nothing sets DEBUG back" "${OVERRIDES}" "=DEBUG"
assert_equals "the pure suite's scheme, the only one whose targets compile without DEBUG" \
  "OvertureCore" "${RELEASE_LIKE_SCHEME}"

# --- the verdict --------------------------------------------------------------------------------
RELEASE_LOG="$(driver OvertureTests '-O -whole-module-optimization -enable-testing -DOVERTURE_RELEASE_LIKE')"
assert_equals "a release-like log is VERIFIED, with its count" \
  "VERIFIED: every compile invocation carried -O, -enable-testing and -DOVERTURE_RELEASE_LIKE, and none carried -Onone or DEBUG (OvertureTests 1)." \
  "$(release_like_build_verdict "${RELEASE_LOG}")"

DEBUG_LOG="$(driver OvertureTests '-O -enable-testing -DOVERTURE_RELEASE_LIKE -DDEBUG')"
expect_in "a compile carrying -DDEBUG is REFUSED" "REFUSED: OvertureTests was compiled WITH DEBUG" \
  "$(release_like_build_verdict "${DEBUG_LOG}")"
SPLIT_LOG="$(driver OvertureTests '-O -enable-testing -DOVERTURE_RELEASE_LIKE -D DEBUG')"
expect_in "and so is DEBUG as its own argument after -D" "compiled WITH DEBUG" \
  "$(release_like_build_verdict "${SPLIT_LOG}")"
C_LOG="$(driver OvertureTests '-O -enable-testing -DOVERTURE_RELEASE_LIKE -Xcc -DDEBUG=1')"
expect_in "and so is the C side's DEBUG=1" "compiled WITH DEBUG" "$(release_like_build_verdict "${C_LOG}")"

NO_MARKER_LOG="$(driver OvertureTests '-O -enable-testing')"
expect_in "a compile without the marker is REFUSED: nothing shows the override reached it (L319)" \
  "WITHOUT -DOVERTURE_RELEASE_LIKE" "$(release_like_build_verdict "${NO_MARKER_LOG}")"

ONONE_LOG="$(driver OvertureTests '-Onone -enable-testing -DOVERTURE_RELEASE_LIKE')"
expect_in "an unoptimised compile is REFUSED" "compiled WITHOUT optimisation" \
  "$(release_like_build_verdict "${ONONE_LOG}")"
UNTESTABLE_LOG="$(driver OvertureTests '-O -DOVERTURE_RELEASE_LIKE')"
expect_in "a compile without testability is REFUSED" "WITHOUT -enable-testing" \
  "$(release_like_build_verdict "${UNTESTABLE_LOG}")"

expect_in "a log with no compile line is UNMEASURED" "UNMEASURED: no compile invocation for OvertureTests" \
  "$(release_like_build_verdict "")"

# A module whose name merely BEGINS with a wanted one, and an SDK module, are neither evidence for nor
# against; and a word that merely CONTAINS DEBUG is not the condition.
OTHER_LOG="${RELEASE_LOG}
$(driver OvertureHostedTests '-Onone -enable-testing -DDEBUG')
$(driver SwiftUI '-Onone -DDEBUG')
$(driver OvertureTests '-O -enable-testing -DOVERTURE_RELEASE_LIKE -DDEBUGGER_OFF')"
assert_equals "other modules and other words are not read" \
  "VERIFIED: every compile invocation carried -O, -enable-testing and -DOVERTURE_RELEASE_LIKE, and none carried -Onone or DEBUG (OvertureTests 2)." \
  "$(release_like_build_verdict "${OTHER_LOG}")"

# REFUSED wins over UNMEASURED and lists every reason, so one fix is not followed by a second surprise.
TWO_LOG="$(driver OvertureTests '-Onone -DDEBUG')"
TWO_VERDICT="$(release_like_build_verdict "${TWO_LOG}")"
expect_in "every reason is named: optimisation" "WITHOUT optimisation" "${TWO_VERDICT}"
expect_in "every reason is named: DEBUG" "WITH DEBUG" "${TWO_VERDICT}"
expect_in "every reason is named: the marker" "WITHOUT -DOVERTURE_RELEASE_LIKE" "${TWO_VERDICT}"

# --- the exclusion list -------------------------------------------------------------------------
EX_DIR="$(fixture_scratch_dir)"
printf '# a comment\n\nAOneTests.swift\n  BTwoTests.swift  \n# another\n' > "${EX_DIR}/list.txt"
assert_equals "the names, space separated, comments and blanks dropped" "AOneTests.swift BTwoTests.swift" \
  "$(release_like_build_exclusions "${EX_DIR}/list.txt")"
printf '# nothing needs DEBUG\n' > "${EX_DIR}/empty.txt"
assert_equals "a list of comments only leaves nothing out" "" "$(release_like_build_exclusions "${EX_DIR}/empty.txt")"
MISSING_OUT="$(release_like_build_exclusions "${EX_DIR}/absent.txt" 2>&1)"
MISSING_CODE=$?
assert_equals "a list that cannot be read refuses, never reads as nothing to leave out" "2" "${MISSING_CODE}"
expect_in "and says how to write it" "TEST_RUNNER_REGENERATE_RELEASE_LIKE_EXCLUSIONS=1" "${MISSING_OUT}"
assert_equals "the committed list is the default" \
  "$(cd "${SCRIPT_DIR}" && pwd)/release-like-excluded-tests.txt" \
  "$(unset OVERTURE_RELEASE_LIKE_EXCLUSIONS; source "${SCRIPT_DIR}/release-like-build.sh"; echo "${RELEASE_LIKE_EXCLUSIONS_FILE}")"
rm -rf "${EX_DIR}"

EVIDENCE="$(release_like_build_evidence "Test run with 4 tests
${RELEASE_LOG}
** TEST SUCCEEDED **")"
assert_equals "evidence is the compile lines alone" "1" "$(grep -c . <<< "${EVIDENCE}")"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All release-like-build.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} release-like-build.sh fixture(s) failed."
exit 1
