#!/usr/bin/env bash
# #4568: the one rule saying an argument is a TEST SCOPE written without its `-only-testing:` prefix.
#
# WHY. Twice on 2026-10-07 an agent passed `OvertureTests/SomeSuite` to scripts/mutate.sh (once single, once
# `--batch`) with the prefix left off. Nothing refused it. run-tests-locked.sh handed it to xcodebuild after
# `test`, where it is not a scope at all: xcodebuild reads a bare word there as a BUILD ACTION and stops with
# `xcodebuild: error: Unknown build action 'OvertureTests/SomeSuite'.` and exit 65 (measured 2026-10-07).
# The runner classifies that output as `crashed` (a red with no named test), retries it once, and then asks
# the pure suite with no scope at all, which is the whole OvertureCore scheme: about 24 minutes and 10,935
# tests on 2026-10-06, holding the shared test lock every agent and project on this Mac waits on. A tool
# taking a target must refuse one it cannot use, never fall back to its default scope (L320).
#
# WHO READS IT. scripts/mutate.sh (the single form, before the file is touched), scripts/lib/mutate-batch.sh
# (once for the whole batch, before any entry is read or the lock is queued for), and
# mac/scripts/run-tests-locked.sh (before the lock), the last because any caller can reach it the same way.
# One predicate in one place, so the three can never disagree about what a bare scope is (L263).
#
# THE SHAPE, and why it is no wider. `<Target>/<Suite>` optionally followed by `/<test>`, where the target is
# an identifier ending in `Tests` (every test target this project has, OvertureTests and OvertureHostedTests,
# and the naming every Xcode test target takes by default) and the suite is an identifier. Narrower than
# "any argument not starting with a dash" on purpose (L93): xcodebuild options take values that do not start
# with one (`-parallel-testing-enabled YES`, `-resultBundlePath <dir>`, `-destination platform=macOS`), and a
# rule refusing those would refuse the ordinary case. Two near shapes are deliberately left out:
#
#   * a target name ALONE (`OvertureTests`), because `-scheme`, `-testPlan` and `-target` take a name of
#     exactly that shape as their value, and nothing here can tell which reading was meant;
#   * a suite carrying a dot (`OvertureTests/RunSlotTests.swift`), which is a file rather than a scope and is
#     mutate.sh's SCOPE NOT FOR THIS RUNNER to refuse, in its own words.

# bare_test_scope <arg...>: prints the FIRST argument shaped like a test scope with its `-only-testing:`
# prefix left off, and returns 0. Returns 1, printing nothing, when no argument has that shape.
bare_test_scope() {
  local arg
  for arg in "$@"; do
    if [[ "${arg}" =~ ^[A-Za-z_][A-Za-z0-9_]*Tests/[A-Za-z_][A-Za-z0-9_]*(/[^[:space:]=/]+)?/?$ ]]; then
      printf '%s\n' "${arg}"
      return 0
    fi
  done
  return 1
}

# bare_test_scope_corrected <bare scope>: the exact argument to write instead. Only the prefix is added,
# so the message can never suggest a scope other than the one that was asked for.
bare_test_scope_corrected() {
  printf '%s\n' "-only-testing:$1"
}
