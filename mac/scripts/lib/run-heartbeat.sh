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

  if [ -s "${claude_pid_file}" ]; then
    # Same shape as the cancel path's stop: read the pid the run recorded and end it. Unquoted on purpose,
    # matching the cancel path, so a file holding several pids stops all of them.
    # shellcheck disable=SC2046
    kill $(cat "${claude_pid_file}" 2>/dev/null) 2>/dev/null || true
  fi
  return 1
}
