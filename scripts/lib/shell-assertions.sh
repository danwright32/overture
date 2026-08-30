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

# assert_pids_gone <description> <pid>...
#
# Waits, up to a deadline, for every pid named to be gone, and reports one verdict (#3248).
#
# The only helper here that is about TIME rather than about a value, and it exists because sampling
# once is wrong. A fixture that stops a background job and immediately asks `kill -0` whether its
# children are gone is asking a question the answer to which depends on how busy the Mac is: the
# signal has been delivered, the process has not been reaped yet, and it reads as a leak. That failed
# a merge on 2026-08-29 (`still alive: 20800`, while the Swift suite ran beside it) on a change whose
# own work was green. Waiting on the condition rather than on a fixed delay is also the faster answer,
# because the ordinary case returns on the first poll (L290, L524).
#
# It has a DEADLINE because a wait without one cannot fail, it can only hang, and a hang is worse than
# a failure: it is indistinguishable from slowness and holds whatever the run was holding (L110). The
# deadline is generous, since it is a bound on a pathology rather than a measurement of speed, and it
# is injectable so the fixture proving the failing verdict does not have to wait it out.
#
# Being given NO pids fails rather than passes. Every caller collects the pids first and has already
# asserted that it found some, so an empty list means that collection came back empty, and zero
# subjects examined must never read as the cleanest possible pass (L98).
SHELL_ASSERTION_PIDS_GONE_DEADLINE_SECONDS="${SHELL_ASSERTION_PIDS_GONE_DEADLINE_SECONDS:-15}"
SHELL_ASSERTION_PIDS_GONE_POLL_SECONDS="${SHELL_ASSERTION_PIDS_GONE_POLL_SECONDS:-0.05}"

assert_pids_gone() {
  local desc="$1"; shift
  local pids=() pid alive started_at now
  for pid in "$@"; do
    [[ -n "${pid}" ]] && pids+=("${pid}")
  done

  if [[ "${#pids[@]}" -eq 0 ]]; then
    echo "FAIL - ${desc}"
    echo "  no pids were given, so nothing was waited for and nothing was measured"
    shell_assertion_record_failure
    return 0
  fi

  # Elapsed time comes from the shell's own clock, never from adding up the sleeps: a timer built by
  # summing its own delays counts iterations rather than seconds, and every poll costs more than the
  # sleep it asked for (L226).
  started_at="${SECONDS}"
  while :; do
    alive=""
    for pid in "${pids[@]}"; do
      kill -0 "${pid}" 2>/dev/null && alive="${alive} ${pid}"
    done
    [[ -n "${alive// /}" ]] || break
    now="${SECONDS}"
    if [[ $(( now - started_at )) -ge "${SHELL_ASSERTION_PIDS_GONE_DEADLINE_SECONDS}" ]]; then
      echo "FAIL - ${desc}"
      echo "  still alive after ${SHELL_ASSERTION_PIDS_GONE_DEADLINE_SECONDS}s:${alive}"
      shell_assertion_record_failure
      return 0
    fi
    sleep "${SHELL_ASSERTION_PIDS_GONE_POLL_SECONDS}"
  done

  echo "ok - ${desc}"
}
