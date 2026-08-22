#!/usr/bin/env bash
set -uo pipefail

# #3065: the judging half of scripts/check-temp-dir-leaks.sh, driven through its
# --before/--after/--log-file seam so it can be proved without paying for a whole suite run.
#
# The trap this exists to keep closed is the one the issue names: a suite that cleans up perfectly and a
# suite that NEVER RAN leave the SAME empty before/after difference, so judging on that difference alone
# reports the emptiest possible failure as the cleanest possible pass (L98). The proof that tests ran has
# to come from the run's own output, and "nothing was measured" has to be a distinct exit code from
# "nothing was left behind".

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-temp-dir-leaks.sh"
FAILURES=0

WORK="$(mktemp -d)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/tests"
# Both shapes have to be derivable, and reading only one is the trap this fixture exists for: converting
# a suite to TemporarySandboxes DELETES its appendingPathComponent line, so a guard reading only that form
# would stop covering a suite at the exact moment that suite was fixed, and would go on reporting a clean
# tree (L96).
cat > "${WORK}/tests/ConvertedTests.swift" <<'SWIFT'
final class ConvertedTests {
    private let sandboxes = TemporarySandboxes()
    func a() throws { _ = try sandboxes.make(named: "census") }
    func b() throws { _ = try sandboxes.makeFile(named: "x.json", inSandboxNamed: "prep-results") }
    func c() { _ = sandboxes.reserve(named: "debug-seed-missing") }
}
SWIFT
cat > "${WORK}/tests/NotYetConvertedTests.swift" <<'SWIFT'
struct NotYetConvertedTests {
    func a() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-leaking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
SWIFT

export OVERTURE_TEMP_LEAK_TESTS_DIRS="${WORK}/tests"
UUID_A="11111111-2222-3333-4444-555555555555"
UUID_B="66666666-7777-8888-9999-000000000000"
RAN_LOG="${WORK}/ran.log"
printf 'Test run with 8295 tests in 1140 suites passed after 292.179 seconds.\n' > "${RAN_LOG}"
EMPTY_RUN_LOG="${WORK}/never-ran.log"
printf 'xcodebuild: error: the scheme could not be found\n** TEST FAILED **\n' > "${EMPTY_RUN_LOG}"

run_check() { "${CHECK}" --before "$1" --after "$2" --log-file "$3" 2>&1; }

# --- every prefix is derived, from BOTH shapes -------------------------------------------------------
PREFIXES="$("${CHECK}" --list-prefixes 2>&1)"
for p in census prep-results debug-seed-missing still-leaking; do
  assert_contains "the prefix ${p} is derived from the sources rather than kept by hand" "${PREFIXES}" "${p}-"
done

# --- a clean run ---------------------------------------------------------------------------------------
printf 'unrelated-thing\n' > "${WORK}/before-clean"
printf 'unrelated-thing\n' > "${WORK}/after-clean"
OUT="$(run_check "${WORK}/before-clean" "${WORK}/after-clean" "${RAN_LOG}")"; ST=$?
assert_equals "a suite that ran and left nothing behind passes" "0" "${ST}"
assert_contains "and says so" "${OUT}" "left nothing behind"

# --- a leaking run ---------------------------------------------------------------------------------------
printf 'unrelated-thing\n' > "${WORK}/before-leak"
printf 'unrelated-thing\ncensus-%s\nprep-results-%s\n' "${UUID_A}" "${UUID_B}" > "${WORK}/after-leak"
OUT="$(run_check "${WORK}/before-leak" "${WORK}/after-leak" "${RAN_LOG}")"; ST=$?
assert_equals "a suite that left sandboxes behind fails" "1" "${ST}"
assert_contains "and says how many" "${OUT}" "2 sandbox"
assert_contains "and names the shape, so the suite can be found" "${OUT}" "census-<uuid>"
assert_contains "and names a real directory, because a shape cannot be looked at" "${OUT}" "census-${UUID_A}"

# --- the one that must never read as clean ------------------------------------------------------------
# Identical before and after, so the difference says "nothing left behind", while the log proves nothing
# ran. This is the emptiest possible failure and it must not be the cleanest possible pass.
OUT="$(run_check "${WORK}/before-clean" "${WORK}/after-clean" "${EMPTY_RUN_LOG}")"; ST=$?
assert_equals "a run in which no test executed is UNMEASURED, not clean" "2" "${ST}"
assert_contains "and says which of the two it is" "${OUT}" "no test executed"
assert_not_contains "and never claims the tree was clean" "${OUT}" "left nothing behind"

# --- an absent input is not an empty one ---------------------------------------------------------------
OUT="$(run_check "${WORK}/no-such-before" "${WORK}/after-clean" "${RAN_LOG}")"; ST=$?
assert_equals "a missing before snapshot is unmeasured" "2" "${ST}"
assert_contains "and names which input was missing" "${OUT}" "before snapshot"
OUT="$(run_check "${WORK}/before-clean" "${WORK}/after-clean" "${WORK}/no-such-log")"; ST=$?
assert_equals "a missing run log is unmeasured" "2" "${ST}"
assert_contains "and names that one too" "${OUT}" "test run log"

# --- somebody else's mess is not this run's ------------------------------------------------------------
# A directory already there before the run is not attributable to it, or the first run after any earlier
# leak blames itself for ever and the check is switched off (L93).
printf 'census-%s\n' "${UUID_A}" > "${WORK}/before-pre-existing"
printf 'census-%s\n' "${UUID_A}" > "${WORK}/after-pre-existing"
OUT="$(run_check "${WORK}/before-pre-existing" "${WORK}/after-pre-existing" "${RAN_LOG}")"; ST=$?
assert_equals "a sandbox that was already there is not blamed on this run" "0" "${ST}"

# --- another application's scratch is not ours ---------------------------------------------------------
printf '' > "${WORK}/before-other"
printf 'com.apple.something-%s\nTemporaryItems\n' "${UUID_A}" > "${WORK}/after-other"
OUT="$(run_check "${WORK}/before-other" "${WORK}/after-other" "${RAN_LOG}")"; ST=$?
assert_equals "a directory matching no derived prefix is left alone" "0" "${ST}"

# --- the UUID is required, so a generic prefix cannot swallow the world ---------------------------------
# Requiring the UUID is what keeps a short prefix from matching another application's temp files (L104).
printf '' > "${WORK}/before-nouuid"
printf 'census-notauuid\ncensus\n' > "${WORK}/after-nouuid"
OUT="$(run_check "${WORK}/before-nouuid" "${WORK}/after-nouuid" "${RAN_LOG}")"; ST=$?
assert_equals "a prefix with no UUID after it is not ours" "0" "${ST}"

# --- deriving nothing is unmeasured, never clean --------------------------------------------------------
# If the sources move or the pattern stops matching, EVERY sandbox becomes exempt from the check meant to
# catch it, and the check would go on reporting a clean tree for ever (L96).
mkdir -p "${WORK}/empty-tests"
OUT="$(OVERTURE_TEMP_LEAK_TESTS_DIRS="${WORK}/empty-tests" run_check "${WORK}/before-leak" "${WORK}/after-leak" "${RAN_LOG}")"; ST=$?
assert_equals "deriving no prefixes at all is unmeasured" "2" "${ST}"
assert_contains "and says why that is not a clean tree" "${OUT}" "exempt"

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all check-temp-dir-leaks checks passed"
