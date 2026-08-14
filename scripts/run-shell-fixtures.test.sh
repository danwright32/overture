#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Coverage for run-shell-fixtures.sh's run_shell_fixtures (#698): runs every given fixture script,
# never stops at the first failure (so one broken fixture doesn't hide another), and reports
# overall pass/fail via its own return code. Uses real, disposable throwaway scripts in a temp dir
# rather than the repo's actual *.test.sh files, so this test doesn't depend on (or duplicate) what
# those fixtures individually assert.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./run-shell-fixtures.sh
source "${SCRIPT_DIR}/run-shell-fixtures.sh"
set +e

FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASSING="${TMP_DIR}/passing.test.sh"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "${PASSING}"
chmod +x "${PASSING}"

ALSO_PASSING="${TMP_DIR}/also-passing.test.sh"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "${ALSO_PASSING}"
chmod +x "${ALSO_PASSING}"

FAILING="${TMP_DIR}/failing.test.sh"
printf '#!/usr/bin/env bash\necho boom\nexit 1\n' > "${FAILING}"
chmod +x "${FAILING}"

run_shell_fixtures "${PASSING}" "${ALSO_PASSING}" >/dev/null
assert_equals "all-passing fixtures return success" "0" "$?"

run_shell_fixtures "${PASSING}" "${FAILING}" >/dev/null
assert_equals "one failing fixture makes the overall run fail" "1" "$?"

RAN_BOTH_OUTPUT="$(run_shell_fixtures "${FAILING}" "${ALSO_PASSING}" 2>&1)"
DID_RUN_LATER_FIXTURE="false"
[[ "${RAN_BOTH_OUTPUT}" == *"also-passing.test.sh"* ]] && DID_RUN_LATER_FIXTURE="true"
assert_equals "a failure earlier in the list doesn't stop later fixtures from running" \
  "true" "${DID_RUN_LATER_FIXTURE}"

# #2501: the defect this harness could not see. A fixture that calls a helper the file never
# defines prints "command not found" to stderr, the assertion silently does nothing, and the
# fixture still exits 0 reporting every check passed. That happened on 2026-08-11 in
# verify-and-merge-branch.test.sh, where three assertions were written against a name that file
# does not define, and the run ended saying all its fixtures passed. Exit status alone cannot
# tell that apart from real coverage, so the harness has to read the output.
TYPO="${TMP_DIR}/typo.test.sh"
printf '#!/usr/bin/env bash\nassert_contains "a check" "haystack" "needle"\necho "All fixtures passed."\nexit 0\n' > "${TYPO}"
chmod +x "${TYPO}"

run_shell_fixtures "${TYPO}" >/dev/null 2>&1
assert_equals "a fixture that exits 0 while calling an undefined helper is a failure" "1" "$?"

# Asserts the HARNESS said why, not merely that bash's own stderr passed through: that stderr
# names the helper whether the harness reads it or not, so matching on the helper name alone
# would pass just as well before this change as after it.
TYPO_OUTPUT="$(run_shell_fixtures "${TYPO}" 2>&1)"
DID_NAME_THE_CAUSE="false"
[[ "${TYPO_OUTPUT}" == *"FAIL - ${TYPO}"*"command it could not find"* ]] && DID_NAME_THE_CAUSE="true"
assert_equals "the harness says the fixture called something that does not exist" \
  "true" "${DID_NAME_THE_CAUSE}"

# The phrase only condemns a fixture when it is bash reporting an unresolved command. A fixture
# that legitimately prints the words (stable-signing.test.sh quotes them back when its own guard
# against this defect fires) must still be allowed to pass.
QUOTES_THE_PHRASE="${TMP_DIR}/quotes.test.sh"
printf '#!/usr/bin/env bash\necho "ok - would have said command not found"\nexit 0\n' > "${QUOTES_THE_PHRASE}"
chmod +x "${QUOTES_THE_PHRASE}"

run_shell_fixtures "${QUOTES_THE_PHRASE}" >/dev/null 2>&1
assert_equals "a fixture that merely quotes the phrase still passes" "0" "$?"

# Some fixtures drive a script's missing-dependency path on purpose: models.test.sh runs record_model
# with PATH set to a directory that holds nothing, to prove a run still succeeds when there is no node
# to stamp it with. That produces the same words on stderr as a mistyped assertion, so a fixture can
# declare which command it expects to go missing. The declaration is per command, not a blanket
# exemption, so a typo inside a declaring fixture is still caught.
DECLARED="${TMP_DIR}/declared.test.sh"
printf '#!/usr/bin/env bash\necho "shell-fixture-expects-missing-command: node"\nPATH=/nonexistent node -e 1\necho "ok - degrades without node"\nexit 0\n' > "${DECLARED}"
chmod +x "${DECLARED}"

run_shell_fixtures "${DECLARED}" >/dev/null 2>&1
assert_equals "a declared missing command does not condemn the fixture" "0" "$?"

