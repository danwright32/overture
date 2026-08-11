#!/bin/sh
# shellcheck shell=sh
#
# #2506: a heartbeat proves its EMITTER is alive, never that the work is progressing.
#
# Measured on the live machine on 2026-08-11. A paid scout extract run of 27 sources across 4 parallel
# chunks finished its actual work at 10:47 and was still reporting "26 of 27, running" at 11:43, 56
# minutes later. One chunk's worker died having written nothing at all (its chunk log was zero bytes), so
# the `wait` on it could never return, and the run had no end. Everything downstream read as healthy:
#
#   the marker was re-touched every few seconds, so DetachedRunner.isRunning said live;
#   the 10 minute RunTimeouts.scoutExtract staleness window could never fire, because the marker was
#     never stale;
#   the results file was re-touched on the same cadence while its CONTENT never changed (identical
#     digests twenty five seconds apart);
#   the derived progress count sat frozen, because it can only ever count what arrived.
#
# Dan saw it was stuck from the screen and was talked out of it twice, on the strength of a fresh
# heartbeat. This is the mirror of #2109 (L71): that one closed the watchdog dying while the work ran on
# unobserved, and this closes the work dying while the watchdog keeps vouching for it. This is the worse
# half, because it actively reassures.
#
# So the heartbeat gets a second question to answer, kept separate from its own pulse: has this run
# produced anything new lately? The signature below is of the results file's CONTENT, so a file re-touched
# with the same bytes reads as exactly what it is, no progress. Once a run has stood still for longer than
# its limit, the guard's verdict is to STOP.
#
# Stopping is the fail-safe direction, and it is worth naming what stopping gets wrong (L93). A healthy
# but genuinely slow run killed by this guard loses the work in flight, not the work already landed: the
# partial results stay, every source that never reported comes home through the results guard as an
# honest `not_read`, the run's status goes non-zero, and Dan can start it again. Against that, a paid run
# that can never end, blocks the next one, and reports itself healthy indefinitely. The limits are sized
# well past any run ever observed (see each runner), and every stalled tick is logged before the stop, so
# the evidence for retuning is in the log rather than in a rerun.
#
# The runners are POSIX sh, not bash.

# stall_signature <results_file>
#
# Prints a stable signature of what the run has PRODUCED. Content, never mtime: the file in the incident
# was rewritten with identical bytes every minute, so anything derived from the timestamp would have gone
# on saying the run was working for as long as it hung.
#
# A file that is absent or unreadable has its own stable signature rather than an empty string, so two
# unreadable ticks in a row compare equal and count as standing still. A run that has produced nothing at
# all IS standing still, and on this defect's own shape that state lasted 56 minutes.
#
# cksum is POSIX and present everywhere these runners run. A CRC collision between two consecutive states
# of one file would cost a single missed tick, never a missed stop: the stored signature is the one that
# was compared, so the next differing write is caught as usual.
stall_signature() {
  if [ -r "$1" ]; then
    cksum < "$1" 2>/dev/null || echo "unreadable"
  else
    echo "absent"
  fi
}

# stall_stalled_seconds <state_file>
#
# How long the run has now stood still, in seconds. 0 for a run that has never ticked, or whose state file
# is missing or malformed: this is what the log line quotes, and it must never be the thing that fails a
# heartbeat.
stall_stalled_seconds() {
  _sg_seconds=0
  if [ -f "$1" ]; then
    read -r _sg_seconds < "$1" 2>/dev/null || _sg_seconds=0
  fi
  case "${_sg_seconds}" in
    ''|*[!0-9]*) _sg_seconds=0 ;;
  esac
  echo "${_sg_seconds}"
}

# stall_tick <results_file> <state_file> <increment_seconds> <limit_seconds>
#
# One heartbeat's worth of the progress question. Returns 0 when the run may carry on and 1 when it has
# stood still for at least <limit_seconds> and must be stopped.
#
# Call it once per marker tick, passing the marker interval as <increment_seconds>: the guard accumulates
# elapsed time from the ticks themselves rather than reading a clock, so it measures the same thing on a
# machine whose clock jumps and cannot inherit the sleep-versus-awake ambiguity that made a different
# outage detector cry wolf every morning (L82, #2220).
#
# An unset, empty or non-numeric limit means no ceiling was configured, and the fail-safe THERE is the
# other way round: a guard that stopped every run because its limit was mistyped would be worse than the
# defect it closes. The state is still recorded on that path, so the log still says how long the run has
# been standing still.
stall_tick() {
  _sg_results="$1"
  _sg_state="$2"
  _sg_increment="$3"
  _sg_limit="$4"

  _sg_now="$(stall_signature "${_sg_results}")"
  _sg_previous=""
  _sg_stalled=0
  if [ -f "${_sg_state}" ]; then
    { read -r _sg_stalled; read -r _sg_previous; } < "${_sg_state}" 2>/dev/null || true
  fi
  case "${_sg_stalled}" in
    ''|*[!0-9]*) _sg_stalled=0 ;;
  esac
  case "${_sg_increment}" in
    ''|*[!0-9]*) _sg_increment=0 ;;
  esac

  if [ "${_sg_now}" = "${_sg_previous}" ]; then
    _sg_stalled=$((_sg_stalled + _sg_increment))
  else
    _sg_stalled=0
  fi
  printf '%s\n%s\n' "${_sg_stalled}" "${_sg_now}" > "${_sg_state}" 2>/dev/null || true

  case "${_sg_limit}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "${_sg_limit}" -gt 0 ] || return 0

  [ "${_sg_stalled}" -lt "${_sg_limit}" ]
}
