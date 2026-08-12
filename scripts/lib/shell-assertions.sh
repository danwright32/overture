#!/usr/bin/env bash
# The one assertion vocabulary every *.test.sh fixture in this repo can rely on (#2501).
#
# Before this file, each of the 48 fixtures defined its own helpers, and which names existed varied
# file to file: 22 defined assert_contains, 13 assert_equals, 10 assert_eq, 6 assert_empty. Reaching
# for a name the file in front of you happens not to define is silent. It printed "command not found"
# to stderr, the assertion did nothing, and the fixture still reported every check passing. That is
# what happened on 2026-08-11 in scripts/verify-and-merge-branch.test.sh, where three assertions were
# written against assert_contains, which that file does not define, and the run ended with "All
# verify-and-merge-branch.sh fixtures passed."
#
# Two things close that. This file makes the vocabulary the same everywhere, so a name a fixture does
# not define is a typo rather than another file's spelling. scripts/run-shell-fixtures.sh fails any
# fixture whose output shows bash could not resolve a command, so the class cannot come back through a
# fixture that forgets to source this one.
#
# Sourcing it does NOT change any fixture that defines its own helpers: a definition after the source
# line replaces the shared one. That matters, because the argument orders were not unanimous either.
# The orders here are the majority ones (assert_contains took the haystack second in 20 of 22 files,
# assert_equals the expected value second in all 13), and the handful of fixtures that read them the
# other way round keep their own definitions and their own meaning.
#
# Every helper reports through FAILURES, the counter 129 of the repo's fixtures already use, and none
# of them exits: a fixture runs all its checks and reports the total at the end, so one failure never
# hides the ones behind it.

# Bumps the shared counter without tripping `set -u` in a fixture that never initialised it.
shell_assertion_record_failure() {
  FAILURES=$(( ${FAILURES:-0} + 1 ))
}

pass() {
  echo "ok - $1"
}

fail() {
  echo "FAIL - $1"
  if [[ -n "${2:-}" ]]; then echo "  $2"; fi
  shell_assertion_record_failure
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    shell_assertion_record_failure
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected NOT to contain: ${needle}"
    echo "  in: ${haystack}"
    shell_assertion_record_failure
  fi
}

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    shell_assertion_record_failure
  fi
}

# The short spelling, same meaning and same argument order as assert_equals.
assert_eq() {
  assert_equals "$@"
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected nothing, got: ${actual}"
    shell_assertion_record_failure
  fi
}
