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

# #2541: a fixture that asserted NOTHING is not a passing fixture. Exit 0 with no assertions is what a
# fixture looks like when its body silently did not run: an early return, a loop over an empty list, a
# guard that skipped everything. Finding zero subjects is its own outcome and must never read as "all
# subjects passed" (L98), and that reading is most believable exactly when the work has not happened.
SILENT="${TMP_DIR}/silent.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${SILENT}"
chmod +x "${SILENT}"

run_shell_fixtures "${SILENT}" >/dev/null 2>&1
assert_equals "a fixture that asserted nothing is not a pass" "1" "$?"

SILENT_OUTPUT="$(run_shell_fixtures "${SILENT}" 2>&1)"
case "${SILENT_OUTPUT}" in
  *"asserted nothing"*) echo "ok - the harness says why, rather than only failing" ;;
  *) echo "FAIL - the harness did not say the fixture asserted nothing"; echo "  ${SILENT_OUTPUT}"
     FAILURES=$((FAILURES + 1)) ;;
esac

# And the other half, because a rule that counts lines is one typo away from failing every fixture: a
# fixture that DID assert is still a pass, whichever of the two spellings this repo uses for "ok".
DASH_OK="${TMP_DIR}/dash-ok.test.sh"
printf '#!/usr/bin/env bash\necho "ok - it did a thing"\nexit 0\n' > "${DASH_OK}"
chmod +x "${DASH_OK}"
COLON_OK="${TMP_DIR}/colon-ok.test.sh"
printf '#!/usr/bin/env bash\necho "  ok: it did a thing"\nexit 0\n' > "${COLON_OK}"
chmod +x "${COLON_OK}"

run_shell_fixtures "${DASH_OK}" "${COLON_OK}" >/dev/null 2>&1
assert_equals "both spellings of a passing assertion still count" "0" "$?"

# --- #2850: a broken pipe is a failure, not a result ---
#
# A fixture whose pipeline breaks reports an assertion failing about code that is perfectly correct,
# because `set -o pipefail` makes the producer's SIGPIPE the pipeline's status. Both halves are driven
# here: the RUNTIME one, which reads the shell's own write error out of a real fixture's output, and the
# SOURCE one, which fires on every run rather than only when the race opens.

# A fixture that really does break a pipe, rather than a log with the words pasted into it: the message
# has to be the shell's, or this proves nothing about what the shell prints (L52).
#
# `yes` writes without end, so `grep -q` exiting on its first match is certain to leave it writing into a
# closed pipe. Wrapped in a subshell whose output is captured, because the point is the message, not the
# status. The producer is a BUILTIN (printf in a loop) so bash itself reports the write error; an
# external command is killed by the signal silently.
BROKEN_PIPE="${TMP_DIR}/broken-pipe.test.sh"
cat > "${BROKEN_PIPE}" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
big=""
for _ in $(seq 1 20000); do big+="match me and then keep going for a while yet "; done
printf '%s' "${big}" | grep -q "match me"
echo "ok - the probe asserted something"
exit 0
PROBE
chmod +x "${BROKEN_PIPE}"

BROKEN_OUTPUT="$(run_shell_fixtures "${BROKEN_PIPE}" 2>&1)"
BROKEN_STATUS=$?
case "${BROKEN_OUTPUT}" in
  *"broke a pipe"*)
    echo "ok - a fixture that broke a pipe is reported, not passed"
    assert_equals "and the run is red" "1" "$([ "${BROKEN_STATUS}" -ne 0 ] && echo 1 || echo 0)" ;;
  *"Broken pipe"*)
    echo "FAIL - the shell reported a broken pipe and the harness did not name it"
    FAILURES=$((FAILURES + 1)) ;;
  *)
    # Not a failure of the rule: this machine's bash did not lose the race, so there was nothing to
    # catch. Said out loud rather than passing silently, because a probe that produced no broken pipe
    # proves nothing either way and a quiet pass here would read as coverage (L98). The check itself is
    # still exercised, deterministically, just below.
    echo "NOTE - the probe did not break a pipe on this machine, so the end-to-end path was not raced" ;;
esac

# So the runtime check is ALSO driven directly, which does not depend on winning a race. The message is
# the one bash really prints, measured from the incident this issue was filed on (2026-08-16, in a full
# scripts/test-all.sh run against mac/scripts/lib/scout-tools.test.sh).
DIRECT_LOG="${TMP_DIR}/broken.log"
printf 'ok - something\nmac/scripts/lib/scout-tools.test.sh: line 170: printf: write error: Broken pipe\nok - more\n' > "${DIRECT_LOG}"
DIRECT_OUTPUT="$(FIXTURE_PATH_FOR_REPORT="some.test.sh" fixture_pipeline_did_not_break "${DIRECT_LOG}" 2>&1)"
DIRECT_STATUS=$?
assert_equals "a log carrying the shell's own write error is a failure" "1" "${DIRECT_STATUS}"
case "${DIRECT_OUTPUT}" in
  *"broke a pipe"*) echo "ok - and it says a pipe broke rather than restating the assertion" ;;
  *) echo "FAIL - the runtime check did not name the broken pipe"; echo "  ${DIRECT_OUTPUT}"
     FAILURES=$((FAILURES + 1)) ;;
