#!/usr/bin/env bash
set -uo pipefail

# #1970: the script itself, end to end, against a stubbed LaunchServices.
#
# Dan's call, 2026-08-04: "it should clear them without me." So the pre-push run does the clearing,
# and there is no mode that counts without clearing: these checks pin that the run really removes
# them, that a bundle still on disk is never touched, and that no argument turns the clearing off.
#
# The dump fixture is shaped from real `lsregister -dump` output read that day: records separated by a
# line of dashes, a `path:` line carrying a trailing "(0x....)" token, and the `identifier:` line after
# the path inside the same record.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

SEP="--------------------------------------------------------------------------------"
LIVE="${TMP}/Photography Assets/live/Build/Products/Debug/Overture.app"
DEAD_A="${TMP}/DerivedData/gone-a/Build/Products/Debug/Overture.app"
DEAD_B="${TMP}/retired worktree/build/Build/Products/Debug/Overture.app"
DEAD_RELEASE="${TMP}/gone/Applications/Overture.app"
mkdir -p "${LIVE}/Contents/MacOS"

FIXTURE="${TMP}/dump.txt"
record() {
  printf '%s\n' "${SEP}"
  printf 'path:                       %s (0x8480)\n' "$1"
  printf 'identifier:                 %s\n' "$2"
}
{
  record "${DEAD_A}" "com.danwright.overture.debug"
  record "${LIVE}" "com.danwright.overture.debug"
  record "${DEAD_B}" "com.danwright.overture.debug"
  record "${DEAD_RELEASE}" "com.danwright.overture"
} > "${FIXTURE}"

# Stands in for LaunchServices: answers -dump with the fixture, and records every -u it is asked for,
# so a test can prove what was removed without touching the real database (L2).
UNREGISTERED="${TMP}/unregistered.txt"
STUB="${TMP}/lsregister"
cat >"${STUB}" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-dump" ]; then cat "${FIXTURE}"; exit 0; fi
if [ "\$1" = "-u" ]; then printf '%s\n' "\$2" >> "${UNREGISTERED}"; exit 0; fi
exit 0
EOF
chmod +x "${STUB}"

# 1. The default run clears them, and says how many it took out.
: > "${UNREGISTERED}"
out="$(LSREGISTER="${STUB}" "${SCRIPT_DIR}/prune-stale-registrations.sh" 2>&1)"
status=$?
removed="$(sort "${UNREGISTERED}")"
expected="$(printf '%s\n%s\n%s' "${DEAD_A}" "${DEAD_RELEASE}" "${DEAD_B}" | sort)"
if [ "${status}" -eq 0 ] && [ "${removed}" = "${expected}" ]; then
  pass "the default run unregisters every stale path, across both bundle ids"
else
  fail "the default run unregisters every stale path, across both bundle ids" \
    "status=${status} removed=${removed}"
fi
case "${out}" in
  *"removed 2"*) pass "and reports how many it removed" ;;
  *) fail "and reports how many it removed" "got: ${out}" ;;
esac

# 2. THE SAFETY PROPERTY, at the level Dan actually runs it: a bundle still on disk is never touched.
if ! grep -qF "${LIVE}" "${UNREGISTERED}"; then
  pass "a bundle still on disk is never unregistered"
else
  fail "a bundle still on disk is never unregistered"
fi

# 3. There is exactly ONE behavior, and no mode that counts without clearing. An argument left over
#    from habit, or from a caller that still passes the old flag, must still clear rather than quietly
#    do nothing while reporting a count: a run that looks like it worked and removed nothing is the
#    failure this whole script exists to end.
: > "${UNREGISTERED}"
LSREGISTER="${STUB}" "${SCRIPT_DIR}/prune-stale-registrations.sh" --check >/dev/null 2>&1
if [ -s "${UNREGISTERED}" ]; then
  pass "an unrecognised argument still clears, since there is no count-only mode"
else
  fail "an unrecognised argument still clears, since there is no count-only mode"
fi

# 4. The failure path: LaunchServices missing must never take a push down, since this rides along in
#    the pre-push run and a dirty registration database is not a defect in the change being pushed.
out="$(LSREGISTER="${TMP}/not-installed" "${SCRIPT_DIR}/prune-stale-registrations.sh" 2>&1)"
status=$?
if [ "${status}" -eq 0 ]; then
  pass "a missing LaunchServices does not fail the run"
else
  fail "a missing LaunchServices does not fail the run" "status=${status}"
fi
case "${out}" in
  *"cannot read LaunchServices"*) pass "and says it could not look, rather than reporting a clean database" ;;
  *) fail "and says it could not look, rather than reporting a clean database" "got: ${out}" ;;
esac

# 5. The wiring (#887, a guard and its wiring are two claims). Dan asked for the clearing to happen
#    without him, so the pre-push run has to actually call this.
TEST_ALL="${SCRIPT_DIR}/../../scripts/test-all.sh"
if grep -q "prune-stale-registrations.sh" "${TEST_ALL}"; then
  pass "the pre-push run calls it, so the clearing happens without being asked"
else
  fail "the pre-push run calls it, so the clearing happens without being asked"
fi

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all checks passed"
