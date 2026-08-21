#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #2106: a run that can no longer report it is alive must STOP, not go on working unobserved.
#
# All three runners heartbeat by touching a marker file every 60s from a forked subshell. That touch used
# to be spelled `touch "$MARKER" 2>/dev/null || exit`, and the `exit` ends the SUBSHELL only: the main
# script goes on waiting for claude, which goes on working. From that moment nothing touches the marker,
# so the app judges the run dead, #1613's sweep settles the check with whatever partial results exist and
# marks those shows researched, and the real run keeps spending tokens invisibly and unstoppably, because
# the cancel sentinel is only ever read by the heartbeat that just died.
#
# The fail-safe direction is to stop: an invisible unstoppable paid run is worse than a stopped one. The
# heartbeat already knows how (it stops claude on the cancel path via the pid file), so it takes the same
# exit on this path too. That also restores the invariant the app's sweep depends on, that a stale marker
# really does mean nothing is running.

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

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/run-heartbeat.sh"

TMP="$(mktemp -d)"
# Guarded on the shell's own pid: bash hands the EXIT trap down to command-substitution subshells, so an
# unguarded `rm -rf` here fires the first time the test runs `$(cat ...)` and deletes the fixtures out
# from under the rest of the run. That is not hypothetical, it happened while writing this.
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${TMP}"' EXIT

# A stand-in for the claude process the runner launched: a real, killable process whose liveness the test
# can check. Real rather than a recorded number, so "did it actually stop it" is measured and not asserted.
# Job-control notices ("Terminated: 15") are noise here: killing the stand-in IS the expected result.
set +m

start_fake_claude() {
  sleep 300 &
  echo $! > "$1"
}

