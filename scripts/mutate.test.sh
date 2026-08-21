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

# --- a runner this shell cannot run is refused, never reported as CAUGHT (#2846) ---------------------
#
# The worst of all of them, because it answers in the reassuring direction: a runner that cannot start
# exits non-zero having tested nothing, which is byte for byte what a red suite looks like from here, and
# CAUGHT is the verdict quoted as proof for roughly 1,700 source-text guards in this suite. NOTHING RAN
# cannot catch it, because that is decided from a total the runner never printed.
#
# Measured 2026-08-16 while proving the guards for #2818, with the runner set to
# `bash scripts/lib/project-freshness.test.sh`, which is the natural way to reach for a shell fixture and
# is TWO WORDS: the shell looked for a file of that whole name, exited 127, and this said CAUGHT.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="bash ${WORK}/some-fixture.test.sh" "${MUTATE}" "${SUBJECT}" 's/yes/no/' 2>&1)"
STATUS=$?
assert_contains "a runner carrying arguments is refused" "${OUT}" "NO RUNNER"
# Asserted against the VERDICT LINE rather than against the whole output, because the refusal itself
# names the verdict it is replacing ("would otherwise call that CAUGHT"), and a needle that a message
# ABOUT the thing can satisfy is not a guard on the thing (L103).
VERDICT="$(grep -E '^(CAUGHT|SURVIVED|NOT APPLIED|NOTHING RAN|LANDED ELSEWHERE|NOT PROOF|NO RUNNER)' <<< "${OUT}" | head -1)"
assert_equals "and the verdict is the refusal, not a reading of any suite" \
  "NO RUNNER - nothing was mutated and nothing was run." "${VERDICT}"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "it names the wrapper as the way to pass arguments" "${OUT}" "executable wrapper"
# Nothing was mutated, which is the other half: the refusal happens before the file is touched, so there
# is no restore to depend on.
assert_contains "the subject is left exactly as it was" "$(cat "${SUBJECT}")" 'static let answer = "yes"'

OUT="$(OVERTURE_MUTATE_RUNNER="${WORK}/no-such-runner.sh" "${MUTATE}" "${SUBJECT}" 's/yes/no/' 2>&1)"
assert_contains "a runner that does not exist is refused too" "${OUT}" "NO RUNNER"
assert_contains "and the refusal names the value it was given" "${OUT}" "no-such-runner.sh"

# The runner is passed as ONE command and must stay that way: this repo's own default runner path holds
# a space, because the checkout lives under "Photography Assets", so a version that split the runner on
# whitespace to allow arguments broke every ordinary invocation. Asserted on the SOURCE, since a fixture
# setting OVERTURE_MUTATE_RUNNER never exercises the default at all.
SRC="$(cat "${MUTATE}")"
assert_not_contains "the runner is never split into words" "${SRC}" "read -ra RUNNER"

# --- the run log is KEPT, so the failure text does not need a second run (#2972) ---------------------
#
# It printed `tail -n 25` and then deleted the log. AGENTS.md requires the exact failure text of every
# guard in the PR body, and that text routinely sits just outside the window: on a 9 test scoped run
# during #2944 it was about 6 lines above the cut. Recovering evidence the run had ALREADY produced then
# meant repeating the whole mutation, another full build plus a wait on the shared xcodebuild lock. With
# roughly 1,600 source-text guards each supposed to have been seen to fail, that is a tax on the most-used
# verification step in the repo, and it pushes toward quoting a summary rather than the real text.
NOISY_BODY="$(printf 'the failing test is named right here\n'; for i in $(seq 1 40); do printf 'filler line %s\n' "${i}"; done)"
NOISY_RUNNER="$(make_runner noisy 1 "${NOISY_BODY}")"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${NOISY_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_not_contains "the interesting line really is outside the printed window" \
  "${OUT}" "the failing test is named right here"
assert_contains "so the run names where the whole log is" "${OUT}" "full log:"

# And the log is actually there, holding the text the window cut off.
KEPT_LOG="$(printf '%s\n' "${OUT}" | sed -n 's/.*full log: //p' | tail -1)"
assert_equals "the named log exists after the run" "1" "$([ -f "${KEPT_LOG}" ] && echo 1 || echo 0)"
assert_contains "and holds the line the window cut off" "$(cat "${KEPT_LOG}" 2>/dev/null)" \
  "the failing test is named right here"

# A GREEN run keeps it too. The reason to reach for the log is not always a failure: a SURVIVED verdict is
# the one that most needs reading, since it is a finding about a guard rather than about the code.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a surviving guard names its log too" "${OUT}" "full log:"

# --- a mutation that did not BUILD is its own outcome, never CAUGHT (#2995, #2859) -------------------
#
# A build failure used to be folded into CAUGHT, on the reasoning that the compiler caught something. That
# holds for a mutation whose POINT is that the code stops type-checking. It does not hold for the ordinary
# case, a behavioural mutation meant to make one test go red, where a build failure means the INSTRUCTION
# was malformed and the guard under test never ran at all.
#
# Measured 2026-08-19, twice in one session on #2988: `$0` left unescaped in the REPLACEMENT is perl's own
# program-name variable, so it interpolated away and produced code that does not compile. Both attempts
# reported CAUGHT. The guard they claimed to prove had never run.
BUILD_FAILED_RUNNER="$(make_runner buildfailed 65 '/tmp/Subject.swift:2:9: error: cannot find type "Nope" in scope
The following build commands failed:
	SwiftCompile normal arm64
run-tests-locked.sh: the code did not COMPILE, so no test ran. The errors are above.')"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${BUILD_FAILED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "a mutation that did not compile says so" "${OUT}" "DID NOT BUILD"
VERDICT="$(grep -E '^(CAUGHT|SURVIVED|NOT APPLIED|NOTHING RAN|LANDED ELSEWHERE|NOT PROOF|NO RUNNER|DID NOT BUILD|MISPLACED FLAG)' <<< "${OUT}" | head -1)"
assert_not_contains "and the verdict is not a reading of any guard" "${VERDICT}" "CAUGHT"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"
assert_equals "and the file is put back" 'struct Subject {
    static let answer = "yes"
}' "$(cat "${SUBJECT}")"

