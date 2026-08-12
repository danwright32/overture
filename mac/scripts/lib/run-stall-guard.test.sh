#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #2506: a heartbeat proves its EMITTER is alive and nothing else.
#
# Measured on the live machine on 2026-08-11: a paid scout extract run of 27 sources across 4 chunks
# finished its actual work at 10:47 and was still reporting "26 of 27, running" at 11:43. One chunk's
# worker died having written nothing at all (a zero byte chunk log), so its `wait` could never return,
# while the heartbeat went on touching the marker every few seconds. The 10 minute staleness window could
# never fire, because the marker was never stale. The results file was re-touched on the same cadence
# while its CONTENT never changed (identical digests twenty five seconds apart).
#
# So liveness has to be tied to observed PROGRESS, not to the watchdog's own pulse. These checks pin the
# tick that does that: the signature of what the run has actually produced, the accumulation of how long
# it has stood still, and the verdict that ends the run once it has stood still too long.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert() {
  local desc="$1"; shift
  if "$@"; then echo "ok - ${desc}"; else echo "FAIL - ${desc}"; FAILURES=$((FAILURES + 1)); fi
}
refute() {
  local desc="$1"; shift
  if "$@"; then echo "FAIL - ${desc}"; FAILURES=$((FAILURES + 1)); else echo "ok - ${desc}"; fi
}
assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "${want}" = "${got}" ]; then echo "ok - ${desc}"
  else echo "FAIL - ${desc} (want '${want}', got '${got}')"; FAILURES=$((FAILURES + 1)); fi
}

# Every helper this file exercises must EXIST before a single assertion runs. A mistyped or absent
# function makes `refute` pass for the wrong reason forever, which is exactly how three assertions in
# this repo once reported green while printing "command not found" to stderr (L100, #2501).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/run-stall-guard.sh"
for fn in stall_signature stall_tick stall_stalled_seconds; do
  if ! command -v "${fn}" >/dev/null 2>&1; then
    echo "FAIL - ${fn} is not defined by run-stall-guard.sh"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${fn} is defined"
  fi
done
if [ "${FAILURES}" -ne 0 ]; then echo "${FAILURES} failure(s)"; exit 1; fi

TMP="$(mktemp -d)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# The signature is of the file's CONTENT, never of its mtime. This is the whole point: the file in the
# incident was re-touched every few seconds while saying the same thing.
# ---------------------------------------------------------------------------
RESULTS="${TMP}/results.json"
printf '{"results":[{"sourceId":"a"}]}' > "${RESULTS}"
SIG_A="$(stall_signature "${RESULTS}")"
assert "a readable results file has a signature" test -n "${SIG_A}"

# The sleep is load-bearing, not padding. Without it a signature built from the file's TIMESTAMP passes
# this check too (two touches inside one clock tick stamp the same time), and the check would then be
# green against the very defect it exists to catch. Measured: with `stat` substituted for the digest,
# this assertion stays green at 0s and goes red at 1.1s.
sleep 1.1
touch "${RESULTS}"
assert_eq "re-touching the file without changing it keeps the same signature" \
  "${SIG_A}" "$(stall_signature "${RESULTS}")"

printf '{"results":[{"sourceId":"a"},{"sourceId":"b"}]}' > "${RESULTS}"
SIG_B="$(stall_signature "${RESULTS}")"
refute "a file that gained a result has a different signature" test "${SIG_A}" = "${SIG_B}"

# An absent file is its own stable signature, never an empty string that would compare equal to an
# unreadable one by accident. A run that has produced nothing yet is standing still, and must be counted
# as standing still: on the incident's own shape, that is the first thirty seconds of every healthy run
# and the entire duration of a dead one.
ABSENT_SIG="$(stall_signature "${TMP}/never-written.json")"
assert "an absent results file still has a signature" test -n "${ABSENT_SIG}"
assert_eq "an absent results file signs the same way twice" \
  "${ABSENT_SIG}" "$(stall_signature "${TMP}/never-written.json")"

# ---------------------------------------------------------------------------
# The tick: work landing resets the stall clock, work not landing accumulates it, and the verdict
# arrives only once the accumulation passes the limit.
# ---------------------------------------------------------------------------
STATE="${TMP}/stall-state"
printf '{"results":[]}' > "${RESULTS}"

