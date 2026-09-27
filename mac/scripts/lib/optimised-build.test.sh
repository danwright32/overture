#!/usr/bin/env bash
set -uo pipefail

# #4106 (plan v7 probe 0c.9): the optimised run's switch, its overrides, and the build log check that
# decides whether the run may be believed. The runner level cases (what an ordinary run passes, what the
# switch adds, that a refused check fails the run) are in mac/scripts/run-tests-locked.test.sh.

# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./optimised-build.sh
source "${SCRIPT_DIR}/optimised-build.sh"

FAILURES=0

# (description, needle, haystack), which reads better beside the verdict text than the shared order.
expect_in() { assert_contains "$1" "$3" "$2"; }

# Shaped like xcodebuild's own compile lines: a task line, then the command under it.
frontend() {
  printf '    builtin-swiftTaskExecution -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c /w/A.swift -module-name %s %s -D DEBUG -o /w/A.o\n' "$1" "$2"
}

# --- the switch ---------------------------------------------------------------------------------
assert_equals "unset is off" "off" "$(unset OVERTURE_TEST_OPTIMISED; optimised_build_switch)"
assert_equals "empty is off" "off" "$(OVERTURE_TEST_OPTIMISED= optimised_build_switch)"
assert_equals "1 is on" "on" "$(OVERTURE_TEST_OPTIMISED=1 optimised_build_switch)"
TYPO_OUT="$(OVERTURE_TEST_OPTIMISED=true optimised_build_switch 2>&1)"
TYPO_CODE=$?
assert_equals "anything else is refused, not read as off" "2" "${TYPO_CODE}"
expect_in "and the refusal names the value" "OVERTURE_TEST_OPTIMISED is 'true'" "${TYPO_OUT}"

# --- the overrides ------------------------------------------------------------------------------
OVERRIDES="$(optimised_build_overrides)"
expect_in "the optimiser is Release's" "SWIFT_OPTIMIZATION_LEVEL=-O" "${OVERRIDES}"
expect_in "whole module, as Release compiles, so generics specialise across files" \
  "SWIFT_COMPILATION_MODE=wholemodule" "${OVERRIDES}"
expect_in "testability stays on for @testable import" "ENABLE_TESTABILITY=YES" "${OVERRIDES}"

# --- the verdict --------------------------------------------------------------------------------
OPT_LOG="$(frontend Overture '-O -enable-testing')
$(frontend OvertureTests '-O -enable-testing')
$(frontend OvertureTests '-O -enable-testing')"
assert_equals "an optimised log is VERIFIED, with its counts" \
  "VERIFIED: every swift-frontend invocation carried -O and -enable-testing and none carried -Onone (Overture 1, OvertureTests 2)." \
  "$(optimised_build_verdict "${OPT_LOG}")"

DEBUG_LOG="$(frontend Overture '-Onone -enable-testing')
$(frontend OvertureTests '-Onone -enable-testing')"
expect_in "a Debug log is REFUSED" "REFUSED:" "$(optimised_build_verdict "${DEBUG_LOG}")"
expect_in "naming the module" "Overture was compiled WITHOUT optimisation in 1 of its 1" \
  "$(optimised_build_verdict "${DEBUG_LOG}")"

# One module optimised and the other not is the case the plan's own wording would miss: the pure probes
# run code compiled as OvertureTests, never as Overture.
HALF_LOG="$(frontend Overture '-O -enable-testing')
$(frontend OvertureTests '-Onone -enable-testing')"
expect_in "the pure test module compiled at -Onone is REFUSED even when the app module is not" \
  "OvertureTests was compiled WITHOUT optimisation" "$(optimised_build_verdict "${HALF_LOG}")"

NO_O_LOG="$(frontend Overture '-enable-testing')
$(frontend OvertureTests '-O -enable-testing')"
expect_in "no optimisation flag at all is REFUSED, not read as the default" \
  "Overture was compiled WITHOUT optimisation" "$(optimised_build_verdict "${NO_O_LOG}")"

UNTESTABLE_LOG="$(frontend Overture '-O')
$(frontend OvertureTests '-O -enable-testing')"
expect_in "an optimised build that dropped testability is REFUSED" \
  "Overture was compiled WITHOUT -enable-testing" "$(optimised_build_verdict "${UNTESTABLE_LOG}")"

ONE_MODULE_LOG="$(frontend Overture '-O -enable-testing')"
expect_in "a module with no compile line is UNMEASURED" \
  "UNMEASURED: no swift-frontend invocation for OvertureTests" "$(optimised_build_verdict "${ONE_MODULE_LOG}")"
expect_in "and an empty log names both" "for Overture, OvertureTests" "$(optimised_build_verdict "")"

# A module whose name merely BEGINS with a wanted one, and an SDK module the build also compiles, are
# neither evidence for nor against.
OTHER_LOG="${OPT_LOG}
$(frontend OvertureHostedTests '-Onone -enable-testing')
$(frontend SwiftUI '-Onone')"
expect_in "other modules are not read" "VERIFIED" "$(optimised_build_verdict "${OTHER_LOG}")"

# Evidence keeps only the compile lines, so a retry's log can be added to the first attempt's.
EVIDENCE="$(optimised_build_evidence "Test run with 4 tests
${OPT_LOG}
** TEST SUCCEEDED **")"
assert_equals "evidence is the compile lines alone" "3" "$(grep -c . <<< "${EVIDENCE}")"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All optimised-build.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} optimised-build.sh fixture(s) failed."
exit 1
