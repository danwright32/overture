#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/shell-assertions.sh"

# #4568: coverage for mac/scripts/lib/test-scope-shape.sh, the one rule saying an argument is a test scope
# written WITHOUT its `-only-testing:` prefix. Twice on 2026-10-07 such a scope reached xcodebuild as an
# unknown build action, the runner read the failure as a crash, and the whole pure suite ran on the shared
# test lock. mutate.sh (single and batch) and run-tests-locked.sh refuse by this one predicate, so the
# shapes it must and must not accept are pinned here once.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-scope-shape.sh
source "${SCRIPT_DIR}/test-scope-shape.sh"
FAILURES=0

bare_of() {
  local found status
  found="$(bare_test_scope "$@")"
  status=$?
  printf '%s|%s' "${status}" "${found}"
}

# --- the shapes that ARE a scope missing its prefix ---------------------------------------------------
assert_equals "a bare Target/Suite is found" "0|OvertureTests/SomeSuite" "$(bare_of OvertureTests/SomeSuite)"
assert_equals "the hosted target too" "0|OvertureHostedTests/RowTests" "$(bare_of OvertureHostedTests/RowTests)"
assert_equals "a bare Target/Suite/test() is found" "0|OvertureTests/SomeSuite/runsOnce()" \
  "$(bare_of OvertureTests/SomeSuite/runsOnce\(\))"
assert_equals "with argument labels as well" "0|OvertureTests/SomeSuite/runs(_:at:)" \
  "$(bare_of 'OvertureTests/SomeSuite/runs(_:at:)')"
assert_equals "an XCTest method with no parentheses" "0|OvertureTests/SomeSuite/testRuns" \
  "$(bare_of OvertureTests/SomeSuite/testRuns)"
assert_equals "found among real scopes, and the bare one is named" "0|OvertureTests/Second" \
  "$(bare_of -only-testing:OvertureTests/First OvertureTests/Second -only-testing:OvertureTests/Third)"

# --- the shapes that are NOT, which a refusal must let through (L93) ----------------------------------
assert_equals "a prefixed scope is not bare" "1|" "$(bare_of -only-testing:OvertureTests/SomeSuite)"
assert_equals "a skip is not bare" "1|" "$(bare_of -skip-testing:OvertureTests/SomeSuite)"
assert_equals "an option and its value are not" "1|" "$(bare_of -parallel-testing-enabled YES)"
assert_equals "a destination is not" "1|" "$(bare_of -destination platform=macOS)"
assert_equals "a build setting is not" "1|" "$(bare_of OTHER_SWIFT_FLAGS=-DX)"
assert_equals "an absolute path is not" "1|" "$(bare_of -resultBundlePath /tmp/OvertureTests/bundle)"
assert_equals "a bundle path carrying its extension is not" "1|" "$(bare_of -resultBundlePath FooTests/out.xcresult)"
# The accepted cost, pinned so it is a decision rather than an accident: a RELATIVE option value of exactly
# the scope shape IS refused. No caller passes one; see the header for why the rule does not skip values.
assert_equals "a relative value of exactly the scope shape is refused, knowingly" "0|FooTests/out" \
  "$(bare_of -resultBundlePath FooTests/out)"
assert_equals "a shell fixture path is not" "1|" "$(bare_of scripts/verify-and-merge-branch.test.sh)"
assert_equals "a source file name is not (no scope can be derived from it)" "1|" "$(bare_of OvertureTests/RunSlotTests.swift)"
assert_equals "a target name with no suite is not (a -scheme or -testPlan value looks the same)" "1|" \
  "$(bare_of OvertureTests)"
assert_equals "no arguments at all is not" "1|" "$(bare_of)"

# --- the message names the exact form to write ----------------------------------------------------------
assert_equals "the corrected form is the prefix and the scope, nothing else" \
  "-only-testing:OvertureTests/SomeSuite/runsOnce()" "$(bare_test_scope_corrected 'OvertureTests/SomeSuite/runsOnce()')"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All test-scope-shape.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} test-scope-shape.sh fixture(s) failed."
  exit 1
fi