assert "the first tick of a run carries on" stall_tick "${RESULTS}" "${STATE}" 60 300
assert_eq "the first tick has accrued no stalled time" "0" "$(stall_stalled_seconds "${STATE}")"

assert "a tick with nothing new carries on while under the limit" stall_tick "${RESULTS}" "${STATE}" 60 300
assert_eq "a tick with nothing new accrues the interval" "60" "$(stall_stalled_seconds "${STATE}")"

assert "a second idle tick carries on" stall_tick "${RESULTS}" "${STATE}" 60 300
assert_eq "idle ticks accumulate" "120" "$(stall_stalled_seconds "${STATE}")"

# Work lands: the clock goes back to zero, however long it had been standing still.
printf '{"results":[{"sourceId":"a"}]}' > "${RESULTS}"
assert "a tick that saw new work carries on" stall_tick "${RESULTS}" "${STATE}" 60 300
assert_eq "new work resets the stall clock" "0" "$(stall_stalled_seconds "${STATE}")"

# And now stand still past the limit.
for _ in 1 2 3 4; do
  stall_tick "${RESULTS}" "${STATE}" 60 300 >/dev/null 2>&1
done
assert_eq "four idle ticks accrue four intervals" "240" "$(stall_stalled_seconds "${STATE}")"
refute "a run that reaches the limit exactly is stopped" \
  stall_tick "${RESULTS}" "${STATE}" 60 300
assert_eq "the stopping tick accrued the interval that took it there" \
  "300" "$(stall_stalled_seconds "${STATE}")"

# The verdict must not depend on the limit being hit exactly. A run well past it stays stopped.
refute "a run well past the limit stays stopped" stall_tick "${RESULTS}" "${STATE}" 60 300

# A limit of 0 or a nonsense limit must not turn the guard into a killer of healthy runs: an
# unparseable limit means "no ceiling was configured", and the fail-safe there is to let the run work.
FRESH="${TMP}/fresh-state"
stall_tick "${RESULTS}" "${FRESH}" 60 "" >/dev/null 2>&1   # prime it so the next tick IS standing still
assert "an unset limit never stops a run" stall_tick "${RESULTS}" "${FRESH}" 60 ""
assert_eq "an unset limit still records how long the run has stood still" \
  "60" "$(stall_stalled_seconds "${FRESH}")"
FRESH2="${TMP}/fresh-state-2"
stall_tick "${RESULTS}" "${FRESH2}" 60 "soon" >/dev/null 2>&1
assert "a non-numeric limit never stops a run" stall_tick "${RESULTS}" "${FRESH2}" 60 "soon"

# ---------------------------------------------------------------------------
# Every runner must actually CALL this, and hand it the results file it defines. A guard that exists and
# is never wired is indistinguishable from no guard (L3).
# ---------------------------------------------------------------------------
RUNNERS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
for runner in prep-run.sh scout-extract-run.sh reply-classify-run.sh; do
  path="${RUNNERS_DIR}/${runner}"
  assert "${runner} sources the shared stall guard" grep -q 'lib/run-stall-guard.sh' "${path}"

  # Inside the heartbeat's OWN region, not merely somewhere in the file: a call in the main body would
  # run once and vouch for nothing.
  loop_body="$(awk '/heartbeat_guard_exit/{f=1} f; /done \) &/{f=0}' "${path}")"
  assert "${runner}: the heartbeat's own region was found" test -n "${loop_body}"
  assert "${runner} runs the stall tick inside its heartbeat" \
    grep -q 'stall_tick' <<<"${loop_body}"

  # And the tick's verdict must END the loop. A tick whose non-zero return is swallowed (a trailing
  # `|| true`, an `if` with no exit) leaves the run doing exactly what it does today.
  assert "${runner} exits its heartbeat when the stall tick says stop" \
    grep -qE 'stall_tick[^|]*$' <<<"${loop_body}"
  refute "${runner} does not swallow the stall verdict" \
    grep -qE 'stall_tick.*\|\| true' <<<"${loop_body}"
done

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all run-stall-guard checks passed"
