#!/bin/sh
# shellcheck shell=sh
#
# #2106: the heartbeat's touch, and what it does when it cannot touch.
#
# All three detached runners (prep, scout extract, reply classify) heartbeat the same way: a forked
# subshell touches a marker file every 60s so the app can tell a live run from a dead one. That touch used
# to be written inline as `touch "$MARKER" 2>/dev/null || exit`, and the `exit` ends the SUBSHELL only.
# The main script goes on waiting for claude, which goes on working, and from that moment:
#
#   nothing touches the marker, so the app judges the run dead;
#   #1613's sweep settles the check with whatever partial results exist and marks those shows researched;
#   the real run is still going, still spending tokens, invisible to the app and no longer stoppable,
#   because the cancel sentinel Overture writes is only ever read by the heartbeat that just died.
#
# A half-finished result is filed as the answer while the run that would have produced the real one is
# still running. So a run that can no longer report that it is alive STOPS. That is the fail-safe
# direction (an invisible unstoppable paid run is worse than a stopped one), it costs nothing on a healthy
# run, and it restores the invariant the app's sweep depends on: a stale marker really does mean nothing
# is running.
#
# The runners are POSIX sh, not bash.

# heartbeat_stop_recorded_run <claude_pid_file>
#
# Ends whatever process the run recorded. Always succeeds, including with no pid recorded or a process
# already gone, so it is safe on every path including the ones where the stop has already happened.
heartbeat_stop_recorded_run() {
  if [ -s "$1" ]; then
    # Unquoted on purpose, matching the cancel path, so a file holding several pids stops all of them.
    # shellcheck disable=SC2046
    kill $(cat "$1" 2>/dev/null) 2>/dev/null || true
  fi
  return 0
}

# heartbeat_guard_exit <claude_pid_file>
#
# #2109: installs the fail-safe. Call it as the FIRST thing inside the heartbeat subshell.
#
# #2106 closed one route into an invisible unstoppable run: a heartbeat that cannot touch its marker now
# stops the run rather than leaving it working invisibly. There is a second, likelier route it does not
# cover. All three runners run under `set -eu`, and that applies inside the heartbeat subshell, so ANY
# command in the loop body returning non-zero ends the subshell without stopping claude. That is exactly
# the #2106 failure again: nothing touches the marker, the app judges the run dead, #1613's sweep files
# the partial results as the answer and marks those shows researched, and the real run carries on
# spending tokens, invisible and no longer stoppable, because the cancel sentinel Overture writes is only
# ever read by the heartbeat that just died.
#
# An EXIT trap covers `set -e` termination and every unforeseen way the loop can end, together. It is
# deliberately unconditional: every deliberate exit from these loops has ALREADY stopped the run, so
# stopping again is a no-op, and by the time the main script tears the heartbeat down its own trap has
# stopped claude too. Making it conditional would mean a flag somebody has to remember to set on a path
# added later, which is the shape of the defect this is closing (L71: a watchdog must not share the
# abort-on-error behaviour of the work it watches).
# #2981: stop the heartbeat subshell WITHOUT the shell announcing it, which is what put the runner's own
# source into every run log.
#
# A killed background job makes the shell print a termination notice at the next command boundary, and
# that notice renders the job's whole command text. For these runners the job is the heartbeat subshell,
# so every ordinary run ended by writing sixty-odd lines of the heartbeat's body into its log, including
# the `echo "prep: STOPPING. ..."` statement. The log is then a record of what happened PLUS the program
# that could have happened, and nothing about reading it warns you of that.
#
# It cost a real measurement. `scripts/measure-concurrent-runs.sh` grepped for `STOPPING` and matched the
# echo statement in both logs, reporting two healthy runs as stalled, into the measurement whose whole
# purpose is deciding whether to change the stall limit (#2981, observed 2026-08-18).
#
# `wait` reaps the job before the shell gets to report it, and that is the whole fix. Measured on this Mac
# 2026-08-21: with a bare `kill` the notice and the body appear; with the `wait` after it, neither does.
# Both are `|| true` because this runs inside an EXIT trap, where a non-zero status is not somebody's
# problem to hear about and `set -e` would turn one into a different exit code than the run really had.
# #3292: ends the JOB, not only the subshell that wraps it.
#
# This was `kill "$1"`, which signals the heartbeat subshell and leaves the `sleep` inside it running as
# an orphan. macOS reaps nothing until the next boot, so every detached run left one behind on every
# stop. Found by #3254's leaked-process check rather than by looking: it named a fixture leaving two
# `sleep 15` per sweep, and that fixture only runs `prep-run.sh`, so the stray was this code's.
#
# It is the same class #3248 fixed for three other helpers, using `set -m` at the start and a group kill
# at the stop. This one was missed because that sweep searched one directory for the shape rather than
# every place the shape occurs (L30, L247).
#
# WHY THE GROUP KILL IS CONDITIONAL, which is the part to understand before changing it. This function
# is also called on pids that were NOT started under job control, and `prep-run.sh` calls it on a
# watchdog pid as well as on the heartbeat. A pid that is not its own group leader belongs to the
# CALLER's group, so `kill -- -$pid` there would take down the runner, its claude, and everything else
# in that group. So the group kill happens only where the pid IS the group id, which is exactly what
# `set -m` makes it and what nothing else does, and the caller's own group is read independently rather
# than assumed to differ (L70, L321).
#
# A pid that has already exited reads no group at all and falls through to the plain kill, which is the
# no-op it has always been on that path.
heartbeat_stop() {
  [ -n "${1:-}" ] || return 0
  hb_pgid="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')"
  hb_own="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  if [ -n "$hb_pgid" ] && [ "$hb_pgid" = "$1" ] && [ "$hb_pgid" != "$hb_own" ]; then
    kill -- "-$hb_pgid" 2>/dev/null || true
  else
    kill "$1" 2>/dev/null || true
  fi
  wait "$1" 2>/dev/null || true
}

