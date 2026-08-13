#!/usr/bin/env bash

# The two-lane plumbing scripts/test-all.sh runs its phases with (#2603).
#
# WHY. test-all.sh ran strictly in sequence, and the Swift suite is the dominant cost by minutes. Its
# opening seconds are spent waiting on the shared xcodebuild flock and then building, during which
# nothing else on this Mac is doing anything, while the cheap checks (typecheck, vitest, ~50s of shell
# fixtures, a handful of read-only drift checks) sat waiting their turn. Starting the Swift suite FIRST
# and running the cheap checks beside it costs the same wall clock as the Swift suite alone.
#
# WHAT THIS FILE IS FOR. The interesting part is not the parallelism, it is the reporting. Two lanes
# means two verdicts, and two independent checks must never share one status field (L53): a green Swift
# run must not erase a red typecheck, and a red typecheck must not stop the Swift verdict being
# reported. So a cheap check records its failure and keeps going, both verdicts are named separately at
# the end, and the combined status is red if either lane is red. All of it lives here, in named
# functions, so test-all-phases.test.sh can drive the reporting decisions against fake phases in
# milliseconds instead of them being provable only by a real four minute suite run.

# The labels of the cheap checks that failed. Set by the caller before the first run_foreground_check.
TEST_ALL_CHEAP_FAILURES=()

# start_background_phase <log-path> <command...>
#
# Starts the command with its output going to log-path, and sets BACKGROUND_PHASE_PID to its pid and
# BACKGROUND_PHASE_STATUS_FILE to the file its exit status will be written to. Nothing is streamed yet;
# stream_and_wait replays the log from its first line, so no output is lost.
#
# The status goes to a FILE as well as being waitable, because `wait` only answers for a process that is
# a child of the shell asking, and the answer it gives otherwise is a status of its own (255 here) that
# is indistinguishable from the phase having failed. The whole combined verdict hangs off this number,
# so it must not depend on which shell is holding it.
start_background_phase() {
  local log="$1"
  shift
  : > "${log}"
  BACKGROUND_PHASE_STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/overture-phase-status.XXXXXX")"
  local status_file="${BACKGROUND_PHASE_STATUS_FILE}"
  { "$@" >"${log}" 2>&1; echo "$?" > "${status_file}"; } &
  BACKGROUND_PHASE_PID=$!
}

# run_foreground_check <label> <command...>
#
# Runs one cheap check and records its label in TEST_ALL_CHEAP_FAILURES if it fails, WITHOUT exiting.
# Always returns 0, so a caller running under `set -e` keeps going.
#
# Two reasons it does not exit. The obvious one: one failing check must not hide the checks behind it.
# The one that matters more here: the Swift suite has already started and holds the shared xcodebuild
# lock, so exiting on a cheap failure would abandon a run that is going to finish anyway and throw away
# the only verdict that costs minutes to produce.
#
# The failure is announced the moment it happens, as well as in the summary, because the whole point of
# the cheap lane is to fail fast: a person watching wants to know now, not in four minutes.
run_foreground_check() {
  local label="$1"
  shift
  echo "==> ${label}"
  if "$@"; then
    return 0
  fi
  TEST_ALL_CHEAP_FAILURES+=("${label}")
  echo "FAILED - ${label} (the Swift suite is still running; its own verdict follows below)"
  return 0
}

# stream_and_wait <log-path> <pid> [status-file]
#
# Prints the background phase's log from its FIRST line and keeps following it until that process
# exits, then returns the phase's exit status, read from the status file rather than from `wait`.
#
# A status file that is missing or empty means the phase was killed before it could record an outcome
# (a Ctrl-C, a crash, an OOM). That is reported as its own failure, in words, because "the phase did not
# say how it ended" and "the phase passed" must never be the same reading (L11, L98).
#
# Deliberately not `tail -f`: macOS tail has no --pid, so it would have to be killed after the wait,
# and killing it races with the lines it has not flushed yet. Losing the LAST lines of a suite log is
# the worst possible thing to lose, since that is where "** TEST SUCCEEDED **", the failing test names
# and the `Suite shape:` line live. Reading the file directly and draining it once more after the
# process is gone cannot lose anything: once the writer has exited, the file is complete.
stream_and_wait() {
  local log="$1" pid="$2" status_file="${3:-${BACKGROUND_PHASE_STATUS_FILE:-}}" line status=0

  exec 8<"${log}"
  while :; do
    while IFS= read -r line; do printf '%s\n' "${line}"; done <&8
    # read returns nonzero at EOF, which is also how it returns a final line with no trailing newline;
    # that partial line is in ${line} and would otherwise be dropped.
    [[ -n "${line}" ]] && printf '%s' "${line}"
    line=""
    if ! kill -0 "${pid}" 2>/dev/null; then
      # The writer is gone, so whatever is left in the file is all there will ever be.
      while IFS= read -r line; do printf '%s\n' "${line}"; done <&8
      [[ -n "${line}" ]] && printf '%s' "${line}"
      break
    fi
    sleep 0.5
  done
  exec 8<&-

  # Reaped where possible, so a finished phase is not left as a zombie, but its ANSWER comes from the
  # file. `|| true` because a shell that is not this process's parent cannot wait for it, and that
  # refusal says nothing about how the phase itself ended.
  wait "${pid}" >/dev/null 2>&1 || true

  if [[ -z "${status_file}" || ! -s "${status_file}" ]]; then
    echo "The background phase never recorded how it ended, so it cannot be called a pass."
    echo "  Killed part way through (a Ctrl-C, a crash) is the usual cause."
    return 1
  fi
  status="$(cat "${status_file}")"
  rm -f "${status_file}"
  return "${status}"
}

# report_phase_results <background-label> <background-status>
#
# Names what failed in each lane and returns 1 if either lane failed, 0 only if both passed.
#
# Every branch says something about BOTH lanes. A summary that named only the cheap failures would
# leave "the Swift suite passed" and "the Swift suite was never reached" looking identical, which is
# the same defect as sharing one status field (L53) one step further along.
report_phase_results() {
  local background_label="$1" background_status="$2"
  local cheap_count="${#TEST_ALL_CHEAP_FAILURES[@]}"

  if [[ "${cheap_count}" -eq 0 && "${background_status}" -eq 0 ]]; then
    echo "==> all suites passed"
    return 0
  fi

  echo
  echo "==> NOT all suites passed"
  if [[ "${cheap_count}" -eq 0 ]]; then
    echo "  every cheap check passed"
  else
    echo "  ${cheap_count} cheap check(s) failed:"
    printf '    %s\n' "${TEST_ALL_CHEAP_FAILURES[@]}"
  fi
  if [[ "${background_status}" -eq 0 ]]; then
    echo "  ${background_label} passed"
  else
    echo "  ${background_label} failed (exit ${background_status})"
  fi
  return 1
}
