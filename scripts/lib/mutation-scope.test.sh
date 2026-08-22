#!/usr/bin/env bash
set -uo pipefail

# #3098: mutate.sh must refuse a SURVIVED whose scope never ran the tests for the file it broke.
#
# Hit for real on 2026-08-21 while proving #2726. A sentence in
# mac/Overture/Integration/ScoutService.swift was reworded, scoped to
# -only-testing:OvertureTests/ScoutStartGateTests, and the tool reported SURVIVED. The guard was fine:
# the test lives in a SECOND suite in that same file, ScoutStartGateWiringTests, so the scope ran nine
# real, unrelated tests and never the one under test. Re-run against the right suite, CAUGHT.
#
# That is a lie in the SURVIVED direction, on the tool the whole repo leans on to prove its ~1,950
# source-text guards are real, and NOTHING RAN (#2317) structurally cannot catch it because something
# did run. The caution mutate.sh already prints is a rule living only in prose, which reaches nobody in
# exactly the runs where it matters (L27).
#
# The signature measured on the real incident: suite ScoutStartGateTests mentions ScoutService ZERO
# times, suite ScoutStartGateWiringTests mentions it once. So the question that separates the two runs
# is not "did anything run" but "did any suite that MENTIONS this file run".
#
# The other signature the issue floated, a scope naming a suite whose FILE declares more than one
# @Suite, was rejected: it fires just as hard when the scope named the RIGHT suite of the two, which is
# the common case, and a guard that fires on the common case is switched off within a day (L93).

# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
# shellcheck source=./mutation-scope.sh
source "${SCRIPT_DIR}/mutation-scope.sh"

WORK="$(mktemp -d)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/tests" "${WORK}/src"
: > "${WORK}/src/ScoutService.swift"

# The incident's real shape: two suites in one file, only the second touching the mutated type.
cat > "${WORK}/tests/ScoutStartGateTests.swift" <<'SWIFT'
import Testing

@Suite("Say the reader is busy before spending a run on it (#2208)")
struct ScoutStartGateTests {
  @Test func theGateRefusesWhileAReadIsRunning() {
    let gate = StartGate(busy: true)
    #expect(gate.refuses)
  }
}

@Suite("The scout press consults the gate (#2208)")
struct ScoutStartGateWiringTests {
  @Test func thePressAsksTheGateFirst() {
    #expect(SwiftSource.contains("ScoutService", "startScout"))
  }
}
SWIFT

# A suite with no display name at all: the log prints its TYPE name, so the match has to cope with both.
cat > "${WORK}/tests/BareTests.swift" <<'SWIFT'
import Testing

struct ExperimentTests {
  @Test func itReadsTheRenamer() {
    #expect(SwiftSource.contains("VenueRenamer", "apply"))
  }
}
SWIFT

# A near-miss name, so the match is proved to be on a WORD and not a substring. A suite mentioning
# ScoutServiceExtra is not a suite mentioning ScoutService.
cat > "${WORK}/tests/NearMissTests.swift" <<'SWIFT'
import Testing

@Suite("A different type with a longer name")
struct NearMissTests {
  @Test func itNamesSomethingElse() {
    #expect(SwiftSource.contains("ScoutServiceExtra", "unrelated"))
  }
}
SWIFT

MUTATION_TEST_ROOTS=("${WORK}/tests")

log_with() { printf '%s\n' "$@" > "${WORK}/run.log"; }

SCOPED="-only-testing:OvertureTests/ScoutStartGateTests"

# --- the incident itself -----------------------------------------------------------------------------
log_with 'Suite "Say the reader is busy before spending a run on it (#2208)" started.' \
         'Suite "Say the reader is busy before spending a run on it (#2208)" passed after 0.01 seconds.' \
         'Test run with 9 tests in 1 suites passed after 0.2 seconds.'
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/ScoutService.swift" "${SCOPED}")"; ST=$?
assert_equals "the incident's scope is judged not to have reached the file" "NOT_REACHED" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and it refuses, rather than reporting" "1" "${ST}"
assert_contains "and it names the suite that does mention the file, which is what tells you where to look" \
  "${OUT}" "The scout press consults the gate (#2208)"
