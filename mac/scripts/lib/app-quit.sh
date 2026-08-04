#!/usr/bin/env bash

# #2072: quitting a running app before replacing or relaunching its bundle, without ever hanging.
#
# build-install.sh used to ask the running app politely via `osascript ... to quit`, which blocks
# waiting on an Apple event reply. The running app never answered (and the call can also sit on an
# automation consent prompt that never appears in a script), so the installer stalled indefinitely
# with the fix built and nowhere to go until Dan quit the app by hand. The `|| true` after it only
# covered an error return, not a call that never returns.
#
# This is the shared replacement, generalising the pattern run-debug.sh proved for its Debug
# instances: kill by PID, bounded wait, escalate to KILL, bounded wait again, then VERIFY the
# process is actually gone. Every wait is bounded and every outcome is a real exit code, so a
# caller can refuse to `rm -rf` a bundle that still has a live process inside it (fail loud,
# never hang, per the progress principle: working, still alive, and failed are distinct states).
#
# The seams (app_quit_ps, app_quit_kill, app_quit_tick) exist so app-quit.test.sh can drive the
# logic against a scripted process table with no real process touched and no real sleep.

app_quit_ps() { ps -eo pid=,command=; }
app_quit_kill() { kill "-$1" "$2" 2>/dev/null || true; }
app_quit_tick() { sleep 0.5; }

# Given `ps -eo pid=,command=` output (one process per line: PID then its full command) and a
# .app bundle path, prints the PIDs of processes whose executable lives inside that bundle.
# Anchored on "<bundle>/Contents/MacOS/" as a fixed string, so a Debug copy of the same app at
# another path, an unrelated app, or a command line merely mentioning the bundle never matches.
pids_inside_bundle() {
  local ps_output="$1" bundle="$2"
  # `|| true`: a grep that matches nothing exits 1, and callers run under `set -euo pipefail`,
  # where pipefail would turn the NORMAL case (no instance running) into an aborted script.
  echo "${ps_output}" | grep -F "${bundle}/Contents/MacOS/" | awk '{print $1}' || true
}

# The driver. Takes the NAME of a lister function (called with `ps -eo pid=,command=` output,
# prints matching PIDs, one per line) and a human label for the messages, so run-debug.sh can
# reuse the same loop with its own Debug-instance matcher. TERM first, then up to ~5 seconds of
# waiting; KILL for whatever remains, then up to ~5 seconds more. Returns 0 once nothing matches,
# 1 (naming the survivors on stderr) if something outlived even KILL.
quit_matched_instances() {
  local lister="$1" label="$2"
  local max_ticks=10
  local pids pid waited

  pids="$("${lister}" "$(app_quit_ps)")"
  [[ -z "${pids}" ]] && return 0

  echo "    Quitting running ${label}: ${pids//$'\n'/ }"
  for pid in ${pids}; do app_quit_kill TERM "${pid}"; done
  waited=0
  while [[ -n "$("${lister}" "$(app_quit_ps)")" && "${waited}" -lt "${max_ticks}" ]]; do
    app_quit_tick
    waited=$((waited + 1))
  done

  pids="$("${lister}" "$(app_quit_ps)")"
  if [[ -n "${pids}" ]]; then
    echo "    Not gone after a polite quit; escalating to kill -9: ${pids//$'\n'/ }"
    for pid in ${pids}; do app_quit_kill KILL "${pid}"; done
    waited=0
    while [[ -n "$("${lister}" "$(app_quit_ps)")" && "${waited}" -lt "${max_ticks}" ]]; do
      app_quit_tick
      waited=$((waited + 1))
    done
  fi

  pids="$("${lister}" "$(app_quit_ps)")"
  if [[ -n "${pids}" ]]; then
    echo "ERROR: ${label} still running after kill -9: ${pids//$'\n'/ }" >&2
    return 1
  fi
  return 0
}

# Quits every process running from inside the given bundle, via the driver above. This is what
# build-install.sh calls on /Applications/Overture.app before rm -rf of the bundle.
_app_quit_bundle_lister() { pids_inside_bundle "$1" "${_app_quit_bundle_path}"; }
quit_bundle_instances() {
  _app_quit_bundle_path="$1"
  quit_matched_instances _app_quit_bundle_lister "instance(s) of $1"
}
