#!/usr/bin/env bash
set -uo pipefail

# #1970: every Xcode build registers the built app with LaunchServices and nothing ever unregisters
# it. Measured on this Mac 2026-08-04: com.danwright.overture.debug had 78 registrations, 76 of them
# pointing at paths that no longer exist (deleted DerivedData folders and retired agent worktrees).
# The bundle sets LSMultipleInstancesProhibited, so launching it asks LaunchServices to route to an
# existing instance, against a pile of phantoms.
#
# These checks pin the reading and the safety property that matters: an entry is stale ONLY when its
# path is gone from disk, so a live bundle can never be unregistered by this.
#
# The fixture below is shaped from the real `lsregister -dump` output read on 2026-08-04: records are
# separated by a line of 80 dashes, the path line carries a trailing "(0x....)" token, and the
# identifier line comes AFTER the path within the same record.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/stale-registrations.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

SEP="--------------------------------------------------------------------------------"

# Two bundles that still exist, and one path with SPACES in it, because Dan's checkout lives under
# "Photography Assets/Dan Wright Photography" and a helper that mangles that would unregister nothing
# on the one Mac this runs on.
LIVE_PLAIN="${TMP}/DerivedData/live/Build/Products/Debug/Overture.app"
LIVE_SPACED="${TMP}/Photography Assets/Dan Wright/mac/build/Build/Products/Debug/Overture.app"
DEAD_ONE="${TMP}/DerivedData/gone-1/Build/Products/Debug/Overture.app"
DEAD_SPACED="${TMP}/Photography Assets/retired worktree/build/Build/Products/Debug/Overture.app"
mkdir -p "${LIVE_PLAIN}/Contents/MacOS" "${LIVE_SPACED}/Contents/MacOS"

record() {
  printf '%s\n' "${SEP}"
  printf 'bundle id:                  Overture (0x2b18)\n'
  printf 'path:                       %s (0x8480)\n' "$1"
  printf 'name:                       Overture\n'
  printf 'identifier:                 %s\n' "$2"
  printf 'version:                    1.0\n'
}

DUMP="${TMP}/dump.txt"
{
  record "${DEAD_ONE}" "com.danwright.overture.debug"
  record "${LIVE_PLAIN}" "com.danwright.overture.debug"
  record "/Applications/Some Other App.app" "com.example.other"
  record "${DEAD_SPACED}" "com.danwright.overture.debug"
  record "${LIVE_SPACED}" "com.danwright.overture.debug"
  record "/Applications/Overture.app" "com.danwright.overture"
} > "${DUMP}"

# 1. Every path registered for one bundle id, and nobody else's.
got="$(overture_registered_paths "${DUMP}" "com.danwright.overture.debug")"
expected="$(printf '%s\n%s\n%s\n%s' "${DEAD_ONE}" "${LIVE_PLAIN}" "${DEAD_SPACED}" "${LIVE_SPACED}")"
if [ "${got}" = "${expected}" ]; then
  pass "reads every path registered for the bundle id, and no other app's"
else
  fail "reads every path registered for the bundle id, and no other app's" "got: ${got}"
fi

# 2. A different id reads its own entry, so the release bundle is a separate question.
got="$(overture_registered_paths "${DUMP}" "com.danwright.overture")"
if [ "${got}" = "/Applications/Overture.app" ]; then
  pass "the release bundle id reads only its own registration"
else
  fail "the release bundle id reads only its own registration" "got: ${got}"
fi

# 3. THE SAFETY PROPERTY: stale means the path is gone. A bundle still on disk is never stale,
#    whatever else is true of it.
got="$(overture_stale_registrations "${DUMP}" "com.danwright.overture.debug")"
expected="$(printf '%s\n%s' "${DEAD_ONE}" "${DEAD_SPACED}")"
if [ "${got}" = "${expected}" ]; then
  pass "only registrations whose path is gone count as stale"
else
  fail "only registrations whose path is gone count as stale" "got: ${got}"
fi

# 4. Unregistering asks the registrar for each stale path, once, and for no live one.
LSREGISTER_LOG="${TMP}/lsregister.args"
STUB="${TMP}/lsregister"
cat >"${STUB}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "${LSREGISTER_LOG}"
EOF
chmod +x "${STUB}"
: > "${LSREGISTER_LOG}"

count="$(LSREGISTER="${STUB}" overture_unregister_stale "${DUMP}" "com.danwright.overture.debug")"
logged="$(cat "${LSREGISTER_LOG}")"
expected="$(printf '%s\n%s' "${DEAD_ONE}" "${DEAD_SPACED}")"
if [ "${count}" = "2" ] && [ "${logged}" = "${expected}" ]; then
  pass "unregisters each stale path once and never a live bundle"
else
  fail "unregisters each stale path once and never a live bundle" "count=${count} logged=${logged}"
fi

# 5. Nothing stale is a clean no-op, not an error: this runs before every debug build.
CLEAN_DUMP="${TMP}/clean.txt"
{ record "${LIVE_PLAIN}" "com.danwright.overture.debug"; } > "${CLEAN_DUMP}"
: > "${LSREGISTER_LOG}"
count="$(LSREGISTER="${STUB}" overture_unregister_stale "${CLEAN_DUMP}" "com.danwright.overture.debug")"
status=$?
if [ "${status}" -eq 0 ] && [ "${count}" = "0" ] && [ ! -s "${LSREGISTER_LOG}" ]; then
  pass "a database with nothing stale is a clean no-op"
else
  fail "a database with nothing stale is a clean no-op" "status=${status} count=${count}"
fi

# 6. An id with no registrations at all reads as nothing, rather than as an error or a stray line.
got="$(overture_registered_paths "${DUMP}" "com.danwright.nothing.here")"
if [ -z "${got}" ]; then
  pass "an id with no registrations reads as nothing"
else
  fail "an id with no registrations reads as nothing" "got: ${got}"
fi

# 7. A registrar that is missing or fails must not take the build down with it: this runs as a
#    convenience before a build, and a broken LaunchServices is not a reason to refuse to compile.
: > "${LSREGISTER_LOG}"
count="$(LSREGISTER="${TMP}/not-installed" overture_unregister_stale "${DUMP}" "com.danwright.overture.debug")"
status=$?
if [ "${status}" -eq 0 ] && [ "${count}" = "0" ]; then
  pass "a missing registrar reports nothing removed instead of failing"
else
  fail "a missing registrar reports nothing removed instead of failing" "status=${status} count=${count}"
fi

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all checks passed"
