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
