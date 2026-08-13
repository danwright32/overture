#!/usr/bin/env bash
set -uo pipefail

# Fixtures for scripts/lib/derived-data.sh (#2585).
#
# Every case here builds a THROWAWAY DerivedData root under a temp directory and never reads or
# writes the real ~/Library/Developer/Xcode/DerivedData (L2). The plists are real XML plists read
# by the same PlistBuddy call the library uses, not a stub of it, so a fixture cannot agree with
# an assumption about a format nobody checked (L52).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/shell-assertions.sh"
# shellcheck source=./derived-data.sh
source "${SCRIPT_DIR}/derived-data.sh"

FAILURES=0

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/derived-data-fixture.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# Builds one DerivedData-shaped folder. With a workspace argument it gets an info.plist naming that
# workspace; without one it gets no plist at all, which is the shape of a folder Xcode is mid-way
# through creating.
make_folder() {
  local root="$1" name="$2" workspace="${3:-}"
  local dir="${root}/${name}"
  mkdir -p "${dir}"
  if [[ -n "${workspace}" ]]; then
    cat > "${dir}/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>${workspace}</string>
</dict>
</plist>
PLIST
  fi
  printf '%s' "${dir}"
}

# A plist that is well formed but carries no WorkspacePath, which is the case the classifier must
# not read as "the workspace is gone".
make_folder_without_workspace_key() {
  local root="$1" name="$2"
  local dir="${root}/${name}"
  mkdir -p "${dir}"
  cat > "${dir}/info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LastAccessedDate</key>
	<string>2026-08-12T10:00:00Z</string>
</dict>
</plist>
PLIST
  printf '%s' "${dir}"
}

echo "== derived_data_classify =="

CASE_ROOT="${TMP_ROOT}/classify"
mkdir -p "${CASE_ROOT}"

# The three caches every project shares. They are not keyed by a workspace at all, so the orphan
# rule cannot speak about them, and deleting one costs every project on the Mac a rebuild.
for shared in ModuleCache.noindex CompilationCache.noindex SDKStatCaches.noindex; do
  mkdir -p "${CASE_ROOT}/${shared}"
  assert_equals "${shared} is a shared cache" \
    "shared-cache" "$(derived_data_classify "${CASE_ROOT}/${shared}")"
done

LIVE_WORKSPACE_DIR="${TMP_ROOT}/live-checkout/mac"
mkdir -p "${LIVE_WORKSPACE_DIR}/Overture.xcodeproj"
LIVE_DIR="$(make_folder "${CASE_ROOT}" "Overture-live" "${LIVE_WORKSPACE_DIR}/Overture.xcodeproj")"
assert_equals "a workspace still on disk is live" "live" "$(derived_data_classify "${LIVE_DIR}")"

ORPHAN_DIR="$(make_folder "${CASE_ROOT}" "Overture-orphan" "${TMP_ROOT}/deleted-worktree/mac/Overture.xcodeproj")"
assert_equals "a workspace that is gone is an orphan" "orphan" "$(derived_data_classify "${ORPHAN_DIR}")"

NO_PLIST_DIR="$(make_folder "${CASE_ROOT}" "Overture-noplist")"
assert_equals "no info.plist is unreadable, never an orphan" \
  "unreadable" "$(derived_data_classify "${NO_PLIST_DIR}")"

NO_KEY_DIR="$(make_folder_without_workspace_key "${CASE_ROOT}" "Overture-nokey")"
assert_equals "a plist with no WorkspacePath is unreadable" \
  "unreadable" "$(derived_data_classify "${NO_KEY_DIR}")"

EMPTY_PATH_DIR="$(make_folder "${CASE_ROOT}" "Overture-emptypath" "")"
assert_equals "an empty WorkspacePath is unreadable" \
  "unreadable" "$(derived_data_classify "${EMPTY_PATH_DIR}")"

# The one way this rule can fail open. An external drive that is unplugged makes every workspace on
# it look deleted, and the folders would then be reclaimed while the work they belong to is fine.
UNMOUNTED_DIR="$(make_folder "${CASE_ROOT}" "Overture-unmounted" \
  "/Volumes/OvertureFixtureVolumeThatIsNotMounted/checkout/mac/Overture.xcodeproj")"
assert_equals "a workspace on an unmounted volume is unreadable, not an orphan" \
  "unreadable" "$(derived_data_classify "${UNMOUNTED_DIR}")"

RELATIVE_DIR="$(make_folder "${CASE_ROOT}" "Overture-relative" "some/relative/path.xcodeproj")"
assert_equals "a relative WorkspacePath is unreadable" \
  "unreadable" "$(derived_data_classify "${RELATIVE_DIR}")"

