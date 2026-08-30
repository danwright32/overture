#!/usr/bin/env bash
# What a finished fixture LEFT RUNNING, and ending it (#3254).
#
# `scripts/run-shell-fixtures.sh` has failed a fixture for leaving a FILE behind since #2850 and never
# looked at what is still running. A leaked process is the worse of the two: it holds the run's stdout
# open, so anything capturing that output waits for it (L235), it can hold the shared xcodebuild lock,
# and macOS reaps nothing until the next boot. #3248 found one fixture that had been leaking two
# `sleep 300` per run for as long as it had existed, plus three helpers that orphaned a child per stop,
# and none of it was visible to the runner that gates every push.
#
# ATTRIBUTION is the hard half, not detection. Eight fixtures run at once, so a stray process seen in the
# process table belongs to nobody in particular. Each fixture already runs as a background job under
# `set -m`, which gives it a process GROUP of its own, and the group is what makes the question
# answerable: everything the fixture started inherits it, and nothing else has it.
#
# Sourced by BOTH the runner and the per-fixture wrapper it writes, rather than inlined in each, because
# two same-named readings of one thing on either side of a boundary are never compared and drift
# indefinitely while both call sites read as correct (L263).

# The surviving members of one process group, one per line, or the single word UNMEASURED.
#
# UNMEASURED is a THIRD outcome and not a tidy way of saying none (L98, L11): a group that could not be
# read and a group with nothing left in it leave the same empty answer, and only one of them is a pass.
fixture_surviving_processes() {
  local pgid="${1:-}"
  if [[ -z "${pgid}" || ! "${pgid}" =~ ^[0-9]+$ ]]; then
    echo "UNMEASURED"
    return 0
  fi
  ps -o pid=,command= -g "${pgid}" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -v '^$' || true
}

# Ends a process group, and REFUSES to end its own caller's.
#
# This is the guard that matters here, because the failure it prevents is not a missed leak but a runner
# that kills itself: if `set -m` did not take, the background job shares the caller's group, and
# `kill -- -<pgid>` would then take down the wrapper, the fixture runner and everything else in it. A
# guard whose two sides come from one lookup can only prove that lookup is self-consistent (L70), so the
# caller's own group is read here, independently, rather than passed in.
fixture_end_process_group() {
  local pgid="${1:-}"
  [[ "${pgid}" =~ ^[0-9]+$ ]] || return 0
  local own
  own="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  if [[ -n "${own}" && "${own}" == "${pgid}" ]]; then
    echo "REFUSED to end process group ${pgid}: it is this process's own group." >&2
    return 1
  fi
  kill -TERM -- "-${pgid}" 2>/dev/null || true
  # A second, harder signal only for what ignored the first. Bounded by a fixed number of checks rather
  # than by a deadline, because this runs per fixture and must not become the thing that makes the sweep
  # slow.
  local attempt=0
  while [[ "${attempt}" -lt 20 ]]; do
    ps -o pid= -g "${pgid}" 2>/dev/null | grep -q . || return 0
    sleep 0.05
    attempt=$(( attempt + 1 ))
  done
  kill -KILL -- "-${pgid}" 2>/dev/null || true
  return 0
}

# Runs a command in a process group of its OWN, waits for it, ends whatever it left behind, and prints
# what it printed. The return value is the command's own status.
#
# For a fixture that DELIBERATELY creates a stray, which several do: `run-heartbeat.test.sh` and
# `sleep-guard.test.sh` both demonstrate that a bare `kill` on a subshell leaves the `sleep` inside it
# running, and demonstrating that means creating one. The fixture is right to create it and wrong to walk
# away from it, and this is the difference: the stray is ended by whoever made it rather than by the
# runner noticing afterwards.
#
# Output is captured through a FILE rather than a pipe, because `cmd | while read` would put the job in
# the pipeline's group instead of its own and the whole point here is the group.
fixture_run_in_own_group() {
  local capture status=0
  capture="$(mktemp "${TMPDIR:-/tmp}/fixture-group-XXXXXX")"
  set -m
  ( "$@" ) > "${capture}" 2>&1 &
  local job=$!
  wait "${job}" || status=$?
  set +m
  fixture_end_process_group "${job}"
  cat "${capture}"
  rm -f "${capture}"
  return "${status}"
}