# Reads the pid WITHOUT a command substitution. `$(cat ...)` forks a subshell, and bash hands the EXIT
# trap down to it, so every such read fired the cleanup and deleted the fixtures mid-run. `read` is a
# builtin and forks nothing.
is_alive() {
  [ -s "$1" ] || return 1
  local pid; read -r pid < "$1"
  kill -0 "${pid}" 2>/dev/null
}
stop_fake_claude() {
  [ -s "$1" ] || return 0
  local pid; read -r pid < "$1"
  kill "${pid}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The healthy tick: the marker is touchable, so the run carries on and nothing is killed.
# ---------------------------------------------------------------------------
MARKER="${TMP}/prep-running"
PIDFILE="${TMP}/prep-claude-pid"
: > "${MARKER}"
start_fake_claude "${PIDFILE}"

assert "a touchable marker reports success" heartbeat_touch_or_stop "${MARKER}" "${PIDFILE}"
assert "a healthy tick leaves the run running" is_alive "${PIDFILE}"
stop_fake_claude "${PIDFILE}"

# ---------------------------------------------------------------------------
# The defect: the marker cannot be touched. The run can no longer be seen, so it must not carry on.
# The marker's own directory is made unwritable and the marker removed, which is the closest reproduction
# of the real failure (the handoff directory going away or losing permissions under a live run).
# ---------------------------------------------------------------------------
DEADDIR="${TMP}/gone"
mkdir -p "${DEADDIR}"
DEADMARKER="${DEADDIR}/prep-running"
chmod 500 "${DEADDIR}"          # readable and traversable, not writable: touch of a NEW file fails
start_fake_claude "${PIDFILE}"

refute "an untouchable marker reports failure" heartbeat_touch_or_stop "${DEADMARKER}" "${PIDFILE}"
sleep 0.3
refute "a run that can no longer report itself alive is stopped, not left running" is_alive "${PIDFILE}"
chmod 700 "${DEADDIR}"

# ---------------------------------------------------------------------------
# Degenerate inputs must not make it worse. With no pid on record there is nothing to stop, and the
# failure is still reported so the caller still exits: a heartbeat that reported success here would leave
# the app believing a dead run is alive.
# ---------------------------------------------------------------------------
EMPTY="${TMP}/no-pid"
: > "${EMPTY}"
chmod 500 "${DEADDIR}"
refute "an untouchable marker with no pid on record still reports failure" \
  heartbeat_touch_or_stop "${DEADMARKER}" "${EMPTY}"
chmod 700 "${DEADDIR}"

# A pid file naming a process that is already gone is not an error either: the run has already ended.
# The fixtures must still be here. Without this the section below could fail to write its file, every
# later `refute` would "pass" because the command errored rather than because the code was right, and the
# whole tail of this fixture would be vacuous.
assert "the temp fixtures survived to this point" test -d "${TMP}"
STALE="${TMP}/stale-pid"
sleep 300 & STALE_PID=$!
kill "${STALE_PID}" 2>/dev/null; wait "${STALE_PID}" 2>/dev/null
echo "${STALE_PID}" > "${STALE}"
chmod 500 "${DEADDIR}"
refute "an already-finished run still reports the failure rather than erroring" \
  heartbeat_touch_or_stop "${DEADMARKER}" "${STALE}"
chmod 700 "${DEADDIR}"

# ---------------------------------------------------------------------------
# Every runner must call this, and must hand it a pid-file variable IT ACTUALLY DEFINES.
#
# This exists because the obvious patch is wrong. The three runners do NOT agree on the name: prep and
# reply-classify record one claude in CLAUDE_PID_FILE, while scout-extract runs several chunks and records
# all their pids in CHUNK_PIDS_FILE. Passing the wrong name is silent, since an unset variable expands to
# an empty string, `[ -s "" ]` is false, and the heartbeat then reports failure without stopping anything,
# which is the exact defect this file exists to fix, reintroduced while fixing it. That happened here.
# ---------------------------------------------------------------------------
# Does <region> call <name> on a line with nothing guarding its exit status? The region is passed as an
# ARGUMENT, not read from an outer variable, because a subshell that cannot see the variable finds nothing
# and the check then passes for the wrong reason forever (caught by mutation while writing this).
calls_unguarded() {
  grep -qE "$2 [^|]*$" <<< "$1"
}

RUNNERS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
for runner in prep-run.sh scout-extract-run.sh reply-classify-run.sh; do
  path="${RUNNERS_DIR}/${runner}"
  assert "${runner} sources the shared heartbeat" grep -q 'lib/run-heartbeat.sh' "${path}"
  assert "${runner} heartbeats through heartbeat_touch_or_stop" \
    grep -q 'heartbeat_touch_or_stop "\$MARKER"' "${path}"
  refute "${runner} keeps no bare touch-or-exit of its own" \
    grep -q 'touch "\$MARKER" 2>/dev/null || exit' "${path}"

  pid_var="$(grep -o 'heartbeat_touch_or_stop "\$MARKER" "\$[A-Z_]*"' "${path}" \
             | grep -o '\$[A-Z_]*"$' | tr -d '$"')"
  assert "${runner} names a pid-file variable at all" test -n "${pid_var}"
  assert "${runner} passes \$${pid_var}, which it defines" grep -q "^${pid_var}=" "${path}"

  # #2109: and the same variable is what the EXIT guard is armed with. Armed with the WRONG name it is
  # silent in exactly the way described above: an unset variable expands to empty, `[ -s "" ]` is false,
  # and the guard stops nothing while looking installed.
  assert "${runner} arms the heartbeat EXIT guard" \
    grep -q "heartbeat_guard_exit \"\$${pid_var}\"" "${path}"

  # And the per-tick bookkeeping cannot kill the run. Under `set -eu` any non-zero return in the loop body
  # ends the subshell, and a progress-count hiccup ending a paid run is the wrong trade in itself.
  #
  # Scoped to the heartbeat's OWN region, from the guard it arms to the loop's terminator. The same two
  # helpers are also called once in the main script body, where a failure genuinely matters and must NOT
  # be swallowed, so a whole-file check would demand exactly the wrong thing there (L63: check the region
  # the rule is about, not a proxy for it).
  loop_body="$(awk '/heartbeat_guard_exit/{f=1} f; /done \) &/{f=0}' "${path}")"
  assert "${runner}: the heartbeat's own region was found" test -n "${loop_body}"
  for bookkeeping in merge_chunk_results update_progress_from_results; do
    if grep -q "${bookkeeping} " <<< "${loop_body}"; then
      refute "${runner}: a failing ${bookkeeping} cannot end the heartbeat" \
        calls_unguarded "${loop_body}" "${bookkeeping}"
    fi
  done
done

# --- #2981: stopping the heartbeat must not put the runner's own source into the log -----------------
#
# A killed background job makes the shell print a termination notice at the next command boundary, and
# that notice renders the job's WHOLE command text. For these runners the job is the heartbeat subshell,
# so every ordinary run ended by writing the heartbeat's body into its log, `echo "prep: STOPPING. ..."`
# included. The log is then a record of what happened plus the program that could have happened.
#
# It cost a real measurement: `scripts/measure-concurrent-runs.sh` grepped for `STOPPING`, matched the
# echo statement in both logs, and reported two healthy runs as stalled, into the measurement whose whole
# purpose is deciding whether to change the stall limit (2026-08-18).
#
# Driven as real processes rather than asserted on the source, because the notice comes from the SHELL
# and no reading of the script can tell you whether it appears.
#
# The job is a BOUNDED `sleep`, not a `while :` loop, and that is not cosmetic. `kill` signals the
# subshell and not the `sleep` it is currently blocked in, so a LOOPING job leaves a fresh orphan behind
# on every iteration. Measured 2026-08-21 on the first real merge of #2981: under the parallel fixture
# runner this fixture stopped reporting for over two minutes and tripped the runner's own stall guard,
# with orphaned sleeps still alive minutes later. One bounded sleep leaves at most one orphan, which exits
# by itself in five seconds and holds no descriptor the runner waits on. The job's body still CONTAINS the
# marker text, which is all the notice needs in order to render it: the echo never has to run.
HB_WORK="$(mktemp -d)"

cat > "${HB_WORK}/with-stop.sh" <<'STOPSH'
#!/bin/sh
set -eu
. "$(dirname "$0")/run-heartbeat.sh"
( sleep 5; echo "the marker text a grep would look for" ) >/dev/null 2>&1 &
HB=$!
sleep 0.2
heartbeat_stop "$HB"
sleep 0.5
echo "finished"
STOPSH

cat > "${HB_WORK}/bare-kill.sh" <<'KILLSH'
#!/bin/sh
set -eu
( sleep 5; echo "the marker text a grep would look for" ) >/dev/null 2>&1 &
HB=$!
sleep 0.2
kill "$HB" 2>/dev/null || true
sleep 0.5
echo "finished"
KILLSH

cp "${SCRIPT_DIR}/run-heartbeat.sh" "${HB_WORK}/run-heartbeat.sh"
chmod +x "${HB_WORK}/with-stop.sh" "${HB_WORK}/bare-kill.sh"

STOP_OUT="$("${HB_WORK}/with-stop.sh" 2>&1)"
assert_contains "a stopped heartbeat lets the script finish" "${STOP_OUT}" "finished"
assert_not_contains "and prints no termination notice" "${STOP_OUT}" "Terminated"
assert_not_contains "and does not echo the subshell's body into the log" "${STOP_OUT}" "the marker text a grep would look for"

# The positive control. Without this the assertions above would pass on any shell that never prints the
# notice at all, and would be proving nothing about the fix (L159).
BARE_OUT="$("${HB_WORK}/bare-kill.sh" 2>&1)"
assert_contains "a bare kill really does announce it on this shell" "${BARE_OUT}" "Terminated"
assert_contains "and really does render the job's body" "${BARE_OUT}" "the marker text a grep would look for"

# And every runner uses it, rather than one of the three keeping a bare kill. Derived from the runners
# themselves, not a list here, so a fourth runner is covered without anybody remembering (L96).
for runner in "${SCRIPT_DIR}/../"*-run.sh; do
  [ -f "${runner}" ] || continue
  name="$(basename "${runner}")"
  grep -q 'HEARTBEAT_PID' "${runner}" || continue
  assert_not_contains "${name} does not bare-kill its heartbeat" "$(cat "${runner}")" 'kill "$HEARTBEAT_PID"'
  assert_contains "${name} stops it through the shared helper" "$(cat "${runner}")" 'heartbeat_stop "$HEARTBEAT_PID"'
done

rm -rf "${HB_WORK}"

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all run-heartbeat checks passed"