assert_not_contains "and does not name the suite that ran and mentions nothing" \
  "${OUT}" "Say the reader is busy"

# --- the same mutation, scoped correctly -------------------------------------------------------------
log_with 'Suite "The scout press consults the gate (#2208)" started.' \
         'Suite "The scout press consults the gate (#2208)" passed after 0.01 seconds.' \
         'Test run with 1 tests in 1 suites passed after 0.2 seconds.'
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/ScoutService.swift" "-only-testing:OvertureTests/ScoutStartGateWiringTests")"; ST=$?
assert_equals "the right scope reaches the file" "REACHED" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and is not refused" "0" "${ST}"

# --- an UNSCOPED run reaches everything, and must never be refused -----------------------------------
# The whole point of a full run is that it ran every suite there is, so the question does not arise.
# Refusing here would fire on the tool's ordinary use and be switched off within a day (L93).
log_with 'Suite "Say the reader is busy before spending a run on it (#2208)" started.' \
         'Test run with 9 tests in 1 suites passed after 0.2 seconds.'
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/ScoutService.swift")"; ST=$?
assert_equals "an unscoped run is never judged on its scope" "REACHED" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and is not refused" "0" "${ST}"

# --- a file no suite mentions ------------------------------------------------------------------------
# SURVIVED is then a real finding about the code, not about the scope, and must be allowed to stand.
# It gets its own verdict rather than borrowing REACHED, because "nothing guards this file" and "the
# scope reached its guards" are different facts and a reader acts differently on each (L11).
log_with 'Suite "Say the reader is busy before spending a run on it (#2208)" started.' \
         'Test run with 9 tests in 1 suites passed after 0.2 seconds.'
: > "${WORK}/src/NobodyMentionsMe.swift"
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/NobodyMentionsMe.swift" "${SCOPED}")"; ST=$?
assert_equals "a file no suite mentions says so in its own words" "NO_SUITE_MENTIONS_IT" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and is not refused" "0" "${ST}"

# --- a suite with no display name, matched on its type name ------------------------------------------
log_with 'Suite ExperimentTests started.' \
         'Test run with 1 tests in 1 suites passed after 0.2 seconds.'
: > "${WORK}/src/VenueRenamer.swift"
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/VenueRenamer.swift" "-only-testing:OvertureTests/ExperimentTests")"; ST=$?
assert_equals "a suite with no display name is matched on the type name the log prints" "REACHED" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and is not refused" "0" "${ST}"

# --- word, not substring -----------------------------------------------------------------------------
# NearMissTests mentions ScoutServiceExtra and nothing else. It must not count as mentioning
# ScoutService, or the guard would silently pass the very run it exists to refuse.
log_with 'Suite "A different type with a longer name" started.' \
         'Test run with 1 tests in 1 suites passed after 0.2 seconds.'
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/ScoutService.swift" "${SCOPED}")"; ST=$?
assert_equals "a longer name containing the symbol does not count as mentioning it" "NOT_REACHED" "$(printf '%s' "${OUT}" | head -1)"
assert_not_contains "and the near miss is not offered as the suite to scope to" "${OUT}" "A different type with a longer name"

# --- a runner whose log has no suite lines at all ----------------------------------------------------
# OVERTURE_MUTATE_RUNNER points at shell fixtures and vitest as well as the Swift suite, and neither
# prints a Swift suite line. Judging those as NOT_REACHED would refuse every shell mutation in the repo.
# It cannot be REACHED either: that would be claiming something was measured when nothing was (L98).
log_with 'ok - some shell fixture assertion' 'all checks passed'
OUT="$(mutation_scope_reached_file "${WORK}/run.log" "${WORK}/src/ScoutService.swift" "${SCOPED}")"; ST=$?
assert_equals "a log with no suite lines is not judged at all" "CANNOT_JUDGE" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and is not refused" "2" "${ST}"
assert_contains "and says why, rather than leaving silence to stand for a measurement" "${OUT}" "no suite"

