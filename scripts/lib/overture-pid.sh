#!/bin/sh
# shellcheck shell=sh
#
# Which Overture, resolved once for every tool here that has to point at the running app (#3424).
#
# WHY IT IS A LIBRARY. `scripts/freeze-measure.sh` and `scripts/sample-overture.sh` both have to answer
# the same question under the same rule, and two readings of one mechanism eventually disagree, with the
# quiet one holding a guard open (L263). The rule itself is the one the global CLAUDE.md was amended
# for: on 2026-08-04 a Cmd+W meant for a Debug build quit Dan's live Overture, because two copies were
# running, both were called `Overture`, and a lookup by name resolved to the wrong one.
#
# So it resolves by the FULL EXECUTABLE PATH, never by app name or bundle id, and it REFUSES when more
# than one candidate matches rather than picking one. A lookup that quietly picks is worse than no
# answer (L521), and the refusal names both pids so the person can see what it was choosing between.
#
# It prints the REASON rather than the whole refusal, so each caller keeps its own `UNMEASURED:` line
# and its own exit path: a library that exits on its caller's behalf takes away the caller's ability to
# say what it was measuring.
#
# POSIX sh, so `scripts/check-runner-posix.sh` stays satisfied wherever this is sourced.

OVERTURE_APP_EXEC_DEFAULT="/Applications/Overture.app/Contents/MacOS/Overture"

overture_app_exec() {
  printf '%s' "${OVERTURE_APP_EXEC:-${OVERTURE_APP_EXEC_DEFAULT}}"
}

# The single running Overture's pid on stdout, returning 0; or the reason it refused, returning 2.
# $1, when non-empty, is a command standing in for `pgrep` so a fixture never asks the real machine.
overture_resolve_pid() {
  _overture_pgrep="${1:-}"
  if [ -n "${_overture_pgrep}" ]; then
    _overture_pids="$("${_overture_pgrep}" 2>/dev/null || true)"
  else
    _overture_pids="$(pgrep -f "$(overture_app_exec)" 2>/dev/null || true)"
  fi
  _overture_pids="$(printf '%s\n' "${_overture_pids}" | grep -E '^[0-9]+$' || true)"
  _overture_count="$(printf '%s\n' "${_overture_pids}" | grep -cE '^[0-9]+$' || true)"

  if [ "${_overture_count}" -eq 0 ]; then
    printf '%s\n' "Overture is not running, so there is nothing to sample."
    printf '%s\n' "            Launch it and take the measurement again."
    return 2
  fi
  if [ "${_overture_count}" -gt 1 ]; then
    printf '%s\n' "two copies of Overture are running, pids $(printf '%s' "${_overture_pids}" | tr '\n' ' ')."
    printf '%s\n' "            Which one this would have measured is not something the pid alone can settle, so it"
    printf '%s\n' "            measures neither. Quit the build you are not measuring and run this again."
    return 2
  fi

  printf '%s' "${_overture_pids}"
  return 0
}
