#!/usr/bin/env bash
set -uo pipefail

# #2072: build-install.sh stalled indefinitely when Overture was running: its polite
# `osascript ... to quit` blocks waiting on an Apple event reply that never comes, and the
# `|| true` only covers an error return, not a call that never returns. These checks pin the
# replacement: kill by PID, bounded wait, escalate, and VERIFY the process is gone, returning
# a real failure (never a hang) when something survives, so the caller can refuse to delete
# a bundle that still has a live process inside it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/app-quit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---- pids_inside_bundle: the pure filter ----------------------------------------------------

BUNDLE="/Applications/Overture.app"
SPACED_BUNDLE="/Users/dan/Photography Assets/Overture/mac/build/Build/Products/Release/Overture.app"

ps_fixture() {
  cat <<EOF
  101 /Applications/Overture.app/Contents/MacOS/Overture
  202 /Users/dan/Photography Assets/Overture/mac/build/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
  303 /Applications/Safari.app/Contents/MacOS/Safari
  404 grep Overture.app/Contents/MacOS
  505 /Users/dan/Photography Assets/Overture/mac/build/Build/Products/Release/Overture.app/Contents/MacOS/Overture
EOF
}

got="$(pids_inside_bundle "$(ps_fixture)" "${BUNDLE}")"
if [[ "${got}" == "101" ]]; then
  pass "matches only processes running from inside the given bundle"
else
  fail "matches only processes running from inside the given bundle" "got: ${got}"
fi

got="$(pids_inside_bundle "$(ps_fixture)" "${SPACED_BUNDLE}")"
if [[ "${got}" == "505" ]]; then
  pass "handles a bundle path containing spaces"
else
  fail "handles a bundle path containing spaces" "got: ${got}"
fi

got="$(pids_inside_bundle "$(ps_fixture)" "/Applications/Missing.app")"
if [[ -z "${got}" ]]; then
  pass "reports nothing for a bundle with no running process"
else
  fail "reports nothing for a bundle with no running process" "got: ${got}"
fi

# ---- quit_bundle_instances: the driver ------------------------------------------------------
#
# The seams (app_quit_ps, app_quit_kill, app_quit_tick) are overridden below so the driver can
# be exercised against a scripted process table, with no real process touched and no real sleep.

KILL_LOG="${TMP}/kill.log"
ALIVE_FILE="${TMP}/alive"

app_quit_ps() {
  if [[ -s "${ALIVE_FILE}" ]]; then
    echo "  909 ${BUNDLE}/Contents/MacOS/Overture"
  fi
}
app_quit_tick() { :; }

# 1. No instance running: succeeds silently, kills nothing.
: > "${KILL_LOG}"
: > "${ALIVE_FILE}"
app_quit_kill() { echo "$1 $2" >> "${KILL_LOG}"; }
if quit_bundle_instances "${BUNDLE}" >/dev/null 2>&1 && [[ ! -s "${KILL_LOG}" ]]; then
  pass "does nothing when no instance is running"
else
  fail "does nothing when no instance is running" "kill log: $(cat "${KILL_LOG}")"
fi

# 2. The polite path: the process dies on TERM, so no escalation happens.
: > "${KILL_LOG}"
echo alive > "${ALIVE_FILE}"
app_quit_kill() {
  echo "$1 $2" >> "${KILL_LOG}"
  [[ "$1" == "TERM" ]] && : > "${ALIVE_FILE}"
}
if quit_bundle_instances "${BUNDLE}" >/dev/null 2>&1; then
  if [[ "$(cat "${KILL_LOG}")" == "TERM 909" ]]; then
    pass "a process that honors TERM is never escalated"
  else
    fail "a process that honors TERM is never escalated" "kill log: $(cat "${KILL_LOG}")"
  fi
else
  fail "a process that honors TERM is never escalated" "driver reported failure"
fi

# 3. Escalation: the process ignores TERM, dies on KILL, and the driver still succeeds.
: > "${KILL_LOG}"
echo alive > "${ALIVE_FILE}"
app_quit_kill() {
  echo "$1 $2" >> "${KILL_LOG}"
  [[ "$1" == "KILL" ]] && : > "${ALIVE_FILE}"
}
if quit_bundle_instances "${BUNDLE}" >/dev/null 2>&1; then
  if grep -q "^TERM 909$" "${KILL_LOG}" && grep -q "^KILL 909$" "${KILL_LOG}"; then
    pass "a process that ignores TERM is escalated to KILL"
  else
    fail "a process that ignores TERM is escalated to KILL" "kill log: $(cat "${KILL_LOG}")"
  fi
else
  fail "a process that ignores TERM is escalated to KILL" "driver reported failure"
fi

# 4. The failure path (#2072's actual defect class): a process that survives everything must
# come back as a real nonzero failure with the survivor named, never a hang and never a false
# success, so build-install.sh can refuse to rm -rf a bundle that still has a live process.
: > "${KILL_LOG}"
echo alive > "${ALIVE_FILE}"
app_quit_kill() { echo "$1 $2" >> "${KILL_LOG}"; }
err="$(quit_bundle_instances "${BUNDLE}" 2>&1 >/dev/null)"
code="$?"
if [[ "${code}" -ne 0 ]]; then
  pass "a process that survives KILL is a real failure, not a hang or a false success"
else
  fail "a process that survives KILL is a real failure, not a hang or a false success" "exit ${code}"
fi
if echo "${err}" | grep -q "909"; then
  pass "the failure names the surviving process"
else
  fail "the failure names the surviving process" "stderr: ${err}"
fi

# 5. Under `set -euo pipefail` (build-install.sh's shell options), finding nothing to quit must
# be an empty answer with a zero status: a grep that matches nothing exits 1, and with pipefail
# that 1 would abort the whole installer in its NORMAL case (no instance running).
out="$(bash -c "set -euo pipefail
source '${SCRIPT_DIR}/app-quit.sh'
app_quit_ps() { echo '  1 /bin/launchd'; }
quit_bundle_instances '/Applications/Missing.app'
echo survived")"
if [[ "${out}" == "survived" ]]; then
  pass "no instance running is a zero status even under set -euo pipefail"
else
  fail "no instance running is a zero status even under set -euo pipefail" "output: ${out}"
fi

# ---- wiring ---------------------------------------------------------------------------------
#
# A correct driver nothing calls would leave the installer exactly as stuck as before. These are
# text assertions because build-install.sh runs xcodebuild and cannot be executed in a fixture.

INSTALLER="${SCRIPT_DIR}/../../build-install.sh"
RUN_DEBUG="${SCRIPT_DIR}/../run-debug.sh"

if grep -qF 'osascript' "${INSTALLER}"; then
  fail "build-install.sh no longer quits via osascript" "an osascript quit can block forever (#2072)"
else
  pass "build-install.sh no longer quits via osascript"
fi

if grep -qF 'quit_bundle_instances "${DEST}"' "${INSTALLER}"; then
  pass "build-install.sh quits the installed bundle through the shared driver"
else
  fail "build-install.sh quits the installed bundle through the shared driver"
fi

if grep -qF 'app-quit.sh' "${RUN_DEBUG}" && ! grep -qE 'while .*waited.*-lt 10' "${RUN_DEBUG}"; then
  pass "run-debug.sh shares the driver instead of keeping its own copy of the wait loop"
else
  fail "run-debug.sh shares the driver instead of keeping its own copy of the wait loop"
fi

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} app-quit check(s) failed"
  exit 1
fi
echo "all app-quit.sh checks passed"