# A mutation whose POINT is to stop the code compiling DECLARES itself, and is then judged. This is the
# half that keeps the outcome above from being a rule nobody can satisfy: a guard enforced by the type
# system is real and has to be provable.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${BUILD_FAILED_RUNNER}" "${MUTATE}" --breaks-the-build "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "a declared build break is a catch" "${OUT}" "CAUGHT"
assert_not_contains "and is not refused" "${OUT}" "DID NOT BUILD"
assert_contains "and says the compiler is what caught it" "${OUT}" "compiler"
assert_equals "and exits 0" "0" "${STATUS}"

# And the declaration does not become a way to launder any red run: a run that BUILT and failed a test is
# still an ordinary catch, named by test, rather than being reported as the compiler refusing it.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --breaks-the-build "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a declared break that compiled is judged normally" "${OUT}" "the row draws a quiet exit"
assert_not_contains "and is not reported as a compiler refusal" "${OUT}" "compiler"

# --- a flag in the trailing scope position is refused, never forwarded (#2993) -----------------------
#
# `--at` must come BEFORE the file. Put it after the expression and it used to fall into the trailing
# test-scope arguments, get forwarded to run-tests-locked.sh and from there to xcodebuild, which fails on
# the unrecognised option; the runner then fell back to the PURE suite, which takes no scope, so the run
# executed the entire pure suite instead of the tests asked for. Two things were lost silently: the aim
# check was never active, and a targeted proof became a multi-minute full-suite run.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' --at 'static let answer' 2>&1)"
STATUS=$?
assert_contains "a flag after the expression is refused" "${OUT}" "MISPLACED FLAG"
assert_contains "and names the argument it refused" "${OUT}" "--at"
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "the subject is left exactly as it was" "$(cat "${SUBJECT}")" 'static let answer = "yes"'

# A real Swift scope still passes, so the rule cannot simply refuse every trailing argument (L1).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' -only-testing:OvertureTests/SubjectTests 2>&1)"
assert_contains "an ordinary scope is not refused" "${OUT}" "CAUGHT"
assert_not_contains "and nothing is called misplaced" "${OUT}" "MISPLACED FLAG"

# --- a perl variable left unescaped in the expression is refused (#2995) -----------------------------
#
# The measured cause of both CAUGHT-on-a-build-failure incidents. In a perl `s///` replacement `$0` is
# perl's own program-name variable, so `isCandidate($0, ...)` interpolates away and produces code that
# does not compile. It is almost never what the author meant, and the answer is to escape it.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/String($0)/' 2>&1)"
STATUS=$?
assert_contains "an unescaped perl variable is refused" "${OUT}" "PERL VARIABLE"
assert_contains "and says how to write it instead" "${OUT}" '\$0'
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# Escaped, it is exactly what the author meant, so it runs.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/String(\$0)/' 2>&1)"
assert_contains "an escaped one is left alone" "${OUT}" "CAUGHT"
assert_not_contains "and is not refused" "${OUT}" "PERL VARIABLE"

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
