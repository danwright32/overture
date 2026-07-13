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

# --- supervise_run notices a FINISHED job promptly ---------------------------------------------------
#
# The supervisor must not make the normal path slower. Observed live on 2026-07-13: a job finished at
# 14:19:09 and the next cycle did not start until 14:19:59, because the supervisor slept a whole probe
# interval before looking at the process at all. Fifty seconds of dead time after EVERY job, and the
# runner is unavailable for the next one throughout.
#
# Asking GitHub every 60s is right; noticing a finished job only every 60s is not. Process liveness is
# free to check, so it is checked on a short tick while GitHub is still probed on the long interval.
STUB_RUNNER=online
LIVENESS_INTERVAL=20            # a long probe interval...
LIVENESS_TICK=1                 # ...must not delay noticing the process is gone

sleep 1 &
FAKE_RUN_PID=$!
STARTED_AT="$(date +%s)"
supervise_run "${FAKE_RUN_PID}"
SUPERVISE_EXIT=$?
ELAPSED=$(( $(date +%s) - STARTED_AT ))

assert_equals "a job that finished on its own is not reported as a zombie" "0" "${SUPERVISE_EXIT}"
if (( ELAPSED < 8 )); then
  echo "ok - a finished job is noticed within seconds (${ELAPSED}s), not after a full probe interval"
else
  echo "FAIL - a finished job took ${ELAPSED}s to notice; the supervisor is sleeping through it"
  FAILURES=$((FAILURES + 1))
fi

# --- supervise_run actually KILLS a zombie ------------------------------------------------------------
#
# The whole point, end to end. A listener that GitHub has stopped listing will never be given a job and
# will never exit on its own: that is the 2026-07-13 deadlock. It must be killed so a fresh cycle can
# re-register. Tested against a REAL process, not just the decision functions, because "it decided to
# kill" and "it killed" are different claims and only the second one unblocks CI.
STUB_RUNNER=none                # GitHub does not list it: the zombie
LIVENESS_INTERVAL=1
LIVENESS_TICK=1
LIVENESS_STRIKES=2

sleep 300 &                     # a listener that would otherwise hang forever
ZOMBIE_PID=$!
supervise_run "${ZOMBIE_PID}"
ZOMBIE_EXIT=$?

assert_equals "a zombie is reported as one, so the loop starts a fresh cycle" "1" "${ZOMBIE_EXIT}"
if kill -0 "${ZOMBIE_PID}" 2>/dev/null; then
  echo "FAIL - the zombie listener is STILL RUNNING; CI would stay dead"
  FAILURES=$((FAILURES + 1))
  kill -9 "${ZOMBIE_PID}" 2>/dev/null
else
  echo "ok - the zombie listener is actually dead, not merely diagnosed"
fi

# And the counterpart: a HEALTHY runner is never killed, no matter how long it listens. This is the
# regression that would hurt most, because it would break CI on a machine where CI was working.
STUB_RUNNER=online
LIVENESS_INTERVAL=1
LIVENESS_TICK=1
LIVENESS_STRIKES=2

sleep 4 &
HEALTHY_PID=$!
supervise_run "${HEALTHY_PID}"
HEALTHY_EXIT=$?

assert_equals "a healthy runner listening a long time is never killed" "0" "${HEALTHY_EXIT}"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all run-ci-runner-loop.sh liveness checks passed"
