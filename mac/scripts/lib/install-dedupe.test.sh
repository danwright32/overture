#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# 2026-07-18: `overture` (build-install.sh --launch) left a second Release Overture.app in the build
# products. It carries the same com.danwright.overture bundle id and overture:// scheme as the
# installed /Applications copy, so `open overture://show` routed to the STRAY build copy and launched
# a second instance that the store single-writer lock refused (the "Overture's data is unavailable"
# clash). overture_dedupe_installed_bundle removes the stray build copy and re-registers the
# installed bundle. These checks pin the behaviour that matters, including the safety guard that it
# must NEVER delete the installed bundle itself.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/install-dedupe.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A stub standing in for LaunchServices' lsregister: records its args so we can prove the installed
# bundle was re-registered, without touching the real LaunchServices database.
LSREGISTER_LOG="${TMP}/lsregister.args"
STUB="${TMP}/lsregister"
cat >"${STUB}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${LSREGISTER_LOG}"
EOF
chmod +x "${STUB}"

make_bundle() { mkdir -p "$1/Contents/MacOS"; }

# 1. The happy path: a stray built copy exists and the installed copy exists.
built="${TMP}/build/Overture.app"
dest="${TMP}/Applications/Overture.app"
make_bundle "${built}"
make_bundle "${dest}"
: > "${LSREGISTER_LOG}"
LSREGISTER="${STUB}" overture_dedupe_installed_bundle "${built}" "${dest}"
if [[ -e "${built}" ]]; then
  fail "removes the stray build copy" "built copy still present at ${built}"
else
  pass "removes the stray build copy"
fi
if [[ -e "${dest}" ]]; then
  pass "leaves the installed copy in place"
else
  fail "leaves the installed copy in place" "installed copy was deleted"
fi
if grep -qF -- "-f ${dest}" "${LSREGISTER_LOG}"; then
  pass "re-registers the installed bundle with LaunchServices"
else
  fail "re-registers the installed bundle with LaunchServices" "lsregister args: $(cat "${LSREGISTER_LOG}")"
fi

# 2. Safety guard (the failure path that matters): if BUILT_APP and DEST are the same path, the
#    function must NOT delete the installed bundle. A naive rm would wipe the live app.
same="${TMP}/same/Overture.app"
make_bundle "${same}"
: > "${LSREGISTER_LOG}"
LSREGISTER="${STUB}" overture_dedupe_installed_bundle "${same}" "${same}"
if [[ -e "${same}" ]]; then
  pass "never deletes the bundle when BUILT_APP equals DEST"
else
  fail "never deletes the bundle when BUILT_APP equals DEST" "the installed bundle was deleted"
fi

# 3. Idempotent edge: a missing build copy is a no-op, not an error, and the installed copy is still
#    re-registered.
missing="${TMP}/gone/Overture.app"
dest2="${TMP}/Applications2/Overture.app"
make_bundle "${dest2}"
: > "${LSREGISTER_LOG}"
if LSREGISTER="${STUB}" overture_dedupe_installed_bundle "${missing}" "${dest2}"; then
  pass "missing build copy is a no-op success"
else
  fail "missing build copy is a no-op success" "function returned non-zero"
fi
if grep -qF -- "-f ${dest2}" "${LSREGISTER_LOG}"; then
  pass "still re-registers the installed bundle when the build copy is already gone"
else
  fail "still re-registers the installed bundle when the build copy is already gone" "lsregister args: $(cat "${LSREGISTER_LOG}")"
fi

# 4. A missing/unusable LaunchServices registrar must not crash the function; it still removes the
#    stray copy.
built3="${TMP}/build3/Overture.app"
dest3="${TMP}/Applications3/Overture.app"
make_bundle "${built3}"
make_bundle "${dest3}"
if LSREGISTER="${TMP}/does-not-exist" overture_dedupe_installed_bundle "${built3}" "${dest3}"; then
  pass "tolerates a missing lsregister without failing"
else
  fail "tolerates a missing lsregister without failing" "function returned non-zero"
fi
if [[ -e "${built3}" ]]; then
  fail "still removes the stray copy when lsregister is missing" "built copy still present"
else
  pass "still removes the stray copy when lsregister is missing"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all install-dedupe checks passed"
