#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"
# shellcheck source=../../../scripts/lib/fixture-process-leak.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/fixture-process-leak.sh"

# #1009: the detached runs (prep, reply-classify, scout-extract) are long, headless claude runs that
# nobody supervises. Nothing held a power assertion, so an idle-sleep timeout or a lid close mid run
# suspended or killed the job with no loud failure. sleep-guard.sh holds a no-idle-sleep assertion
# (caffeinate) for the life of a run and releases it when the run ends OR dies. These checks pin the
# release-on-end and release-on-death behaviour: an assertion left held forever is its own defect.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/sleep-guard.sh"

TMP="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP}"' EXIT

is_alive() { kill -0 "$1" 2>/dev/null; }

# Give a just-signalled process a moment to actually go away before asserting it did.
wait_gone() {
  local pid="$1" i=0
  while is_alive "${pid}" && [ "${i}" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_alive "${pid}"
}

# A stub that stands in for caffeinate: it just blocks so we can prove start launched a live process
# and that stop_sleep_guard actually reaps it. Deterministic, no real power assertion involved.
STUB="${TMP}/fake-caffeinate"
cat > "${STUB}" <<'EOF'
#!/bin/sh
# Ignore all caffeinate flags; just stay alive until killed.
while :; do sleep 1; done
EOF
chmod +x "${STUB}"

# --- start_sleep_guard launches a live guard and prints its PID -------------------------------------

GUARD="$(SLEEP_GUARD_BIN="${STUB}" start_sleep_guard "$$")"
if [ -n "${GUARD}" ] && is_alive "${GUARD}"; then
  pass "start_sleep_guard launches a live guard process and prints its pid"
else
  fail "start_sleep_guard should launch a live guard and print its pid" "printed: '${GUARD}'"
fi

# --- the run ends: stop_sleep_guard releases the assertion (the core cleanup path) ------------------

stop_sleep_guard "${GUARD}"
if wait_gone "${GUARD}"; then
  pass "stop_sleep_guard releases the assertion when the run ends"
else
  fail "stop_sleep_guard must kill the guard so no assertion is left held forever"
fi

# --- stop is idempotent: calling it again, or with nothing, is a quiet no-op ------------------------
# (assume-it-runs-twice: an EXIT trap can fire on a run that already reaped its guard.)

if stop_sleep_guard "${GUARD}" && stop_sleep_guard "" ; then
  pass "stop_sleep_guard is a quiet no-op on an already-dead pid and on an empty pid"
else
  fail "stop_sleep_guard must never error on a stale or empty pid"
fi

# --- caffeinate missing: start fails loudly (nonzero, empty pid), never a phantom guard -------------

MISSING="$(SLEEP_GUARD_BIN="${TMP}/does-not-exist" start_sleep_guard "$$")"
if [ -z "${MISSING}" ]; then
  pass "start_sleep_guard prints no pid when caffeinate is unavailable"
else
  fail "start_sleep_guard must not print a phantom pid when the binary is missing" "printed: '${MISSING}'"
fi
if SLEEP_GUARD_BIN="${TMP}/does-not-exist" start_sleep_guard "$$" >/dev/null 2>&1; then
  fail "start_sleep_guard must return nonzero when caffeinate is unavailable"
else
  pass "start_sleep_guard returns nonzero when caffeinate is unavailable"
fi

# --- arm_sleep_guard: the one call a runner makes, arming for THIS shell and printing a live pid ------

ARMED="$(SLEEP_GUARD_BIN="${STUB}" arm_sleep_guard)"
if [ -n "${ARMED}" ] && is_alive "${ARMED}"; then
  pass "arm_sleep_guard prints a live guard pid when caffeinate is available"
  stop_sleep_guard "${ARMED}"
  wait_gone "${ARMED}" || true
else
  fail "arm_sleep_guard should print a live guard pid" "printed: '${ARMED}'"
fi

# --- arm_sleep_guard fails loud: no pid on stdout, a warning on stderr, run continues unprotected -----

ARM_OUT="${TMP}/arm.out"
ARM_ERR="${TMP}/arm.err"
SLEEP_GUARD_BIN="${TMP}/does-not-exist" arm_sleep_guard >"${ARM_OUT}" 2>"${ARM_ERR}"
if [ ! -s "${ARM_OUT}" ] && grep -qi "not protected" "${ARM_ERR}"; then
  pass "arm_sleep_guard prints no pid and warns loudly on stderr when caffeinate is missing"
else
  fail "arm_sleep_guard must emit an empty stdout and a loud stderr warning when unprotected" \
    "stdout: '$(cat "${ARM_OUT}")' stderr: '$(cat "${ARM_ERR}")'"
fi

# --- release on DEATH: with the REAL caffeinate, the guard self-releases when the watched run dies ---
# This is the crash path an EXIT trap can never cover (a hard kill, a forced sleep-kill runs no trap).
# caffeinate -w <pid> exits on its own when the watched process is gone, so the assertion cannot outlive
# a run that died without cleaning up. Skip cleanly where the real tool is absent (non-macOS/CI without
# it) so this fixture never fails for a reason unrelated to our code.
REAL_CAFFEINATE="/usr/bin/caffeinate"
if [ -x "${REAL_CAFFEINATE}" ]; then
  # #3254: started in a process group of its OWN, so the `sleep 1` inside the subshell can be ended with
  # it. `kill "${WATCHED}"` below ends the subshell and NOT its child, which is the very defect the
  # detached runners were fixed for in #3248 and is exactly what this case has to reproduce; it just must
  # not walk away from the child afterwards. Measured before this line existed: one `sleep 1` survived
  # every sweep of this fixture.
  set -m
  ( while :; do sleep 1; done ) &
  WATCHED=$!
  set +m
  # Keep bash from printing a "Terminated" job-control notice when we kill WATCHED below.
  disown "${WATCHED}" 2>/dev/null || true
  REAL_GUARD="$(SLEEP_GUARD_BIN="${REAL_CAFFEINATE}" start_sleep_guard "${WATCHED}")"
  if [ -n "${REAL_GUARD}" ] && is_alive "${REAL_GUARD}"; then
    kill "${WATCHED}" 2>/dev/null
    fixture_end_process_group "${WATCHED}"
    if wait_gone "${REAL_GUARD}"; then
      pass "real caffeinate guard self-releases when the watched run dies (crash path)"
    else
      fail "a guard that outlives its run holds the assertion forever" "guard ${REAL_GUARD} still alive after watched ${WATCHED} died"
      kill "${REAL_GUARD}" 2>/dev/null
    fi
  else
    kill "${WATCHED}" 2>/dev/null
    fail "real caffeinate should have launched a live guard for the crash-path check" "printed: '${REAL_GUARD}'"
  fi
else
  echo "ok - (skipped) real caffeinate self-release check: ${REAL_CAFFEINATE} not present"
fi

# --- wiring: every detached runner arms the guard and releases it in its EXIT trap ------------------
# A source-grep, deliberately paired with the behavioural checks above (a grep alone proves nothing
# about behaviour). It locks the wiring so a future runner cannot quietly ship without sleep protection,
# the #804/#1097 "right in two runners, missing from the third" failure shape.
for runner in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  path="${REPO_ROOT}/mac/scripts/${runner}"
  if grep -q 'lib/sleep-guard.sh' "${path}" \
    && grep -q 'arm_sleep_guard' "${path}" \
    && grep -q 'stop_sleep_guard' "${path}"; then
    pass "${runner} sources sleep-guard.sh and both arms and releases the assertion"
  else
    fail "${runner} must source sleep-guard.sh and call arm_sleep_guard + stop_sleep_guard"
  fi
done

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all sleep-guard.sh checks passed"
