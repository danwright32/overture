#!/usr/bin/env bash
# #1037: cooperative cancel for the detached scout-extract read. The read has no trackable PID
# (DetachedRunner backgrounds it via `sh -c '... &'` and keeps no handle), so a hard kill is off the
# table. Instead Overture writes a cancel-request file into the handoff dir, and the runner checks for
# it on each heartbeat tick and stops cleanly if it is there. Safe by construction: a cooperative stop
# between ticks can never interrupt a source mid-write and corrupt the shared results file, the way a
# kill -9 could.
#
# The sentinel's presence IS the request; its contents are never read. See docs/contracts.md and
# docs/scout-extract-runbook.md for the cross-language contract.

# cancel_requested <cancel_file>: true (0) when Overture has asked this run to stop.
cancel_requested() {
  [ -f "$1" ]
}

# clear_cancel <cancel_file>: remove the sentinel. Called by the runner on exit (so a stopped run does
# not leave a sentinel that would kill the next run) and, in the app, before a fresh run starts. A quiet
# no-op when the file is absent, never an error that could fail a run.
clear_cancel() {
  rm -f "$1" 2>/dev/null || true
}

# #1053: marker_due <elapsed_seconds> <interval_seconds>: true (0) once at least <interval> seconds have
# accrued since the heartbeat last did its periodic work. The heartbeat polls the cancel sentinel on a
# short interval (a few seconds), so a Cancel Dan clicks stops the read within seconds instead of up to a
# minute; this gates the expensive periodic work (touching the marker, merging chunk results, deriving
# the progress count) so it still runs only once per interval. Keeping the two cadences separate is the
# whole point: the sentinel is read every poll, the 60s work is not dragged along with it.
marker_due() {
  [ "$1" -ge "$2" ]
}