# heartbeat_stop_all <space-separated pids>
#
# #3099: heartbeat_stop over a LIST, for the OTHER jobs the EXIT traps end.
#
# #2981 reaped the heartbeat and left the chunk and claude kills in those same traps alone, on the
# reasoning that they had not been observed to leave a notice. That reasoning was wrong and was never
# checked: measured 2026-08-21 over the real logs in ~/Library/Application Support/Overture, 67
# termination notices, 56 of them the heartbeat and the rest other jobs, including
# `run_claude_on_chunk "$CHUNKD...` rendered into scout-extract-run.log. Same consequence as #2981: the
# log then holds the program as well as the events, so a grep for a phrase can match code that never ran.
#
# It also closes a second defect on the same line, found while fixing the first. prep's trap read
# `kill "$CLAUDE_PID"`, quoted, while the parallel path sets CLAUDE_PID to the space-separated list of
# every chunk pid, commented "so the EXIT trap kills every chunk, not just one". A quoted list is ONE
# argument: `kill "111 222"` exits 1 with "arguments must be process or job IDs" and kills nothing at all,
# so a crash or an app quit orphaned every chunk the run had launched. The word-splitting here is
# therefore load-bearing rather than incidental, and is what the caller gets by using this helper.
#
# Both `kill` and `wait` are `|| true` for heartbeat_stop's reason: this runs inside an EXIT trap, where a
# non-zero status is not somebody's problem to hear about and `set -e` would turn one into a different
# exit code than the run really had. An empty or blank list is a no-op returning 0, because the traps name
# a variable that is legitimately empty for a run that never launched a chunk and for one already reaped.
heartbeat_stop_all() {
  # Unquoted on purpose: the argument is a LIST and must word-split. See the note above.
  # shellcheck disable=SC2086
  set -- ${1:-}
  [ "$#" -gt 0 ] || return 0
  for _hb_pid in "$@"; do
    kill "$_hb_pid" 2>/dev/null || true
  done
  # Reaped in a second pass, after every one has been signalled, so a slow first process cannot delay the
  # signal reaching the rest. `wait` is what stops the shell announcing the job, which is the whole point.
  for _hb_pid in "$@"; do
    wait "$_hb_pid" 2>/dev/null || true
  done
  return 0
}

heartbeat_guard_exit() {
  trap "heartbeat_stop_recorded_run '$1'" EXIT
}

# heartbeat_touch_or_stop <marker> <claude_pid_file>
#
# Touches the marker. Returns 0 when the run may carry on. When the marker cannot be touched, stops the
# recorded claude process (the same stop the cancel path performs, and for the same reason) and returns 1,
# so the caller exits its heartbeat loop.
#
# Returning 1 is unconditional on that path, even with no pid recorded or a process already gone: the
# caller must still exit, because a heartbeat that reported success while unable to touch the marker would
# leave the app believing a dead run is alive, which is the whole defect one level down.
heartbeat_touch_or_stop() {
  marker="$1"
  claude_pid_file="$2"

  if touch "${marker}" 2>/dev/null; then
    return 0
  fi

  # Same shape as the cancel path's stop: read the pid the run recorded and end it.
  heartbeat_stop_recorded_run "${claude_pid_file}"
  return 1
}