DECLARED_TYPO="${TMP_DIR}/declared-typo.test.sh"
printf '#!/usr/bin/env bash\necho "shell-fixture-expects-missing-command: node"\nPATH=/nonexistent node -e 1\nassert_contains "a check" "a" "b"\necho "ok"\nexit 0\n' > "${DECLARED_TYPO}"
chmod +x "${DECLARED_TYPO}"

run_shell_fixtures "${DECLARED_TYPO}" >/dev/null 2>&1
assert_equals "declaring one missing command does not excuse a different one" "1" "$?"

# A declaration that stops being true means the degradation path is no longer being exercised, and the
# fixture would go on reading as if it were. Said out loud rather than failed, because whether the
# words appear at all depends on how the shell resolves a command it has already run.
STALE_DECLARATION="${TMP_DIR}/stale-declaration.test.sh"
printf '#!/usr/bin/env bash\necho "shell-fixture-expects-missing-command: node"\necho "ok - nothing went missing"\nexit 0\n' > "${STALE_DECLARATION}"
chmod +x "${STALE_DECLARATION}"

STALE_OUTPUT="$(run_shell_fixtures "${STALE_DECLARATION}" 2>&1)"
STALE_RC="$?"
assert_equals "a declaration that never fired does not fail the fixture" "0" "${STALE_RC}"
DID_WARN="false"
[[ "${STALE_OUTPUT}" == *"declared it would exercise a missing"*"node"* ]] && DID_WARN="true"
assert_equals "a declaration that never fired is said out loud" "true" "${DID_WARN}"

# Every case above runs with errexit OFF, because this file turns it off right after sourcing. The
# real entry point does not: run-shell-fixtures.sh opens with `set -euo pipefail`, and main calls
# run_shell_fixtures with those still in force. So the options the shipping runner actually uses get
# their own case, driven through the real script rather than the sourced function. Without this,
# reading a fixture's output through a pipeline made the runner die on the FIRST failing fixture with
# that fixture's own status, silently undoing the property the case above asserts, and the whole suite
# stayed green because no fixture was failing that day (L3).
UNDER_ERREXIT="$(
  set -euo pipefail
  # shellcheck source=./run-shell-fixtures.sh
  source "${SCRIPT_DIR}/run-shell-fixtures.sh"
  rc=0
  run_shell_fixtures "${FAILING}" "${ALSO_PASSING}" 2>&1 || rc=$?
  echo "RETURNED=${rc}"
)"
assert_contains "under errexit, a failing fixture does not stop the ones after it" \
  "${UNDER_ERREXIT}" "also-passing.test.sh"
assert_contains "under errexit, the run still reports its own failure count" \
  "${UNDER_ERREXIT}" "RETURNED=1"

# The same for the reading itself: a fixture that exits 0 while calling something bash cannot find
# must be counted, not allowed to abort the run before the fixtures behind it get to run.
UNDER_ERREXIT_TYPO="$(
  set -euo pipefail
  # shellcheck source=./run-shell-fixtures.sh
  source "${SCRIPT_DIR}/run-shell-fixtures.sh"
  rc=0
  run_shell_fixtures "${TYPO}" "${ALSO_PASSING}" 2>&1 || rc=$?
  echo "RETURNED=${rc}"
)"
assert_contains "under errexit, an unresolved command does not stop the run either" \
  "${UNDER_ERREXIT_TYPO}" "also-passing.test.sh"
assert_contains "under errexit, an unresolved command is still counted" \
  "${UNDER_ERREXIT_TYPO}" "RETURNED=1"

# The fixture's own output must still reach the person watching, not be swallowed by the reading.
STREAMED_OUTPUT="$(run_shell_fixtures "${PASSING}" 2>&1)"
DID_SHOW_FIXTURE_OUTPUT="false"
[[ "${STREAMED_OUTPUT}" == *"ok"* ]] && DID_SHOW_FIXTURE_OUTPUT="true"
assert_equals "the fixture's own output is still shown" "true" "${DID_SHOW_FIXTURE_OUTPUT}"

# #2601: fixtures run CONCURRENTLY, not one after another. The serial run cost 113s of which 78s was
# two fixtures, so the phase should cost roughly the slowest fixture instead of the sum of all of them.
# Proven by construction rather than by a stopwatch: the FIRST fixture in the list waits (up to 15s)
# for a marker only the SECOND fixture writes. A serial runner cannot pass this, because the waiter
# runs to its timeout before the marker's writer ever starts; a concurrent runner sees it in well
# under a second. No wall-clock assertion, so a slow machine cannot flake it, only fail it honestly.
WAITER="${TMP_DIR}/waits-for-marker.test.sh"
cat > "${WAITER}" <<WAITER_EOF
#!/usr/bin/env bash
for _ in \$(seq 1 150); do
  [[ -f "${TMP_DIR}/marker" ]] && { echo "ok - saw the marker"; exit 0; }
  sleep 0.1
