#!/usr/bin/env bash
set -uo pipefail

# Fixtures for scripts/reclaim-orphan-derived-data.sh (#2585).
#
# These drive the REAL script, end to end, against a throwaway DerivedData root handed to it through
# XCODE_DERIVED_DATA_ROOT. Nothing here can reach ~/Library/Developer/Xcode/DerivedData (L2), and
# nothing is stubbed, because the part that was worth testing is exactly the part that turns a verdict
# into `rm -rf`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/shell-assertions.sh"
SCRIPT="${SCRIPT_DIR}/reclaim-orphan-derived-data.sh"

FAILURES=0

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reclaim-derived-data-fixture.XXXXXX")"
cleanup() {
  # The read-only case below leaves a directory nothing can be deleted from until it is put back.
  chmod -R u+w "${TMP_ROOT}" 2>/dev/null || true
  rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

make_folder() {
  local root="$1" name="$2" workspace="$3"
  mkdir -p "${root}/${name}"
  cat > "${root}/${name}/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>${workspace}</string>
</dict>
</plist>
PLIST
}

# A root holding one live folder, two dead ones, one unreadable one, and the three shared caches.
build_root() {
  local root="$1"
  mkdir -p "${root}"
  mkdir -p "${TMP_ROOT}/live-checkout/mac/Overture.xcodeproj"
  make_folder "${root}" "Overture-live" "${TMP_ROOT}/live-checkout/mac/Overture.xcodeproj"
  make_folder "${root}" "Overture-dead-1" "${TMP_ROOT}/gone-1/mac/Overture.xcodeproj"
  make_folder "${root}" "Overture-dead-2" "${TMP_ROOT}/gone-2/mac/Overture.xcodeproj"
  mkdir -p "${root}/Overture-unreadable"
  mkdir -p "${root}/ModuleCache.noindex" "${root}/CompilationCache.noindex" "${root}/SDKStatCaches.noindex"
}

run_script() {
  local root="$1"; shift
  XCODE_DERIVED_DATA_ROOT="${root}" bash "${SCRIPT}" "$@" 2>&1
}

echo "== the default run reclaims what is provably dead =="

ROOT_A="${TMP_ROOT}/a"
build_root "${ROOT_A}"
OUT="$(run_script "${ROOT_A}")"
STATUS=$?
assert_equals "exits 0" "0" "${STATUS}"
assert_contains "says how many it reclaimed" "${OUT}" "Reclaimed 2 dead build folder(s)"
assert_contains "says what it kept in use" "${OUT}" "1 still in use"
assert_contains "counts the shared caches without touching them" "${OUT}" "3 shared cache(s)"
[[ -d "${ROOT_A}/Overture-dead-1" ]] && fail "dead-1 should be gone" || pass "dead-1 is gone"
[[ -d "${ROOT_A}/Overture-dead-2" ]] && fail "dead-2 should be gone" || pass "dead-2 is gone"
[[ -d "${ROOT_A}/Overture-live" ]] && pass "the live folder survives" || fail "the live folder should survive"
[[ -d "${ROOT_A}/Overture-unreadable" ]] && pass "the unreadable folder survives" || fail "the unreadable folder should survive"
[[ -d "${ROOT_A}/ModuleCache.noindex" ]] && pass "the shared caches survive a default run" || fail "the shared caches should survive a default run"

echo
echo "== a second run has nothing to do and says so =="

OUT="$(run_script "${ROOT_A}")"
assert_contains "reports zero rather than staying silent" "${OUT}" "Reclaimed 0 dead build folder(s)"

echo
echo "== --dry-run changes nothing =="

ROOT_B="${TMP_ROOT}/b"
build_root "${ROOT_B}"
OUT="$(run_script "${ROOT_B}" --dry-run)"
assert_contains "says what it would do" "${OUT}" "Would reclaim 2 dead build folder(s)"
assert_contains "names the dead workspace so the claim can be checked" "${OUT}" "gone-1/mac/Overture.xcodeproj"
assert_contains "says plainly that nothing was deleted" "${OUT}" "nothing was deleted"
[[ -d "${ROOT_B}/Overture-dead-1" ]] && pass "a dry run leaves the dead folders alone" || fail "a dry run must not delete"

echo
echo "== --clear-shared-caches is a separate, explicit ask =="

OUT="$(run_script "${ROOT_B}" --clear-shared-caches)"
assert_contains "says it cleared them" "${OUT}" "Cleared 3 shared cache(s)"
assert_contains "says what that costs" "${OUT}" "one slow build"
[[ -d "${ROOT_B}/ModuleCache.noindex" ]] && fail "the shared caches should be gone" || pass "the shared caches are gone"

ROOT_C="${TMP_ROOT}/c"
build_root "${ROOT_C}"
OUT="$(run_script "${ROOT_C}" --dry-run --clear-shared-caches)"
[[ -d "${ROOT_C}/ModuleCache.noindex" ]] && pass "a dry run does not clear the shared caches either" || fail "a dry run must not clear the shared caches"

echo
echo "== a folder it cannot remove is reported, not counted =="

# The failure path that matters: rm fails, and the run must neither claim the folder was reclaimed nor
# stop the push it rides along with (L12, L11).
ROOT_D="${TMP_ROOT}/d"
build_root "${ROOT_D}"
chmod 555 "${ROOT_D}"
OUT="$(run_script "${ROOT_D}")"
STATUS=$?
chmod 755 "${ROOT_D}"
assert_equals "still exits 0, because a full disk is not a defect in the change being pushed" "0" "${STATUS}"
assert_contains "names the folder it could not remove" "${OUT}" "could not remove"
assert_contains "does not count it as reclaimed" "${OUT}" "Reclaimed 0 dead build folder(s)"
[[ -d "${ROOT_D}/Overture-dead-1" ]] && pass "the folder really is still there" || fail "the folder should still be there"

echo
echo "== a machine with no DerivedData at all =="

OUT="$(run_script "${TMP_ROOT}/never-created")"
STATUS=$?
assert_equals "exits 0" "0" "${STATUS}"
assert_contains "says there is nothing there rather than reporting a clean sweep" "${OUT}" "no Xcode build output"

echo
echo "== free space is reported every run =="

ROOT_E="${TMP_ROOT}/e"
build_root "${ROOT_E}"
OUT="$(run_script "${ROOT_E}")"
assert_contains "reports free space" "${OUT}" "GiB free"

echo
echo "== it is wired into the path that actually runs =="

# Built is not wired (L3). The whole value of this script is that nobody has to remember it, which is
# only true while scripts/test-all.sh calls it. Comments are stripped before matching, so a comment
# mentioning the script, including one explaining that the call was removed, cannot satisfy this (L103).
TEST_ALL_CODE="$(grep -v '^[[:space:]]*#' "${SCRIPT_DIR}/test-all.sh")"
assert_contains "scripts/test-all.sh runs it before every push" \
  "${TEST_ALL_CODE}" "reclaim-orphan-derived-data.sh"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All reclaim-orphan-derived-data.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} reclaim-orphan-derived-data.sh fixture(s) failed."
exit 1