esac
case "${DIRECT_OUTPUT}" in
  *"line 170"*) echo "ok - and quotes the line, so the offending pipeline can be found" ;;
  *) echo "FAIL - the runtime check did not quote the offending line"; FAILURES=$((FAILURES + 1)) ;;
esac

# An ordinary log is untouched, or every fixture in the repo would fail on it.
CLEAN_LOG="${TMP_DIR}/clean.log"
printf 'ok - something\nok - more\n' > "${CLEAN_LOG}"
FIXTURE_PATH_FOR_REPORT="some.test.sh" fixture_pipeline_did_not_break "${CLEAN_LOG}" >/dev/null 2>&1
assert_equals "an ordinary log passes" "0" "$?"

# The SOURCE half, which does not depend on any race. A fixture carrying the shape is named before
# anything runs.
RACED_SOURCE="${TMP_DIR}/raced.test.sh"
printf '#!/usr/bin/env bash\nif printf "%%s" "${x:-a}" | grep -q a; then echo "ok - x"; fi\n' > "${RACED_SOURCE}"
chmod +x "${RACED_SOURCE}"
SOURCE_OUTPUT="$(fixture_sources_avoid_short_circuit_pipes "${RACED_SOURCE}" 2>&1)"
SOURCE_STATUS=$?
assert_equals "a fixture whose condition reads a short-circuiting pipe is refused" "1" "${SOURCE_STATUS}"
case "${SOURCE_OUTPUT}" in
  *"raced.test.sh"*) echo "ok - and the refusal names the file and line" ;;
  *) echo "FAIL - the refusal did not name the offending fixture"; echo "  ${SOURCE_OUTPUT}"
     FAILURES=$((FAILURES + 1)) ;;
esac

# And the other direction, which is what keeps the rule from being switched off: a pipeline whose STATUS
# IS NEVER READ is left alone. Eight of those exist in this repo, all assignments inside $(...), and a
# rule that condemned them would fire on the common case (L93).
ASSIGNED="${TMP_DIR}/assigned.test.sh"
printf '#!/usr/bin/env bash\nline="$(printf "%%s" "abc" | grep -n b | head -1)"\necho "ok - $line"\n' > "${ASSIGNED}"
chmod +x "${ASSIGNED}"
fixture_sources_avoid_short_circuit_pipes "${ASSIGNED}" >/dev/null 2>&1
assert_equals "a pipeline whose status nobody reads is left alone" "0" "$?"

# The herestring form every fix in #2850 used is accepted, or the rule would condemn its own remedy.
FIXED="${TMP_DIR}/fixed.test.sh"
printf '#!/usr/bin/env bash\nif grep -q a <<< "${x:-a}"; then echo "ok - x"; fi\n' > "${FIXED}"
chmod +x "${FIXED}"
fixture_sources_avoid_short_circuit_pipes "${FIXED}" >/dev/null 2>&1
assert_equals "the herestring remedy is accepted" "0" "$?"

# --- #3125: a background job must not be killed in the breath it is started --------------------------
#
# The proven defect. `run-heartbeat.test.sh` started a stand-in and killed it on the very next line, then
# waited for it. The kill is sent so soon after the fork that it sometimes does not take, and the wait
# then sits for the stand-in's whole lifetime. Measured 2026-08-22 under the real runner: one round in
# roughly ten cost 306 seconds, every assertion still passing, and marks either side of those two lines
# showed +1s before and +301s after while every other mark in the fixture stayed at +1s.
#
# It is refused at the SOURCE, before anything runs, for #2850's reason: a runtime check could only ever
# fire on the runs where the race actually opened, which is one in ten.
RACED_KILL="${TMP_DIR}/raced-kill.test.sh"
printf '#!/usr/bin/env bash\nsleep 300 & P=$!\nkill "${P}" 2>/dev/null; wait "${P}" 2>/dev/null\necho "ok - x"\n' > "${RACED_KILL}"
chmod +x "${RACED_KILL}"
KILL_OUTPUT="$(fixture_sources_avoid_kill_wait_on_a_fresh_job "${RACED_KILL}" 2>&1)"
KILL_STATUS=$?
assert_equals "a fixture that kills and waits for a job it just started is refused" "1" "${KILL_STATUS}"
case "${KILL_OUTPUT}" in
  *"raced-kill.test.sh"*) echo "ok - and the refusal names the file" ;;
  *) echo "FAIL - the refusal did not name the offending fixture"; echo "  ${KILL_OUTPUT}"
     FAILURES=$((FAILURES + 1)) ;;