done
echo "FAIL - never saw the marker: fixtures are running serially"
exit 1
WAITER_EOF
chmod +x "${WAITER}"

MARKER_WRITER="${TMP_DIR}/writes-marker.test.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\necho ok\nexit 0\n' "${TMP_DIR}/marker" > "${MARKER_WRITER}"
chmod +x "${MARKER_WRITER}"

run_shell_fixtures "${WAITER}" "${MARKER_WRITER}" >/dev/null 2>&1
assert_equals "fixtures run concurrently: an early fixture can see a later one's effect" "0" "$?"
rm -f "${TMP_DIR}/marker"

# --- a fixture that leaves temp files behind fails, however green its own assertions are ------------
#
# Measured 2026-08-13: three fixtures were each leaking one file per run into the shared temp directory,
# and one had been doing it since at least the day before (53 files) because a second `trap ... EXIT`
# silently replaced the first. Nothing noticed, because the files are small, they are outside the
# checkout, and every one of those fixtures passed. Same class as #2585, where the identical habit at
# Xcode's scale filled the disk and stopped the machine.

LEAKY="${TMP_DIR}/leaky.test.sh"
cat > "${LEAKY}" <<'LEAKY_EOF'
#!/usr/bin/env bash
# Creates a temp file the way a real fixture does, and never removes it.
mktemp "${TMPDIR:-/tmp}/leaked-by-a-fixture.XXXXXX" >/dev/null
echo ok
exit 0
LEAKY_EOF
chmod +x "${LEAKY}"

LEAK_OUTPUT="$(run_shell_fixtures "${LEAKY}" 2>&1)"
LEAK_STATUS=$?
assert_equals "a fixture that leaves a temp file behind fails, even though it exited 0" "1" "${LEAK_STATUS}"
assert_contains "and the report names the file it left" "${LEAK_OUTPUT}" "leaked-by-a-fixture"
assert_contains "and says where to look for the cause" "${LEAK_OUTPUT}" "EXIT trap"

# The mirror: a fixture that cleans up after itself passes. Without this the guard could be satisfied by
# refusing everything, which is a different way of checking nothing.
TIDY="${TMP_DIR}/tidy.test.sh"
cat > "${TIDY}" <<'TIDY_EOF'
#!/usr/bin/env bash
f="$(mktemp "${TMPDIR:-/tmp}/tidy-fixture.XXXXXX")"
trap 'rm -f "${f}"' EXIT
echo ok
exit 0
TIDY_EOF
chmod +x "${TIDY}"

run_shell_fixtures "${TIDY}" >/dev/null 2>&1
assert_equals "a fixture that cleans up after itself passes" "0" "$?"

# The allowed names are DERIVED from the account the run is under, not written down. tsx names its cache
# after the user id, so a hardcoded one is correct only on the machine it was written on: on any other
# Mac or account the guard would call that cache a leak and fail a run for a reason unrelated to the code
# under test, which is how a guard gets edited until it is quiet.
#
# Driven with a made-up account number, because the assertion has to be able to FAIL. Checking this
# machine's own number would pass whether the name is derived or hardcoded, since they are the same here.
ALLOWED_FOR_OTHER_ACCOUNT="$(fixture_temp_allowed_names 4242)"
assert_contains "the allowed names follow the account the run is under" "${ALLOWED_FOR_OTHER_ACCOUNT}" "tsx-4242"
assert_not_contains "and do not carry the account this was written on" "${ALLOWED_FOR_OTHER_ACCOUNT}" "tsx-501"
assert_contains "the tool cache that has no account in its name is always allowed" \
  "${ALLOWED_FOR_OTHER_ACCOUNT}" "node-compile-cache"

# Another account's cache appearing under this run IS unexpected, so it must still be reported.
OTHER_ACCOUNT_CACHE="$(fixture_temp_allowed_names 4242)"
assert_not_contains "one account's allowed list does not excuse another's" "${OTHER_ACCOUNT_CACHE}" "tsx-7777"

# node and tsx write their caches wherever TMPDIR points, on any fixture that shells out to either. They
# are not the fixture's doing, so they must not be reported as its leak.
TOOL_CACHE="${TMP_DIR}/tool-cache.test.sh"
cat > "${TOOL_CACHE}" <<'CACHE_EOF'
#!/usr/bin/env bash
mkdir -p "${TMPDIR:-/tmp}/node-compile-cache"
echo ok
exit 0
CACHE_EOF
chmod +x "${TOOL_CACHE}"

run_shell_fixtures "${TOOL_CACHE}" >/dev/null 2>&1
assert_equals "a node or tsx cache is not counted against the fixture" "0" "$?"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-shell-fixtures.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} run-shell-fixtures.sh fixture(s) failed."
  exit 1
fi