# --- a log that is not there -------------------------------------------------------------------------
OUT="$(mutation_scope_reached_file "${WORK}/absent.log" "${WORK}/src/ScoutService.swift" "${SCOPED}")"; ST=$?
assert_equals "an unreadable log is not judged at all" "CANNOT_JUDGE" "$(printf '%s' "${OUT}" | head -1)"
assert_equals "and is not refused" "2" "${ST}"

# --- the candidate list is capped, and says what it dropped ------------------------------------------
# Measured 2026-08-22: ScoutService is named by 65 suites and StoreRelocation by 1, so the list is
# sometimes a wall and sometimes the answer. A cut that does not say it cut reads as the whole answer,
# and the suite you wanted may be the one below the line.
SHORT="$(printf 'one\ntwo\nthree\n' | mutation_scope_format_candidates 15)"
assert_contains "a short list is printed whole" "${SHORT}" "three"
assert_not_contains "and says nothing about dropping anything" "${SHORT}" "more of the"

LONG="$(seq 1 65 | sed 's/^/suite /' | mutation_scope_format_candidates 15)"
assert_contains "a long list keeps the first of them" "${LONG}" "suite 1"
assert_not_contains "and cuts the rest" "${LONG}" "suite 65"
assert_contains "and names how many it dropped, of how many there were" "${LONG}" "and 50 more of the 65 suites"

# --- mutate.sh actually consults it ------------------------------------------------------------------
# The rule has to reach the SURVIVED branch, not merely exist beside it (L27, "built is not wired").
# Asserted through a grep that answers yes or no, NEVER by passing mutate.sh's text as the haystack.
# A failing assert_contains prints its haystack, so the file version dumped all ~700 lines of mutate.sh
# into the run log, and mutate.sh's own header names every one of its outcomes. That is the #3035 trap
# recurring exactly: a log that quotes the discussion of a phrase is a log a check for that phrase
# matches (L156). Measured 2026-08-22, it turned a CAUGHT into a NOTHING RAN.
MUTATE_SH="${SCRIPT_DIR}/../mutate.sh"
mutate_holds() {
  if grep -qF -- "$2" "${MUTATE_SH}"; then echo "found"; else echo "missing"; fi
}
assert_equals "mutate.sh sources the rule" "found" "$(mutate_holds x "lib/mutation-scope.sh")"
assert_equals "mutate.sh calls it" "found" "$(mutate_holds x "mutation_scope_reached_file")"
# On the line that SPEAKS the outcome, not on the phrase. The phrase also sits in mutate.sh's header
# list of outcomes, so a guard on the bare words was satisfied by the COMMENT about the refusal while
# the refusal itself had been deleted: it reported SURVIVED when that exact deletion was mutated in
# (measured 2026-08-22, and it is L135, a whole-file match answered by a second occurrence elsewhere).
assert_equals "mutate.sh actually speaks the refusal, not merely documents it" \
  "found" "$(mutate_holds x 'echo "SCOPE MISSED THE FILE')"

# And it EXITS on it. A refusal that printed and then fell through into the SURVIVED report below would
# say both things at once, and the second is the one a reader would act on. Read off the refusal BLOCK
# rather than the whole file, for the same reason as the assertion above it.
REFUSAL_BLOCK="$(awk '/echo "SCOPE MISSED THE FILE/{f=1} f{print} f&&/^fi$/{exit}' "${MUTATE_SH}")"
assert_contains "the refusal hands its candidate list through the cap" "${REFUSAL_BLOCK}" "mutation_scope_format_candidates 15"
assert_contains "and exits rather than falling through to the SURVIVED report" "${REFUSAL_BLOCK}" "exit 2"

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all mutation-scope checks passed"
