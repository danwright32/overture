#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #1160: build-install.sh --launch surfaced the window with `open overture://show` immediately after
# bootstrapping the login agent, racing the resident copy's LaunchServices registration and spawning a
# SECOND instance the store lock then refused. overture_await_bundle_registered waits for the resident
# to register FIRST, so the URL routes to it instead of launching a duplicate. These checks pin that it
# returns as soon as the bundle registers, gives up after the attempt cap (the failure path), rejects
# an empty bundle id, and never blocks when it cannot probe.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/await-registered.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Never actually sleep between probes in the test.
_noop_sleep() { :; }
export OVERTURE_AWAIT_SLEEP=_noop_sleep

ATTEMPTS_FILE="${TMP}/attempts"

# 1. It returns success as soon as the bundle registers, and stops probing right then (not the full cap).
echo 0 > "${ATTEMPTS_FILE}"
_probe_ready_on_third() {
  local n
  n=$(< "${ATTEMPTS_FILE}"); n=$((n + 1)); echo "${n}" > "${ATTEMPTS_FILE}"
  (( n >= 3 ))
}
export OVERTURE_LSREGISTERED_PROBE=_probe_ready_on_third
if overture_await_bundle_registered "com.danwright.overture" 40; then
  pass "returns success once the bundle registers"
else
  fail "returns success once the bundle registers" "returned non-zero though the probe reported registered"
fi
attempts=$(< "${ATTEMPTS_FILE}")
if [[ "${attempts}" == "3" ]]; then
  pass "stops probing as soon as it registers"
else
  fail "stops probing as soon as it registers" "probed ${attempts} times, expected 3"
fi

# 2. The failure path: it gives up after the attempt cap when the bundle never registers, and does not
#    loop forever. Returns non-zero and probes exactly the cap number of times.
echo 0 > "${ATTEMPTS_FILE}"
_probe_never() {
  local n
  n=$(< "${ATTEMPTS_FILE}"); n=$((n + 1)); echo "${n}" > "${ATTEMPTS_FILE}"
  return 1
}
export OVERTURE_LSREGISTERED_PROBE=_probe_never
if overture_await_bundle_registered "com.danwright.overture" 5; then
  fail "gives up after the attempt cap" "returned success though it never registered"
else
  pass "gives up after the attempt cap"
fi
attempts=$(< "${ATTEMPTS_FILE}")
if [[ "${attempts}" == "5" ]]; then
  pass "probes exactly the cap number of times before giving up"
else
  fail "probes exactly the cap number of times before giving up" "probed ${attempts} times, expected 5"
fi

# 3. An empty bundle id is rejected without probing (nothing to wait for).
echo 0 > "${ATTEMPTS_FILE}"
export OVERTURE_LSREGISTERED_PROBE=_probe_never
if overture_await_bundle_registered "" 5; then
  fail "rejects an empty bundle id" "returned success for an empty bundle id"
else
  pass "rejects an empty bundle id"
fi
attempts=$(< "${ATTEMPTS_FILE}")
if [[ "${attempts}" == "0" ]]; then
  pass "does not probe for an empty bundle id"
else
  fail "does not probe for an empty bundle id" "probed ${attempts} times"
fi

# 4. When it cannot probe (probe reports registered immediately), it returns success on the first
#    attempt and never blocks the launch.
echo 0 > "${ATTEMPTS_FILE}"
_probe_always() {
  local n
  n=$(< "${ATTEMPTS_FILE}"); n=$((n + 1)); echo "${n}" > "${ATTEMPTS_FILE}"
  return 0
}
export OVERTURE_LSREGISTERED_PROBE=_probe_always
if overture_await_bundle_registered "com.danwright.overture" 40; then
  pass "returns immediately when the probe reports registered"
else
  fail "returns immediately when the probe reports registered" "returned non-zero"
fi
attempts=$(< "${ATTEMPTS_FILE}")
if [[ "${attempts}" == "1" ]]; then
  pass "probes only once on the fast path"
else
  fail "probes only once on the fast path" "probed ${attempts} times, expected 1"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all await-registered checks passed"