assert_equals "a folder that does not exist is unreadable" \
  "unreadable" "$(derived_data_classify "${CASE_ROOT}/never-created")"

echo
echo "== derived_data_orphans =="

ORPHANS="$(derived_data_orphans "${CASE_ROOT}")"
assert_contains "the orphan is listed" "${ORPHANS}" "Overture-orphan"
assert_not_contains "the live folder is not listed" "${ORPHANS}" "Overture-live"
assert_not_contains "a shared cache is not listed" "${ORPHANS}" "ModuleCache.noindex"
assert_not_contains "an unreadable folder is not listed" "${ORPHANS}" "Overture-noplist"
assert_not_contains "an unmounted volume's folder is not listed" "${ORPHANS}" "Overture-unmounted"
assert_equals "exactly one orphan in this root" "1" "$(printf '%s\n' "${ORPHANS}" | grep -c . || true)"

assert_empty "a DerivedData root that does not exist yields nothing" \
  "$(derived_data_orphans "${TMP_ROOT}/no-such-root")"

echo
echo "== derived_data_reclaim =="

RECLAIM_ROOT="${TMP_ROOT}/reclaim"
mkdir -p "${RECLAIM_ROOT}"
mkdir -p "${RECLAIM_ROOT}/ModuleCache.noindex"
KEEP_LIVE="$(make_folder "${RECLAIM_ROOT}" "Overture-keep" "${LIVE_WORKSPACE_DIR}/Overture.xcodeproj")"
KEEP_UNREADABLE="$(make_folder "${RECLAIM_ROOT}" "Overture-unreadable")"
GO_1="$(make_folder "${RECLAIM_ROOT}" "Overture-gone-1" "${TMP_ROOT}/gone-1/mac/Overture.xcodeproj")"
GO_2="$(make_folder "${RECLAIM_ROOT}" "Overture-gone-2" "${TMP_ROOT}/gone-2/mac/Overture.xcodeproj")"
# Another project's orphan. Dan's call, 2026-08-12: reclaim these too, because the proof that they
# can never be reused is the same proof, and it does not know which project made them.
GO_3="$(make_folder "${RECLAIM_ROOT}" "PostRoll-gone" "${TMP_ROOT}/gone-3/PostRoll.xcodeproj")"

RECLAIMED="$(derived_data_reclaim "${RECLAIM_ROOT}")"
assert_equals "reclaimed three orphans" "3" "${RECLAIMED}"
[[ -d "${GO_1}" ]] && fail "the first orphan should be gone" || pass "the first orphan is gone"
[[ -d "${GO_2}" ]] && fail "the second orphan should be gone" || pass "the second orphan is gone"
[[ -d "${GO_3}" ]] && fail "another project's orphan should be gone" || pass "another project's orphan is gone"
[[ -d "${KEEP_LIVE}" ]] && pass "the live folder survives" || fail "the live folder should survive"
[[ -d "${KEEP_UNREADABLE}" ]] && pass "the unreadable folder survives" || fail "the unreadable folder should survive"
[[ -d "${RECLAIM_ROOT}/ModuleCache.noindex" ]] && pass "the shared cache survives" || fail "the shared cache should survive"

assert_equals "a second run reclaims nothing and does not fail" "0" "$(derived_data_reclaim "${RECLAIM_ROOT}")"
assert_equals "a root that does not exist reclaims nothing" "0" "$(derived_data_reclaim "${TMP_ROOT}/no-such-root")"

echo
echo "== derived_data_space_warning =="

# The threshold has to fire well before the disk is full. When it filled on 2026-08-12 the first
# symptom was `df` itself failing, because the shell could not write its own output file, so a
# warning that waits for a nearly full disk arrives after the ability to read it has gone.
assert_contains "warns below the threshold" \
  "$(derived_data_space_warning 10 50)" "10 GiB free"
assert_contains "the warning names what to do" \
  "$(derived_data_space_warning 10 50)" "reclaim-orphan-derived-data.sh"
assert_empty "says nothing above the threshold" "$(derived_data_space_warning 200 50)"
assert_empty "says nothing exactly at the threshold" "$(derived_data_space_warning 50 50)"
# An unreadable free-space figure must not be scored as a healthy one (L50).
assert_contains "an unreadable figure is reported, not passed" \
  "$(derived_data_space_warning "" 50)" "could not read"
assert_contains "a non-numeric figure is reported, not passed" \
  "$(derived_data_space_warning "not-a-number" 50)" "could not read"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All derived-data.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} derived-data.sh fixture(s) failed."
exit 1
