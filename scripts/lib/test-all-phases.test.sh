#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

# Coverage for scripts/lib/test-all-phases.sh (#2603): the reporting decisions that come with running
# the cheap checks BESIDE the Swift suite instead of after it.
#
# The properties worth testing are the ones a real four minute suite run proves slowly and only for
# whichever lane happened to be red that day:
#   1. a cheap failure does not stop the cheap checks behind it
#   2. a cheap failure does not swallow the Swift verdict, and a Swift failure does not swallow the
#      cheap ones (L53: two independent checks must never share one status field)
#   3. when both lanes fail, BOTH are named
#   4. nothing written to the background log is lost, including lines written before streaming starts
#      and the last line if it has no trailing newline
#
# Every case drives fake phases (sh -c 'exit 1', a loop writing to a file), so the whole file runs in
# milliseconds and never invokes xcodebuild.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./test-all-phases.sh
source "${SCRIPT_DIR}/test-all-phases.sh"
set +e

FAILURES=0

# The recorded cheap failures as one string. Written through the `+` form because this Mac's bash is
# 3.2, where "${arr[@]}" on an EMPTY array is a fatal unbound-variable error under `set -u`, and half
# these cases assert that nothing was recorded.
cheap_failures() {
  printf '%s' "${TEST_ALL_CHEAP_FAILURES[@]+${TEST_ALL_CHEAP_FAILURES[*]}}"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-all-phases-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- run_foreground_check: records failures, never exits, keeps going ---

TEST_ALL_CHEAP_FAILURES=()
run_foreground_check "green one" true >/dev/null
run_foreground_check "red one" false >/dev/null
run_foreground_check "green two" true >/dev/null
RAN_AFTER_FAILURE="ran"
assert_eq "a failing cheap check does not stop the ones behind it" "ran" "${RAN_AFTER_FAILURE}"
assert_eq "exactly the failing check is recorded" "red one" "$(cheap_failures)"

TEST_ALL_CHEAP_FAILURES=()
run_foreground_check "red one" false >/dev/null
run_foreground_check "red two" sh -c 'exit 3' >/dev/null
assert_eq "every failing check is recorded, not just the first" \
  "red one red two" "$(cheap_failures)"

TEST_ALL_CHEAP_FAILURES=()
IMMEDIATE="$(run_foreground_check "typecheck" false 2>&1)"
assert_contains "a cheap failure is announced when it happens, not only in the summary" \
  "${IMMEDIATE}" "FAILED - typecheck"
assert_contains "and says the Swift suite is still running, so the wait is not mistaken for a hang" \
  "${IMMEDIATE}" "still running"

# A check whose command carries arguments must run with them, rather than the label being taken as one.
TEST_ALL_CHEAP_FAILURES=()
ARG_OUT="$(run_foreground_check "echoing check" echo "hello there" 2>&1)"
assert_contains "the command runs with its own arguments" "${ARG_OUT}" "hello there"
assert_empty "a passing check records nothing" "$(cheap_failures)"

# --- report_phase_results: both lanes always accounted for ---

TEST_ALL_CHEAP_FAILURES=()
OUT="$(report_phase_results "the Swift suite" 0 2>&1)"
assert_eq "both lanes green is a pass" "0" "$?"
assert_contains "both lanes green says so in one line" "${OUT}" "all suites passed"

TEST_ALL_CHEAP_FAILURES=("pnpm typecheck")
OUT="$(report_phase_results "the Swift suite" 0 2>&1)"
STATUS=$?
assert_eq "a cheap failure beside a green Swift run is still a red overall" "1" "${STATUS}"
assert_contains "the failing cheap check is named" "${OUT}" "pnpm typecheck"
# The half that a shared status field would lose: the Swift lane's own verdict.
assert_contains "the Swift verdict is reported even though a cheap check failed" \
  "${OUT}" "the Swift suite passed"

TEST_ALL_CHEAP_FAILURES=()
OUT="$(report_phase_results "the Swift suite" 65 2>&1)"
STATUS=$?
assert_eq "a failing Swift run with every cheap check green is red overall" "1" "${STATUS}"
assert_contains "the Swift failure names its exit status" "${OUT}" "exit 65"
# The mirror image: a green cheap lane must not read as though nothing else ran.
assert_contains "the cheap lane's clean result is stated too" "${OUT}" "every cheap check passed"

TEST_ALL_CHEAP_FAILURES=("pnpm test" "scripts/run-shell-fixtures.sh")
OUT="$(report_phase_results "the Swift suite" 1 2>&1)"
STATUS=$?
assert_eq "both lanes red is red" "1" "${STATUS}"
assert_contains "both cheap failures are named when the Swift suite failed too" "${OUT}" "pnpm test"
assert_contains "the second cheap failure is named as well" "${OUT}" "run-shell-fixtures.sh"
assert_contains "and the Swift failure is named beside them" "${OUT}" "the Swift suite failed"

# --- start_background_phase and stream_and_wait: nothing written is lost ---

LOG="${TMP_DIR}/phase.log"
start_background_phase "${LOG}" sh -c 'echo first; echo second; exit 0'
PID="${BACKGROUND_PHASE_PID}"
# Deliberately give the phase time to finish and to write BEFORE streaming starts, which is the real
# shape: the cheap lane takes about a minute, and the Swift suite has been writing the whole time.
sleep 0.5
STREAMED="$(stream_and_wait "${LOG}" "${PID}")"
STREAM_STATUS=$?
assert_contains "a line written before streaming started is still printed" "${STREAMED}" "first"
assert_contains "and so is the last one" "${STREAMED}" "second"
assert_eq "a clean background phase reports 0" "0" "${STREAM_STATUS}"

# The one that matters most: the FINAL lines, which is where TEST SUCCEEDED, the failing test names and
# the Suite shape line live. Written slowly, so the streamer reaches EOF while the writer is still alive
# and has to come back for more.
LOG2="${TMP_DIR}/phase2.log"
start_background_phase "${LOG2}" sh -c 'echo early; sleep 1; echo late; printf "** TEST SUCCEEDED **\n"; exit 0'
PID2="${BACKGROUND_PHASE_PID}"
STREAMED2="$(stream_and_wait "${LOG2}" "${PID2}")"
assert_contains "a line written after streaming started is printed" "${STREAMED2}" "late"
assert_contains "the final line is never lost to a race with the streamer" "${STREAMED2}" "TEST SUCCEEDED"

# A failing background phase's status reaches the caller, since the whole combined verdict hangs off it.
LOG3="${TMP_DIR}/phase3.log"
start_background_phase "${LOG3}" sh -c 'echo failing; exit 65'
PID3="${BACKGROUND_PHASE_PID}"
STREAMED3="$(stream_and_wait "${LOG3}" "${PID3}")"
assert_eq "a failing background phase's exit status is returned, not swallowed" "65" "$?"
assert_contains "its output is still streamed" "${STREAMED3}" "failing"

# A last line with NO trailing newline (a crash mid-write, or a tool that does not end with one) must
# still be printed rather than silently dropped.
LOG4="${TMP_DIR}/phase4.log"
start_background_phase "${LOG4}" sh -c 'printf "no trailing newline"; exit 0'
PID4="${BACKGROUND_PHASE_PID}"
STREAMED4="$(stream_and_wait "${LOG4}" "${PID4}")"
assert_contains "a final line with no trailing newline is still printed" "${STREAMED4}" "no trailing newline"

# A phase KILLED before it could record an outcome must not read as a pass. This is the case that made
# the status come from a file rather than from `wait`: `wait` answers only for a child of the shell
# asking, and its refusal (255) is indistinguishable from the phase itself having failed, while a status
# nobody wrote must be reported as exactly that.
LOG5="${TMP_DIR}/phase5.log"
start_background_phase "${LOG5}" sh -c 'echo working; sleep 30'
PID5="${BACKGROUND_PHASE_PID}"
STATUS_FILE5="${BACKGROUND_PHASE_STATUS_FILE}"
sleep 0.3
kill -9 "${PID5}" 2>/dev/null
KILLED_OUT="$(stream_and_wait "${LOG5}" "${PID5}" "${STATUS_FILE5}")"
KILLED_STATUS=$?
if [[ "${KILLED_STATUS}" -ne 0 ]]; then
  pass "a phase killed before it recorded an outcome is not a pass"
else
  fail "a phase killed before it recorded an outcome must not report success"
fi
assert_contains "and says that is why, rather than looking like an ordinary failure" \
  "${KILLED_OUT}" "never recorded how it ended"

# --- the phase gets a process group of its own (#3248) -----------------------------------------------
#
# Everything above is satisfied by a job started with no job control at all, because a job in the
# shell's own process group is started, streamed and waited on identically: the only thing it cannot do
# is be stopped WHOLE. The one `set -m` that arranges it is therefore invisible to every behavioural
# assertion in this file, and a later edit removing it would take nothing red with it while quietly
# restoring the orphan (L281). So it is asserted directly, on the running process, rather than by
# reading the source for the flag.
LOG6="${TMP_DIR}/phase6.log"
start_background_phase "${LOG6}" sh -c 'sleep 30'
PID6="${BACKGROUND_PHASE_PID}"
STATUS_FILE6="${BACKGROUND_PHASE_STATUS_FILE}"
JOB_PGID="$(ps -o pgid= -p "${PID6}" 2>/dev/null | tr -d ' ')"
SHELL_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
assert_equals "the background phase leads a process group of its own" "${PID6}" "${JOB_PGID}"
# Both halves, because the first is also satisfied by a shell that happens to be its own group leader,
# in which case there is no group to address that is not the whole run (L70).
assert_equals "which is not the run's own group, so stopping it cannot take the run with it" \
  "different" \
  "$(if [[ "${JOB_PGID}" != "${SHELL_PGID}" ]]; then echo "different"; else echo "the same: ${JOB_PGID}"; fi)"
PHASE6_CHILDREN="$(pgrep -P "${PID6}" 2>/dev/null | tr '\n' ' ')"
assert_equals "and it really has a child of its own to leave behind" \
  "has a child" \
  "$(if [[ -n "${PHASE6_CHILDREN// /}" ]]; then echo "has a child"; else echo "none, so the next line proves nothing"; fi)"
# Timed, because "everything is gone afterwards" is also what a job that simply RAN OUT looks like: with
# no group to signal, the kill reaches nothing and the `wait` behind it sits for the job's whole life,
# after which the assertion below passes for a reason unrelated to stopping anything (L165). The bound
# is against a 30 second job and a stop that returns in milliseconds, so it is nowhere near what this
# Mac's load can move.
PHASE6_STOP_STARTED_AT="${SECONDS}"
stop_background_phase "${PID6}"
PHASE6_STOP_TOOK=$(( SECONDS - PHASE6_STOP_STARTED_AT ))
assert_equals "stopping the phase returns at once rather than waiting the job out" \
  "prompt" \
  "$(if [[ "${PHASE6_STOP_TOOK}" -le 5 ]]; then echo "prompt"; else echo "took ${PHASE6_STOP_TOOK}s of a 30s job"; fi)"
# shellcheck disable=SC2086
assert_pids_gone "and stopping it takes the wrapper and its child together" "${PID6}" ${PHASE6_CHILDREN}
rm -f "${STATUS_FILE6}"

# --- the vacuous-guard advisory warns and does not block, and can be made to block -------------------
#
# Dan's standing rule is that he wants the override on anything, with the reason named in the message. It
# shipped as a hard gate first; this pins the correction, and pins that the override really does the other
# thing, so "advisory" cannot quietly become "absent".
TA_SRC="$(cat "${SCRIPT_DIR}/../test-all.sh")"
assert_contains "the vacuous-guard check rides along" "${TA_SRC}" "pnpm find-vacuous-guards"
assert_contains "it names an override" "${TA_SRC}" "OVERTURE_VACUOUS_GUARDS_STRICT"
assert_contains "and its message says it is not failing the run" "${TA_SRC}" "does NOT fail the run"
# The gate half. Without the override it must NOT reach the failure list; with it, it must, so advisory
# cannot quietly become absent.
TA_BLOCK_LINE="$(printf '%s' "${TA_SRC}" | grep -n 'TEST_ALL_CHEAP_FAILURES+=("pnpm find-vacuous-guards")' | cut -d: -f1)"
assert_equals "it can still be made blocking" "1" "$([ -n "${TA_BLOCK_LINE}" ] && echo 1 || echo 0)"
TA_GUARD="$(printf '%s' "${TA_SRC}" | sed -n "$((TA_BLOCK_LINE - 1))p")"
assert_contains "and that path is reachable only through the override" "${TA_GUARD}" "OVERTURE_VACUOUS_GUARDS_STRICT"

# --- the shared-state check rides along, advisory, and its UNMEASURED verdict does NOT (#3270) -------
#
# The check itself is proved by scripts/check-test-shared-state.test.sh. What is proved HERE is that
# anything runs it at all: a guard nobody invokes is a value with no writer (L46), and #2773 is the
# record of what that costs (the tool shipped, nothing ran it, 17 entries accumulated).
#
# Its three exit codes are not one thing. 1 is advisory, because a new stored static may be perfectly
# safe and a rule that fires on the ordinary case gets switched off (L93). 2 is UNMEASURED and DOES fail
# the run, because a pass that examined nothing must never read like a pass that examined everything
# (L98, L11), and folding the two together is exactly how that happens.
assert_contains "the shared-state check rides along" "${TA_SRC}" "scripts/check-test-shared-state.sh"
assert_contains "and its findings say they are not failing the run" "${TA_SRC}" \
  "Advisory, so this does NOT fail the run. Give the suites that touch it a shared lock"
TA_SHARED_BLOCK_LINE="$(printf '%s' "${TA_SRC}" | grep -n 'TEST_ALL_CHEAP_FAILURES+=("scripts/check-test-shared-state.sh")' | cut -d: -f1)"
assert_equals "an unmeasured run still reaches the failure list" "1" \
  "$([ -n "${TA_SHARED_BLOCK_LINE}" ] && echo 1 || echo 0)"
TA_SHARED_GUARD="$(printf '%s' "${TA_SRC}" | sed -n "$((TA_SHARED_BLOCK_LINE - 1))p")"
assert_contains "and that path is reached only by exit 2, never by a finding" "${TA_SHARED_GUARD}" '= "2"'

# --- the dependency install happens BEFORE the working-tree snapshot (#3168) -------------------------
#
# check-tree-untouched.sh reports the IGNORED paths a run changed, and that report is only worth
# anything while it is silent on the ordinary run. It was not. `pnpm` installs missing dependencies by
# itself when a script is run, so the first `pnpm typecheck` in the cheap lane created `node_modules/`,
# and the snapshot recorded before it had no such path: every verify-and-merge run reported
# `appeared: node_modules/`, forever, starting with the very first one (merging #3167). The verify slot
# is scrubbed with `git clean -ffdx`, so it is the path where this is guaranteed rather than incidental.
#
# The remedy is ordering, not an exception list: a step the run is DEFINED to perform belongs before the
# measurement, so the snapshot is taken of a tree that already has the dependencies in it. An exception
# list naming `node_modules` would have to be maintained by hand and would go stale the way any
# registry-driven guard does (L96).
#
# Asserted as a LINE ORDER rather than as two presences, because both lines being present is exactly
# what the defect looked like.
TA_INSTALL_LINE="$(printf '%s' "${TA_SRC}" | grep -n '^pnpm install' | head -1 | cut -d: -f1)"
TA_RECORD_LINE="$(printf '%s' "${TA_SRC}" | grep -n 'check-tree-untouched.sh" record' | head -1 | cut -d: -f1)"
assert_equals "test-all.sh installs the node dependencies itself" \
  "1" "$([ -n "${TA_INSTALL_LINE}" ] && echo 1 || echo 0)"
assert_equals "test-all.sh records the working-tree snapshot" \
  "1" "$([ -n "${TA_RECORD_LINE}" ] && echo 1 || echo 0)"
assert_equals "the install runs BEFORE the snapshot, so node_modules is never reported as something the run left behind" \
  "1" "$([ -n "${TA_INSTALL_LINE}" ] && [ -n "${TA_RECORD_LINE}" ] && [ "${TA_INSTALL_LINE}" -lt "${TA_RECORD_LINE}" ] && echo 1 || echo 0)"
# It must not take the run down on its own. The cheap lane exists so one failure does not hide the
# others, and the Swift lane has not started yet at this point, so an install that dies under `set -e`
# would end the run before either lane reported anything. The pnpm checks in the cheap lane are what
# report a broken install, exactly as they did before this step existed.
TA_INSTALL_STMT="$(printf '%s' "${TA_SRC}" | sed -n "${TA_INSTALL_LINE:-0}p")"
assert_contains "and a failed install does not end the run before either lane has reported" \
  "${TA_INSTALL_STMT}" "||"

# --- the background lane is REAPED, so it leaves no notice in the output (#3105) ---------------------
#
# A killed background job is announced by the shell at the next command boundary, and the notice renders
# the job's WHOLE COMMAND TEXT. start_background_phase's job is a compound command, so a run cut short
# used to print `{ "$@" > "${log}" 2>&1; echo "$?" > "${status_file}"; }` into its own output. Observed
# live 2026-08-22: a `scripts/test-all.sh` run that ended early printed
# `scripts/lib/test-all-phases.sh: line 80: 82854 Terminated: 15          sleep 0.5`.
#
# Why it matters is #2981's and #3099's reason, and it has cost a real measurement once already: a log
# holding the PROGRAM as well as the EVENTS is one where a check reading it for a phrase matches code
# that never ran, and grepping a run log is the obvious thing to reach for. #2981 lost a concurrency
# measurement exactly that way, matching an `echo "... STOPPING ..."` statement rendered by one of these
# notices and reporting two healthy runs as stalled.
#
# `wait` reaps the job before the shell gets to report it, which is the whole fix (measured on this Mac,
# and the same remedy heartbeat_stop already applies in the detached runners).
STOP_DIR="${TMP_DIR}/stop-background-phase"
mkdir -p "${STOP_DIR}"

# Written as a script and run as its OWN bash process on purpose: the notice is printed by the shell that
# owns the job, so a subshell of this fixture would not show it the way a real run does.
# The job is given a distinctive argv[0] so it can be found by name rather than by walking a process
# tree that no longer exists: once the wrapper has been killed, its child is reparented to launchd and
# there is nothing left to ask `pgrep -P` (#3248). STOPPER_JOB_MARKER is set for the caller to look it
# up by, and carries this fixture's own pid so two runs on one Mac cannot see each other's jobs.
write_stopper() {
  local path="$1" stop_line="$2" injected="${3:-}"
  STOPPER_JOB_MARKER="overture-test-all-phases-job-$$-$(basename "${path}" .sh)"
  cat > "${path}" <<STOPPER
#!/usr/bin/env bash
set -uo pipefail
source "${SCRIPT_DIR}/test-all-phases.sh"
LOG="\$(mktemp "\${TMPDIR:-/tmp}/stopper-log.XXXXXX")"
trap '${stop_line} rm -f "\${LOG:-}" "\${BACKGROUND_PHASE_STATUS_FILE:-}"' EXIT
${injected}
start_background_phase "\${LOG}" bash -c 'exec -a ${STOPPER_JOB_MARKER} sleep 300'
PID="\${BACKGROUND_PHASE_PID}"
echo "\${PID}" > "${STOP_DIR}/\$(basename "\$0").pid"
# Waits until the job is really up before going on, so everything the caller then asserts is about
# STOPPING it rather than about whether it ever started. Without this the success case and the case
# where the wrapper died before it could fork are the same empty answer, and the assertion that the
# job is gone would pass hardest when there had never been one (L159, L98).
JOB=""
for _ in \$(seq 1 200); do
  JOB="\$(pgrep -f "${STOPPER_JOB_MARKER}" | tr '\\n' ' ')"
  [[ -n "\${JOB// /}" ]] && break
  sleep 0.05
done
echo "\${JOB}" > "${STOP_DIR}/\$(basename "\$0").job.pid"
echo "the run ends early, the way a fatal cheap check ends one"
exit 1
STOPPER
  chmod +x "${path}"
}

# The POSITIVE CONTROL first. Without it, "no notice was printed" is satisfied just as well by a fixture
# that could never see one, and the test would pass hardest when it was measuring nothing (L159).
write_stopper "${STOP_DIR}/bare-kill.sh" 'kill "${PID:-}" 2>/dev/null || true;'
# Output goes to a FILE, never a command substitution. The background job inherits the stopper's
# stderr, so `$(...)` would hold the pipe open until that job ended on its own, which both stalls the
# fixture for the whole sleep and lets a natural expiry stand in for a reap that never happened.
bash "${STOP_DIR}/bare-kill.sh" > "${STOP_DIR}/bare-kill.out" 2>&1
BARE_OUT="$(cat "${STOP_DIR}/bare-kill.out")"
assert_contains "a bare kill really does announce the job (the control)" "${BARE_OUT}" "Terminated"
assert_contains "and the notice renders the job's own body" "${BARE_OUT}" "status_file"

# The second half of the same control, and the one #3248 is about. The pid the helper is handed is the
# WRAPPER's, not the job's: start_background_phase runs a compound command, so the thing that does the
# work is a child of that wrapper. Killing the wrapper does not take its child with it on any Unix, so
# a bare kill leaves the real job running, orphaned to launchd, holding the run's stdout open. This is
# what the fixture itself did twice per run until now, measured 2026-08-29: two `sleep 300` survivors.
BARE_JOB_PIDS="$(cat "${STOP_DIR}/bare-kill.sh.job.pid" 2>/dev/null | tr '\n' ' ')"
assert_equals "and the job it started really is left running by a bare kill (the control)" \
  "left running" \
  "$(if [[ -n "${BARE_JOB_PIDS// /}" ]] && kill -0 ${BARE_JOB_PIDS} 2>/dev/null; then
       echo "left running"
     else
       echo "nothing was left, so the case below proves nothing"
     fi)"
# shellcheck disable=SC2086
kill ${BARE_JOB_PIDS} 2>/dev/null || true
assert_pids_gone "and this fixture cleans up the orphan its own control makes" ${BARE_JOB_PIDS}

# The same script, stopped through the helper.
write_stopper "${STOP_DIR}/reaped.sh" 'stop_background_phase "${PID:-}";'
bash "${STOP_DIR}/reaped.sh" > "${STOP_DIR}/reaped.out" 2>&1
REAPED_OUT="$(cat "${STOP_DIR}/reaped.out")"
# Asserted BEFORE the quiet, because quiet is also what a trap whose command does not exist produces:
# nothing is killed, so there is nothing for the shell to announce. Without this the whole case passes
# hardest when the helper is missing entirely, which is the state it was written to fail on.
REAPED_PID="$(cat "${STOP_DIR}/reaped.sh.pid" 2>/dev/null)"
assert_not_contains "the helper resolved, rather than being reported missing" "${REAPED_OUT}" "command not found"
assert_equals "and the phase it names is really gone" "0" "$(kill -0 "${REAPED_PID:-0}" 2>/dev/null && echo 1 || echo 0)"
assert_not_contains "stopping through the helper announces nothing" "${REAPED_OUT}" "Terminated"
assert_not_contains "so the job's body never reaches the output" "${REAPED_OUT}" "status_file"
assert_contains "and the run's own line is still printed" "${REAPED_OUT}" "the run ends early"

# THE assertion #3248 adds. Everything above this line is satisfied by a helper that kills the wrapper
# and walks away, which is what it did: the wrapper is gone, the shell says nothing, and the job the
# wrapper was started for runs on for its full five minutes with nobody's name on it.
#
# Waited for rather than sampled once, because a signalled process is not a reaped one and how long
# the gap is depends on what else this Mac is running. Sampling once is the defect on the other side
# of this same issue, which failed a merge on 2026-08-29 on a change that was green (L524).
REAPED_JOB_PIDS="$(cat "${STOP_DIR}/reaped.sh.job.pid" 2>/dev/null | tr '\n' ' ')"
assert_equals "the helper's own run really did get a job started (so the next line measures one)" \
  "started" \
  "$(if [[ -n "${REAPED_JOB_PIDS// /}" ]]; then echo "started"; else echo "none, so nothing below is proved"; fi)"
assert_pids_gone "and stopping through the helper ends the JOB, not only the wrapper it rode in on" \
  ${REAPED_JOB_PIDS}

# --- the window between creating the log and protecting it -------------------------------------------
#
# THE defect, seen on 2026-08-29: a `scripts/test-all.sh` run failed on
# `run-shell-fixtures.sh` with `test-all-phases.test.sh left files behind in its temp directory`
# and one `stopper-log.XXXXXX` in it. That runner is right to fail it: a fixture leaking one file
# per run leaks forever, outside the checkout, where nobody looks (#2585 is the same habit at Xcode
# scale, and it filled the disk).
#
# The stopper used to create its log, then do three more things, and only THEN arm the trap that
# removes it. Anything going wrong in that window leaks the file, and the window is wider than it
# looks because `set -u` is on and no errexit is: an unset variable there is a fatal exit with no
# cleanup armed.
#
# The evidence NARROWS it to that window rather than merely being consistent with it. The same trap
# removes a SECOND file, the status file `start_background_phase` makes for itself, and that one was
# NOT left behind. A trap that never ran would have left both; a trap that ran would have removed
# both. Only the log surviving means the script died after `mktemp` and before
# `start_background_phase` got as far as its own `mktemp`, which is exactly the unprotected span.
#
# Driven by INJECTING a death into that span rather than by waiting to see it again, because the real
# one appeared once in four full runs and is load dependent (this Mac was running two other test
# suites at the time). A guard that can only be exercised by luck is one nobody can prove (L1).
EARLY_DIR="${TMP_DIR}/dies-before-the-trap"
mkdir -p "${EARLY_DIR}"
write_stopper "${STOP_DIR}/dies-early.sh" 'true;' 'exit 9'
TMPDIR="${EARLY_DIR}" bash "${STOP_DIR}/dies-early.sh" > /dev/null 2>&1

assert_equals "a stopper that dies before its phase starts still removes the log it just created" \
  "0" "$(find "${EARLY_DIR}" -name 'stopper-log.*' | grep -c . || true)"

# The positive control for the line above. Without it, "no log was left" is satisfied just as well by
# a stopper that never created one, and the assertion would pass hardest while measuring nothing
# (L159), which is the rule this fixture already applies to its bare-kill control.
write_stopper "${STOP_DIR}/dies-early-keeping.sh" 'true;' 'trap - EXIT; exit 9'
TMPDIR="${EARLY_DIR}" bash "${STOP_DIR}/dies-early-keeping.sh" > /dev/null 2>&1

assert_equals "and the same stopper with its cleanup disarmed really does leave one (the control)" \
  "1" "$(find "${EARLY_DIR}" -name 'stopper-log.*' | grep -c . || true)"

find "${EARLY_DIR}" -name 'stopper-log.*' -delete

# An empty or already-gone pid is a no-op rather than an error, because the trap naming it runs on every
# path, including ones where the phase was never started.
STOP_STATUS_OUT="$(bash -c "source '${SCRIPT_DIR}/test-all-phases.sh'; stop_background_phase ''; echo \"status=\$?\"" 2>&1)"
assert_contains "an empty pid is a no-op" "${STOP_STATUS_OUT}" "status=0"

# Whatever the verdict, this fixture leaves no process of its own behind: on the path where the helper
# is missing the phase is still running, and a red fixture must not leak one.
#
# The claim in that sentence was false for as long as it stood, which is why #3248 says a claim a
# measurement disproves is worse than no claim. `*.pid` holds the WRAPPER pids, and every one of them
# is already dead by the time this runs: what survived was the wrapper's child, which this loop never
# named. Measured 2026-08-29 on this file as it stood: two `sleep 300` per run, forever, since macOS
# reaps nothing until the next boot. `*.job.pid` is the other half, and the wait is what makes the
# claim checkable rather than asserted (L524).
_LEFTOVER_PIDS=""
for _pidfile in "${STOP_DIR}"/*.pid; do
  [[ -f "${_pidfile}" ]] || continue
  _LEFTOVER_PIDS="${_LEFTOVER_PIDS} $(tr '\n' ' ' < "${_pidfile}")"
done
# shellcheck disable=SC2086
kill ${_LEFTOVER_PIDS} 2>/dev/null || true
# shellcheck disable=SC2086
assert_pids_gone "and this fixture really does leave no process of its own behind" ${_LEFTOVER_PIDS}

# The half that stops it coming back. test-all.sh is where the trap lives, and a later edit putting a
# bare kill back would be invisible to every behavioural test above, which drives the helper directly.
assert_contains "test-all.sh stops its Swift lane through the helper" "${TA_SRC}" 'stop_background_phase "${SWIFT_PID}"'
assert_not_contains "and never bare-kills it" "${TA_SRC}" 'kill "${SWIFT_PID}"'

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "test-all-phases.test.sh: all assertions passed"
  exit 0
else
  echo "test-all-phases.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