esac
case "${KILL_OUTPUT}" in
  *"line 3"*) echo "ok - and quotes the line the wait is on" ;;
  *) echo "FAIL - the refusal did not name the line"; echo "  ${KILL_OUTPUT}"
     FAILURES=$((FAILURES + 1)) ;;
esac

# The other direction, which is what stops this being switched off (L93). Every OTHER recorded background
# pid in this repo is the `stuck-tool-call.test.sh` shape: a stand-in started, real work done, and the
# WATCHDOG killed rather than the stand-in. Its race window is closed by the work in between, and a rule
# that condemned it would fire on eight lines that have never stalled.
WORKING="${TMP_DIR}/working.test.sh"
printf '#!/usr/bin/env bash\nsleep 120 & P=$!\n( true ) & WD=$!\nsleep 3\nkill "${WD}" 2>/dev/null || true\necho "ok - x"\n' > "${WORKING}"
chmod +x "${WORKING}"
fixture_sources_avoid_kill_wait_on_a_fresh_job "${WORKING}" >/dev/null 2>&1
assert_equals "a stand-in with real work before the kill is left alone" "0" "$?"

# And the remedy this issue's fix used must be accepted, or the rule would condemn its own cure: a job
# that EXITS ON ITS OWN needs no kill at all, so there is no race to lose.
CURED="${TMP_DIR}/cured.test.sh"
printf '#!/usr/bin/env bash\n( exit 0 ) & P=$!\nwait "${P}" 2>/dev/null\necho "ok - x"\n' > "${CURED}"
chmod +x "${CURED}"
fixture_sources_avoid_kill_wait_on_a_fresh_job "${CURED}" >/dev/null 2>&1
assert_equals "a job left to exit on its own is accepted" "0" "$?"

# The false positive this guard shipped with for one run, kept as a test because it is the failure mode
# that gets a rule switched off. Its first version asked only whether the two lines after a recorded pid
# CONTAINED the characters "kill" and "wait", and the line after this guard's own synthetic offender
# calls `fixture_sources_avoid_kill_wait_on_a_fresh_job`, whose name carries both. A single-letter pid
# variable made it worse, matching any capital letter in the neighbouring line. It condemned its own test.
MENTIONS="${TMP_DIR}/mentions.test.sh"
printf '#!/usr/bin/env bash\nsleep 5 & P=$!\nrun_the_kill_wait_checker "${SOME_PATH}"\necho "ok - P"\n' > "${MENTIONS}"
chmod +x "${MENTIONS}"
fixture_sources_avoid_kill_wait_on_a_fresh_job "${MENTIONS}" >/dev/null 2>&1
assert_equals "an identifier merely carrying the words kill and wait is not a kill or a wait" "0" "$?"

# The real fixture that carried the defect, so this cannot be marked fixed while the fixture still has it.
fixture_sources_avoid_kill_wait_on_a_fresh_job "${REPO_ROOT}/mac/scripts/lib/run-heartbeat.test.sh" >/dev/null 2>&1
assert_equals "run-heartbeat.test.sh no longer kills a job it just started" "0" "$?"

# --- the stall guard is actually WIRED IN (#2929) -----------------------------------------------------
#
# `scripts/lib/fixture-stall-guard.test.sh` proves the guard decides correctly, and would keep passing if
# this runner never recorded a thing for it to read. Measured with `scripts/mutate.sh`: deleting the
# wrapper's "started" line was reported SURVIVED. A guard whose input nothing supplies is a value with no
# writer (L46), so the wiring is asserted here, where the runner is.
RUNNER_SRC="$(cat "${SCRIPT_DIR}/run-shell-fixtures.sh" 2>/dev/null || echo "")"
assert_contains "the runner sources the stall guard" "${RUNNER_SRC}" "lib/fixture-stall-guard.sh"
assert_contains "and starts a watch on the progress file" "${RUNNER_SRC}" "start_fixture_watch"
assert_contains "and stops it" "${RUNNER_SRC}" "stop_fixture_watch"

# Both ENDS, which is the half a lane full of fast fixtures would otherwise hide.
assert_contains "each fixture records that it started" "${RUNNER_SRC}" 'echo "started ${fixture}" >> "${scratch}/progress"'
assert_contains "and that it finished" "${RUNNER_SRC}" 'echo "finished ${fixture}" >> "${scratch}/progress"'

# The watch has to be stopped on the way OUT as well as on the happy path, or a watcher outlives its run
# and sits warning about a file nobody is writing.
assert_contains "the watch is stopped from a trap too" "${RUNNER_SRC}" "trap 'stop_fixture_watch"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-shell-fixtures.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} run-shell-fixtures.sh fixture(s) failed."
  exit 1
fi
