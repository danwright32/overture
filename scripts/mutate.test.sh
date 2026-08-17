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

# --- a mutation that landed somewhere other than where it was aimed is a REFUSAL (#2820) -------------
# The fourth way this can lie, and the worst, because it lies in the CAUGHT direction. A perl expression
# that misfires can damage the file outside the line it was aimed at, which turns the whole suite red,
# and "the suite went red" was read as "the guard is real". Measured 2026-08-16: an expression using a
# pipe as its perl delimiter reached the regex engine as a bare alternation with an empty branch, matched
# the EMPTY STRING at offset 0, and prepended text ahead of a shebang. Roughly 1600 of the suite's
# declarations are source-text guards and CAUGHT is the verdict quoted as proof of each one.
#
# An expression whose match consumed no characters landed at an arbitrary offset rather than on any code,
# so it can never be evidence about a guard, whatever the suite then does.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/nomatch|/PREFIX /' 2>&1)"
STATUS=$?
assert_contains "an empty match is refused as having landed elsewhere" "${OUT}" "LANDED ELSEWHERE"
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"
assert_contains "and says the match consumed nothing" "${OUT}" "empty"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"
assert_equals "and the file is put back" 'struct Subject {
    static let answer = "yes"
}' "$(cat "${SUBJECT}")"

# The aim can also be DECLARED, which is the only way the tool can know where a mutation was supposed to
# land. A mutation that changes a line outside the declared aim is refused the same way.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/struct Subject/struct Other/' 2>&1)"
STATUS=$?
assert_contains "a mutation outside the declared aim is refused" "${OUT}" "LANDED ELSEWHERE"
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"
assert_contains "and names the line it actually touched" "${OUT}" "line(s) 1"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# And a mutation that lands ON the declared aim is judged normally, so the check cannot simply refuse
# everything (a guard that refuses every input is indistinguishable from one that works, L1).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "a mutation on the declared aim is judged normally" "${OUT}" "CAUGHT"
assert_not_contains "and is not refused" "${OUT}" "LANDED ELSEWHERE"
assert_equals "and exits 0" "0" "${STATUS}"

# --- a near-total failure is not proof that any one guard is real (#2820) ----------------------------
# The other half. A mutation that breaks a file badly enough makes EVERY check fail, and a run in which
# everything went red is indistinguishable from one in which the guard under test fired. Read as
# evidence the instrument misfired, not as proof.
#
# Both runner shapes are driven, because the shape mutate.sh meets depends on which runner it was given
# and the measured incident was on the shell fixtures, not the Swift suite (L147: a guard seen to fail
# on one chosen fixture has only been shown to work on the shape somebody had in mind).
ALL_FIXTURES_RED="$(make_runner allfixtures 1 'Running 3 shell fixture(s)...
==> scripts/a.test.sh
FAIL - scripts/a.test.sh
==> scripts/b.test.sh
FAIL - scripts/b.test.sh
==> scripts/c.test.sh
FAIL - scripts/c.test.sh')"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${ALL_FIXTURES_RED}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "every fixture going red is not proof" "${OUT}" "NOT PROOF"
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"
assert_contains "and quotes how much of the run went red" "${OUT}" "3 of 3"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

ONE_FIXTURE_RED="$(make_runner onefixture 1 'Running 3 shell fixture(s)...
==> scripts/a.test.sh
FAIL - scripts/a.test.sh
==> scripts/b.test.sh
==> scripts/c.test.sh')"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${ONE_FIXTURE_RED}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "one fixture of three going red is an ordinary catch" "${OUT}" "CAUGHT"
assert_not_contains "and is not condemned as a misfire" "${OUT}" "NOT PROOF"
assert_equals "and exits 0" "0" "${STATUS}"

# The mark Swift Testing prints before a failing test, BUILT from its UTF-8 bytes rather than typed. The
# pre-push style gate blocks a new line carrying that character and cannot tell a line that USES one from
# a line that must QUOTE one, which is the gate working correctly; the answer is to build it, so the file
# holds no literal one (mac/scripts/lib/suite-stats.test.sh is the worked example, #2193).
FAIL_MARK="$(printf '\xe2\x9c\x98')"
ALL_TESTS_RED="$(make_runner alltests 1 "${FAIL_MARK} Test \"one\" failed after 0.01 seconds with 1 issue.
${FAIL_MARK} Test \"two\" failed after 0.01 seconds with 1 issue.
${FAIL_MARK} Test \"three\" failed after 0.01 seconds with 1 issue.
${FAIL_MARK} Test \"four\" failed after 0.01 seconds with 1 issue.
${FAIL_MARK} Test run with 4 tests in 1 suites failed after 0.1 seconds with 4 issues.")"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${ALL_TESTS_RED}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "every test in the run going red is not proof either" "${OUT}" "NOT PROOF"
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# A SCOPED run is exempt, and deliberately so: a scope naming the one suite that holds the guard is
# expected to go entirely red, and that is the ordinary proof shape. A rule that condemned it would fire
# on the common case and be switched off within a day (L93).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${ALL_TESTS_RED}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' -only-testing:OvertureTests/SubjectTests 2>&1)"
STATUS=$?
assert_contains "a scoped run going entirely red is still a catch" "${OUT}" "CAUGHT"
assert_not_contains "and is not condemned" "${OUT}" "NOT PROOF"
assert_equals "and exits 0" "0" "${STATUS}"

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
