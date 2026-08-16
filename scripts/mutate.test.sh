#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains, assert_equals,
# assert_eq, assert_empty (#2501). Haystack second, needle third.
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #2755: coverage for scripts/mutate.sh.
#
# Every guard here is supposed to have been SEEN to fail (L1), and 1600 of the suite's declarations are
# source-text guards, so this is done constantly and was hand-rolled every time. The hand-rolled version
# failed twice in one session in ways that REPORTED SUCCESS: one run piped through a command that was not
# on PATH and exited 0 having tested nothing, and one perl substitution matched nothing, so the green run
# that followed read as a surviving guard rather than as a mutation that never applied (L100).
#
# Both of those are what this fixture is mostly about. The runner is injected, so none of this drives the
# real Swift suite.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATE="${HERE}/mutate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

SUBJECT="${WORK}/Subject.swift"
write_subject() { printf 'struct Subject {\n    static let answer = "yes"\n}\n' > "${SUBJECT}"; }

# A stand-in runner. Prints what a real run prints and exits how it is told, so the fixture can drive
# every verdict without a build.
make_runner() {
  local path="${WORK}/runner-$1.sh" status="$2" body="$3"
  { echo '#!/usr/bin/env bash'; echo "cat <<'RUNNEROUT'"; echo "${body}"; echo "RUNNEROUT"; echo "exit ${status}"; } > "${path}"
  chmod +x "${path}"
  echo "${path}"
}

RED_RUNNER="$(make_runner red 1 '✘ Test "the row draws a quiet exit" failed after 0.01 seconds with 1 issue.
✘ Test run with 12 tests in 2 suites failed after 0.1 seconds with 1 issue.')"
GREEN_RUNNER="$(make_runner green 0 '✔ Test run with 12 tests in 2 suites passed after 0.1 seconds.')"
EMPTY_RUNNER="$(make_runner empty 1 'run-tests-locked.sh: NOTHING RAN. The scope matched no tests.')"

# --- a mutation that matches nothing is a FAILURE, never a surviving guard --------------------------
# The sharpest of the three, because it is the one that reads as a result. A substitution that matched
# nothing leaves the file untouched, so the run that follows is green for the most ordinary reason there
# is, and the report says the guard survived a mutation that never happened (L100).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/nothing-matches-this/x/' 2>&1)"
STATUS=$?
assert_contains "a mutation that changed nothing says so" "${OUT}" "changed nothing"
assert_not_contains "and never reports the guard as surviving" "${OUT}" "SURVIVED"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"
assert_equals "the file is untouched" 'struct Subject {
    static let answer = "yes"
}' "$(cat "${SUBJECT}")"

# --- a guard that goes red is a guard that is real ---------------------------------------------------
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "a mutation the suite catches is reported as caught" "${OUT}" "CAUGHT"
assert_contains "and names the test that caught it" "${OUT}" "the row draws a quiet exit"
assert_equals "and exits 0, because the guard did its job" "0" "${STATUS}"

# --- a guard that stays green is the finding ---------------------------------------------------------
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "a mutation nothing catches is reported as survived" "${OUT}" "SURVIVED"
assert_equals "and exits nonzero, because a vacuous guard is the defect" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# --- a run that executed nothing is its own outcome, never a surviving guard -------------------------
# The other way the hand-rolled version lied. An empty run and a run where everything passed are the two
# most different outcomes a scope can have, and they look identical from a green tick (L98).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${EMPTY_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a run that executed nothing says so" "${OUT}" "NOTHING RAN"
assert_not_contains "and is not called a surviving guard" "${OUT}" "SURVIVED"

# --- the file is always restored, including when the run dies ----------------------------------------
write_subject
BEFORE="$(cat "${SUBJECT}")"
DYING_RUNNER="$(make_runner dying 137 'killed')"
OVERTURE_MUTATE_RUNNER="${DYING_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' >/dev/null 2>&1
assert_equals "the file comes back after a run that died" "${BEFORE}" "$(cat "${SUBJECT}")"

# And after the script itself is killed, which is the case a restore written at the end cannot cover.
write_subject
OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" OVERTURE_MUTATE_SELF_KILL=1 "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' >/dev/null 2>&1
assert_equals "the file comes back after the script is killed mid-run" "${BEFORE}" "$(cat "${SUBJECT}")"

# --- it refuses what it cannot do --------------------------------------------------------------------
OUT="$("${MUTATE}" "${WORK}/does-not-exist.swift" 's/a/b/' 2>&1)"
assert_contains "a missing file is refused by name" "${OUT}" "does-not-exist.swift"

OUT="$("${MUTATE}" 2>&1)"
assert_contains "no arguments prints how to use it" "${OUT}" "usage"

# --- the runner's own status is read, not a pipe's ---------------------------------------------------
# `some-runner | tail -5` reports tail's status, which is how a script that died instantly reads as a
# clean pass. Asserted on the SOURCE, because a fixture cannot see the difference from outside: both
# spellings behave identically whenever the runner happens to exit 0.
SRC="$(cat "${MUTATE}")"
assert_not_contains "the runner is never piped into tail" "${SRC}" "RUNNER}\" | tail"
assert_contains "pipefail is set, so a pipe elsewhere cannot lie either" "${SRC}" "set -uo pipefail"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all mutate.sh checks passed"
