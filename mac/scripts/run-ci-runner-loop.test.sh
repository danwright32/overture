#!/usr/bin/env bash
set -uo pipefail

# #881: the CI runner loop can deadlock on a dead session, and CI stops forever.
#
# 2026-07-13: swift-tests sat queued indefinitely. The runner PROCESS was alive and its own log's last
# line said "Listening for Jobs", but GitHub listed ZERO runners: it was holding a session GitHub no
# longer recognised, so it would never be assigned a job. The loop could not recover, because it blocked
# on `wait "${RUN_PID}"` and run.sh never exits while it is listening. Nothing merged until the
# LaunchAgent was restarted by hand.
#
# A live process is NOT evidence of a live runner. The only authority is whether GitHub still lists it.
#
# The hard part is the same one as everywhere else in this repo: not crying wolf. A network blip or a
# failed API call is NOT evidence that the runner is gone, and killing a HEALTHY runner mid-job because
# GitHub was briefly unreachable would be a worse bug than the one being fixed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_success() {
  local desc="$1"; shift
  if "$@"; then echo "ok - ${desc}"; else
    echo "FAIL - ${desc} (expected success, got exit $?)"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_failure() {
  local desc="$1"; shift
  if "$@"; then
    echo "FAIL - ${desc} (expected failure, got success)"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${desc}"
  fi
}

# Stubbed `gh`, mirroring check-pr-ci.test.sh. STUB_RUNNER controls what GitHub "reports":
#   online <name>  -> that runner is registered and idle
#   busy <name>    -> registered and mid-job
#   none           -> registered runners list is empty (the zombie case)
#   error          -> the API call itself failed (a blip; NOT evidence of absence)
gh() {
  local args="$*"
  # runner_state goes through the real gh_as_danwright32 wrapper, so the token call is on the path.
  if [[ "${args}" == "auth token"* ]]; then
    echo "stub-token"
    return 0
  fi
  if [[ "${args}" == *"/actions/runners"* ]]; then
    case "${STUB_RUNNER:-none}" in
      online) echo "Daniels-MacBook-Pro-2-overture-ci	online	false"; return 0 ;;
      busy)   echo "Daniels-MacBook-Pro-2-overture-ci	online	true";  return 0 ;;
      none)   return 0 ;;                       # empty list, exit 0
      error)  echo "api error" >&2; return 1 ;;
    esac
  fi
  echo "run-ci-runner-loop.test.sh: unstubbed gh call: ${args}" >&2
  return 1
}
export -f gh 2>/dev/null || true

# shellcheck source=./run-ci-runner-loop.sh
source "${SCRIPT_DIR}/run-ci-runner-loop.sh"
set +e

# --- runner_state: what GitHub actually says --------------------------------------------------------

STUB_RUNNER=online
assert_equals "a registered idle runner reads as registered" "registered" "$(runner_state)"

# Mid-job. It MUST read as registered, or the supervisor would kill a runner while it is building.
STUB_RUNNER=busy
assert_equals "a runner mid-job reads as registered, never as gone" "registered" "$(runner_state)"

# The 2026-07-13 zombie: process alive, GitHub's list empty.
STUB_RUNNER=none
assert_equals "an empty runner list reads as absent" "absent" "$(runner_state)"

# THE cry-wolf guard. A failed API call tells us nothing about the runner. It must never be mistaken
# for "the runner is gone", or a network blip would kill a healthy runner mid-build.
STUB_RUNNER=error
assert_equals "an API failure reads as unknown, never as absent" "unknown" "$(runner_state)"

# --- next_strikes: only real absence accumulates toward a kill ---------------------------------------

assert_equals "a registered runner clears the strike count" "0" "$(next_strikes registered 2)"
assert_equals "an absent runner adds a strike" "3" "$(next_strikes absent 2)"

# The same guard, at the counter. An unknown state HOLDS: it neither clears the count (a real zombie
# must still be caught across a blip) nor advances it (a blip must never kill a healthy runner).
assert_equals "an unknown state holds the count rather than advancing it" "2" "$(next_strikes unknown 2)"
assert_equals "and a run of unknowns alone never reaches a kill" "0" "$(next_strikes unknown 0)"

# --- is_zombie: the verdict --------------------------------------------------------------------------

assert_failure "one strike is not yet a zombie" is_zombie 1 3
assert_failure "two strikes is not yet a zombie" is_zombie 2 3
assert_success "the threshold is a zombie" is_zombie 3 3
assert_success "past the threshold is still a zombie" is_zombie 9 3

# A single absent probe must NOT kill the runner: the window between an ephemeral runner finishing a job
# (GitHub deregisters it) and run.sh exiting is legitimately absent for a moment.
assert_failure "a single absent probe never kills a runner on its own" is_zombie 1 "${LIVENESS_STRIKES}"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all run-ci-runner-loop.sh liveness checks passed"
