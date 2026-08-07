#!/usr/bin/env bash
set -uo pipefail

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
  printf '%s' "$1" | grep -qE "$2 [^|]*$"
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
    if printf '%s' "${loop_body}" | grep -q "${bookkeeping} "; then
      refute "${runner}: a failing ${bookkeeping} cannot end the heartbeat" \
        calls_unguarded "${loop_body}" "${bookkeeping}"
    fi
  done
done

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all run-heartbeat checks passed"
