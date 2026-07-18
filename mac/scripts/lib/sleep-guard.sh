#!/usr/bin/env bash
# #1009: keep the Mac awake for the life of a detached run.
#
# The detached runs (prep-run.sh, reply-classify-run.sh, scout-extract-run.sh) are long, headless
# claude runs the app launches and never supervises. Each can take many minutes across several
# prospects. Nothing held a power assertion, so an idle-sleep timeout (or a lid close) mid run
# suspended or killed the job with no loud failure: exactly the "a dead run looks identical to an
# in-progress one from the files on disk" hazard, made worse because a suspended run stops touching
# its heartbeat marker and only LOOKS dead after the marker goes stale.
#
# The fix is a scoped power assertion via caffeinate: NoIdleSleep (-i) plus system sleep (-s), held
# from the moment a run arms it and released the instant the run ends. Two independent release paths,
# because an assertion left held forever is its own defect and one path is not enough:
#   1. The run's EXIT trap calls stop_sleep_guard on the clean path (normal finish, cancel, `set -e`).
#   2. caffeinate is launched with `-w <run-pid>`, so it self-releases when the run process exits for
#      ANY reason, including a hard kill or a forced sleep-kill that runs no trap. The trap can never
#      cover that path; -w does.
#
# In ONE file sourced by all three runners, for the same reason models.sh / scout-cancel.sh /
# claude-run-scope.sh are: a guard that is right in two runners and missing from the third is the same
# bug wearing a disguise (#804 / #1097).

# start_sleep_guard <watch_pid>: arm the assertion for the life of <watch_pid> and print the guard's
# pid on stdout. The caller records that pid and hands it to stop_sleep_guard on exit. If caffeinate is
# unavailable, print nothing and return nonzero: a missing convenience tool must not abort a paid run,
# but the caller MUST be able to tell it is unprotected and say so loudly rather than believe a guard is
# held that never launched. SLEEP_GUARD_BIN overrides the binary (tests point it at a stub).
start_sleep_guard() {
  local watch_pid="$1"
  local bin="${SLEEP_GUARD_BIN:-/usr/bin/caffeinate}"
  if [ ! -x "${bin}" ]; then
    return 1
  fi
  # -i no idle sleep, -s no system sleep, -w exit when the watched run exits (crash-safe self-release).
  # stdout/stderr go to /dev/null: the guard has nothing to say, and, crucially, if it inherited the
  # stdout of a `X="$(start_sleep_guard ...)"` capture it would hold that pipe open and hang the caller
  # until the guard itself exited (never). Detaching its fds lets the capture return the pid immediately.
  "${bin}" -i -s -w "${watch_pid}" >/dev/null 2>&1 &
  printf '%s' "$!"
}

# arm_sleep_guard: the one call a runner makes. Arms the assertion for the life of THIS script ($$) and
# prints the guard pid on stdout (empty if unprotected). If caffeinate is missing it warns LOUDLY on
# stderr (which the runner has redirected into its run log) rather than letting the run believe it is
# protected: fail loud, not silent. Only the pid ever goes to stdout, so `X="$(arm_sleep_guard)"` never
# captures the warning. The caller records the pid and passes it to stop_sleep_guard in its EXIT trap.
arm_sleep_guard() {
  local guard_pid
  if guard_pid="$(start_sleep_guard "$$")" && [ -n "${guard_pid}" ]; then
    printf '%s' "${guard_pid}"
  else
    echo "sleep-guard: caffeinate unavailable, this run is NOT protected against idle sleep" >&2
    printf '%s' ""
  fi
}

# stop_sleep_guard <guard_pid>: release the assertion by stopping caffeinate. A quiet no-op on an empty
# pid (the run never armed a guard) or an already-dead one (the -w path already released it, or the trap
# fires twice). Never errors, so it is safe in an EXIT trap that also runs on the failure path.
stop_sleep_guard() {
  local guard_pid="${1:-}"
  [ -n "${guard_pid}" ] || return 0
  kill "${guard_pid}" 2>/dev/null || true
  return 0
}
