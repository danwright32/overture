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
WORK="$(fixture_scratch_dir)"
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

# The mark Swift Testing prints for a failing test, built from its UTF-8 bytes rather than typed, on
# mac/scripts/lib/suite-stats.test.sh's precedent (#2193). The pre-push style gate blocks a new line
# holding one and cannot tell a line that USES the character from a line that must QUOTE it, which is the
# gate working correctly, so the file holds no literal mark and there is nothing for it to catch.
X="$(printf '\xe2\x9c\x98')"
RED_RUNNER="$(make_runner red 1 "${X} Test \"the row draws a quiet exit\" failed after 0.01 seconds with 1 issue.
${X} Test run with 12 tests in 2 suites failed after 0.1 seconds with 1 issue.")"
GREEN_RUNNER="$(make_runner green 0 '✔ Test run with 12 tests in 2 suites passed after 0.1 seconds.')"
EMPTY_RUNNER="$(make_runner empty 1 'run-tests-locked.sh: NOTHING RAN. The scope matched no tests.')"

# --- #3395: the phrase in a DUMP of the code that prints it is not the runner saying it ---------------
# #3035 already narrowed this once, because a Swift failure prints the source around it and any comment
# MENTIONING the phrase put it in the log. The anchor it settled on allowed a `: ` prefix anywhere on the
# line, which lets the phrase back in one level further out: a fixture whose failing assertion PRINTS A
# SCRIPT'S SOURCE puts the runner's own `echo "run-tests-locked.sh: NOTHING RAN. ..."` into the log.
#
# Measured 2026-08-31 while proving #3348's wiring guard: a run that had really gone red on exactly the
# assertion under test was reported NOTHING RAN, so the proof had to be re-read by hand. It lies in the
# direction that refuses a real CAUGHT, which costs a rerun rather than a false proof.
DUMPED_RUNNER="$(make_runner dumped 1 "${X} Test \"the guard fires\" failed after 0.01 seconds with 1 issue.
  echo \"run-tests-locked.sh: NOTHING RAN. \${nothing_ran_detail}\" >&2
${X} Test run with 12 tests in 2 suites failed after 0.1 seconds with 1 issue.")"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${DUMPED_RUNNER}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a quoted echo of the phrase in the log is not the runner saying it" "${OUT}" "CAUGHT"
# On the VERDICT line, not on the phrase: mutate.sh echoes the last lines of the run log, so the log's
# own text is in this output by design and asserting its absence would be asserting about the fixture.
assert_not_contains "and the run is not refused as having executed nothing" \
  "${OUT}" "NOTHING RAN - the run executed no tests"

# #3035's own case, kept, because the two are different lines and a rule covering one is not a rule
# covering the other: this one is the phrase inside PROSE rather than inside a quoted echo.
COMMENTED_RUNNER="$(make_runner commented 1 "${X} Test \"the guard fires\" failed after 0.01 seconds with 1 issue.
    // A run that reported success while executing no tests fails with NOTHING RAN, naming the scope.
${X} Test run with 12 tests in 2 suites failed after 0.1 seconds with 1 issue.")"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${COMMENTED_RUNNER}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a comment mentioning the phrase is not the runner saying it either" "${OUT}" "CAUGHT"
assert_not_contains "and that run is not refused either" \
  "${OUT}" "NOTHING RAN - the run executed no tests"

# The other direction, so the anchoring cannot have turned the check into one that never fires (L1). The
# real emission opens its line with the script's name.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${EMPTY_RUNNER}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "the runner really saying it is still read as NOTHING RAN" "${OUT}" "NOTHING RAN"

# And the bare form, with no script name at all, which the anchor also has to keep.
BARE_RUNNER="$(make_runner bare 1 'NOTHING RAN. The scope matched no tests.')"
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${BARE_RUNNER}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "the phrase opening a line with no prefix is still read as NOTHING RAN" "${OUT}" "NOTHING RAN"

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

# --- an unescaped array sigil in the expression is refused (#3109) -----------------------------------
#
# Measured 2026-08-22 while proving #2839's guard. The expression asked for
# "someone@arealpersonsite.com", `@arealpersonsite` interpolated away, and the text that landed was
# "someone.com", which is not an address at all. The guard under test judges an address by its domain,
# correctly said nothing about a string with no `@` in it, and mutate.sh reported SURVIVED: a real,
# working guard reported as protecting nothing. That is a lie in the direction SURVIVED is quoted in,
# which is as evidence that a guard is fake and should be deleted. The aim check cannot catch it,
# because the substitution lands on exactly the line it was aimed at.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"someone@arealpersonsite.com"/' 2>&1)"
STATUS=$?
assert_contains "an unescaped array sigil is refused" "${OUT}" "PERL VARIABLE"
# Asserted on the ESCAPED spelling the message hands back, not on the bare name: the bare name is in
# the expression the refusal quotes, so an assertion on it would pass whatever the message said.
assert_contains "and says how to write the characters instead" "${OUT}" '\@arealpersonsite'
assert_not_contains "and is never reported as survived" "${OUT}" "SURVIVED"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "the subject is left exactly as it was" "$(cat "${SUBJECT}")" 'static let answer = "yes"'

# The PATTERN half interpolates too, so it is refused there as well. Measured: `s/someone@site\.com/x/`
# reaches the regex as `someone\.com` and matches nothing, so the verdict is NOT APPLIED, reported about
# an expression nobody wrote. Quieter than the SURVIVED above and still an answer about the wrong text.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/someone@arealpersonsite\.com/"x"/' 2>&1)"
assert_contains "an unescaped array sigil in the pattern half is refused too" "${OUT}" "PERL VARIABLE"
assert_not_contains "and is never reported as not applied" "${OUT}" "NOT APPLIED"

# Escaped, it is exactly what the author meant, so it runs. This is the whole of the remedy the message
# names, so it has to work.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"someone\@arealpersonsite.com"/' 2>&1)"
assert_contains "an escaped array sigil is left alone" "${OUT}" "CAUGHT"
assert_not_contains "and is not refused" "${OUT}" "PERL VARIABLE"

# An @ perl cannot read as a variable is not one. The rule has to be narrower than the character, or it
# fires on the ordinary case and gets switched off within a day (L93).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"@ "/' 2>&1)"
assert_contains "an @ with no name after it is left alone" "${OUT}" "CAUGHT"
assert_not_contains "and that one is not refused either" "${OUT}" "PERL VARIABLE"

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

# --- #3080: the aim is a LITERAL locator, not a regex ------------------------------------------------
# Both `--at` and the perl expression were regexes and neither said so at the point of use. Measured
# 2026-08-21, six occurrences in one session, each costing a rerun of a scoped Swift suite: an aim like
# `Text(SendConfirmCopy.openReview)` reported LANDED ELSEWHERE because the parentheses GROUPED rather than
# matched, and `guard let x = try? f` did the same because the `?` made `try` optional.
#
# The tool was right every time, which is the point: it refused rather than reporting a verdict. What it
# cost was that the refusal arrives after the aim is already wrong, and the fix was always the same
# mechanical escaping. `--at` is a locator, so it now matches literally.
write_subject
printf 'struct Subject {\n    static let answer = value(from: other)\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at 'value(from: other)' "${SUBJECT}" 's/value\(from: other\)/nothing/' 2>&1)"
STATUS=$?
assert_contains "an aim holding parentheses matches the text it names" "${OUT}" "CAUGHT"
assert_not_contains "and is not read as a regex group" "${OUT}" "LANDED ELSEWHERE"
assert_equals "and exits 0" "0" "${STATUS}"

# The same for a `?`, which as a regex makes the character before it optional and so names lines the
# author never meant.
printf 'struct Subject {\n    let a = try? one()\n    let b = tr = 2\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at 'try? one()' "${SUBJECT}" 's/try\? one\(\)/nil/' 2>&1)"
STATUS=$?
assert_contains "an aim holding a question mark matches literally" "${OUT}" "CAUGHT"
assert_not_contains "and does not read the ? as optional" "${OUT}" "LANDED ELSEWHERE"

# A literal aim still REFUSES a mutation that lands elsewhere, so the change cannot have turned the check
# into one that accepts everything (a guard that accepts every input is indistinguishable from one that
# works, L1).
printf 'struct Subject {\n    static let answer = value(from: other)\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at 'value(from: other)' "${SUBJECT}" 's/struct Subject/struct Other/' 2>&1)"
STATUS=$?
assert_contains "a literal aim still refuses a mutation that lands elsewhere" "${OUT}" "LANDED ELSEWHERE"
assert_not_contains "and never reports it as caught" "${OUT}" "CAUGHT"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# The regex behaviour is still reachable, opt in, for an aim that genuinely wants one. It is a separate
# flag rather than a mode on `--at`, so which reading is in force is visible at the call site.
printf 'struct Subject {\n    static let answer = "yes"\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at-regex 'answer|absent' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "--at-regex still reads its pattern as a regex" "${OUT}" "CAUGHT"
assert_equals "and exits 0" "0" "${STATUS}"

# And the two are not silently the same flag: an alternation handed to the LITERAL aim names no line, so
# it is refused rather than quietly matching.
printf 'struct Subject {\n    static let answer = "yes"\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" --at 'answer|absent' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a regex handed to the literal aim is refused" "${OUT}" "LANDED ELSEWHERE"

# --- #3344: an aim can span more than one line ------------------------------------------------------
# `--at` refuses a mutation touching any line the aim does not name, which is the right rule and caught
# real misfires (#3080, #2820). What it could not express is an aim spanning TWO ADJACENT lines, which is
# an ordinary shape: a `set -m` above the line it protects, a `return` under the message explaining it.
#
# Measured 2026-08-30 while proving #3292 and #3264: five correctly aimed mutations came back LANDED
# ELSEWHERE naming a line one above or below the aim. Two were worked around by copying the file, editing
# it with perl by hand and copying it back, which is exactly the sequence this script exists to stop
# anybody doing, and one by finding a weaker single-line mutation, which proves less.
TWO_LINE_SUBJECT='struct Subject {
    static let answer = "yes"
    static let other = "no"
}'
printf '%s\n' "${TWO_LINE_SUBJECT}" > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" \
  --at 'static let answer' --at 'static let other' "${SUBJECT}" \
  's/"yes"\n    static let other = "no"/"a"\n    static let other = "b"/' 2>&1)"
STATUS=$?
assert_contains "two aims cover a mutation spanning both their lines" "${OUT}" "CAUGHT"
assert_not_contains "and it is not refused" "${OUT}" "LANDED ELSEWHERE"
assert_equals "and exits 0" "0" "${STATUS}"

# The SAME mutation with only the first aim is still refused, so the pair is doing real work rather than
# the check having been loosened into one that accepts everything (L1).
printf '%s\n' "${TWO_LINE_SUBJECT}" > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" \
  --at 'static let answer' "${SUBJECT}" \
  's/"yes"\n    static let other = "no"/"a"\n    static let other = "b"/' 2>&1)"
assert_contains "one aim over a two-line mutation is still refused" "${OUT}" "LANDED ELSEWHERE"
assert_contains "and names the line the single aim does not cover" "${OUT}" "line(s) 3"

# A mutation outside EVERY aim is refused, and the refusal lists them all, because a message naming one
# of several leaves the reader to guess which were in force.
printf '%s\n' "${TWO_LINE_SUBJECT}" > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" \
  --at 'static let answer' --at 'static let other' "${SUBJECT}" 's/struct Subject/struct Other/' 2>&1)"
assert_contains "a mutation outside every aim is refused" "${OUT}" "LANDED ELSEWHERE"
assert_contains "and lists the first aim" "${OUT}" "--at static let answer"
assert_contains "and the second one too" "${OUT}" "--at static let other"

# An aim that names NO line is refused rather than carried by its neighbour. With a single aim a typo
# could only ever refuse, because every touched line fell outside it, so the wrong aim announced itself.
# With two, a typo is silently covered by the other and the author is left believing a line was named
# that never was (L98).
printf '%s\n' "${TWO_LINE_SUBJECT}" > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" \
  --at 'static let answer' --at 'static let nosuchthing' "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "an aim naming no line is refused" "${OUT}" "LANDED ELSEWHERE"
assert_contains "and names the aim that covers nothing" "${OUT}" "static let nosuchthing"
assert_not_contains "and never reports it as caught" "${OUT}" "CAUGHT"
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# The two flags MIX, each read the way its own flag says. One reading for the whole set would make it
# depend on which flag was written last, which is the invisible-at-the-call-site problem #3080 split
# them over.
printf '%s\n' "${TWO_LINE_SUBJECT}" > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" \
  --at 'static let answer' --at-regex 'let other|absent' "${SUBJECT}" \
  's/"yes"\n    static let other = "no"/"a"\n    static let other = "b"/' 2>&1)"
assert_contains "a literal aim and a regex aim can be given together" "${OUT}" "CAUGHT"

# And the mirror, so the mixing cannot have quietly made both readings the same: the same alternation
# handed to the LITERAL flag names no line and is refused.
printf '%s\n' "${TWO_LINE_SUBJECT}" > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" \
  --at 'static let answer' --at 'let other|absent' "${SUBJECT}" \
  's/"yes"\n    static let other = "no"/"a"\n    static let other = "b"/' 2>&1)"
assert_contains "the same alternation given literally is refused" "${OUT}" "LANDED ELSEWHERE"

# `--at-regex` after the expression is the same misplaced flag `--at` already is (#2993), and has to be
# refused the same way rather than falling into the trailing scopes.
printf 'struct Subject {\n    static let answer = "yes"\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' --at-regex 'answer' 2>&1)"
assert_contains "--at-regex after the expression is refused too" "${OUT}" "MISPLACED FLAG"
assert_contains "and names the argument it refused" "${OUT}" "--at-regex"

# --- #3080: an unapplied substitution names the character that is being read as a regex ---------------
# The expression is genuinely a perl expression and stays one, but the refusal used to leave the reader to
# spot the metacharacter. `PERL VARIABLE` (#2995) already names `$0`; this does the same for the ones that
# make a pattern unmatchable. It only speaks when it has EVIDENCE: the search text, read literally, really
# is in the file, so "it is being read as a regex" is measured rather than guessed.
printf 'struct Subject {\n    static let answer = value(from: other)\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/value(from: other)/nothing/' 2>&1)"
STATUS=$?
assert_contains "an unapplied substitution is still refused" "${OUT}" "NOT APPLIED"
assert_contains "and says the text is there literally" "${OUT}" "literally"
assert_contains "and names the character to escape" "${OUT}" "("
assert_equals "and does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# It must not accuse when the text is simply absent, which is the ordinary typo and a different problem.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/nowhere(in: this)/x/' 2>&1)"
assert_contains "a search text that is genuinely absent is still NOT APPLIED" "${OUT}" "NOT APPLIED"
assert_not_contains "and is not blamed on escaping" "${OUT}" "literally"

# --- a MENTION of NOTHING RAN is not a run that executed nothing ------------------------------------
# A Swift test failure prints the source around it, comments included, so a file whose comment mentions
# the phrase puts it in the log. This repo has several, because the rule is written down in AGENTS.md and
# cited in tests. Before this, every mutation touching such a file reported NOTHING RAN while the suite
# had really run and really gone red, turning a CAUGHT into a refusal (L156). Measured 2026-08-21.
write_subject
MENTION_RUNNER="$(make_runner mention 1 "  | > // this repo already refuses it at three other entry points (\`NOTHING RAN\` in run-tests-locked.sh)
${X} Test \"the row draws a quiet exit\" failed after 0.01 seconds with 1 issue.
${X} Test run with 12 tests in 2 suites failed after 0.1 seconds with 1 issue.")"
OUT="$(OVERTURE_MUTATE_RUNNER="${MENTION_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
STATUS=$?
assert_contains "a log that merely MENTIONS the phrase is judged on the run" "${OUT}" "CAUGHT"
assert_not_contains "and is not refused as an empty run" "${OUT}" "NOTHING RAN - the run executed no tests"
assert_equals "and exits 0" "0" "${STATUS}"

# And a run that genuinely executed nothing is still refused, so the anchoring did not simply switch the
# check off (L1).
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${EMPTY_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a run that really executed nothing is still refused" "${OUT}" "NOTHING RAN"
assert_not_contains "and is never reported as caught" "${OUT}" "CAUGHT"

# --- #3157: a SURVIVED says whether the needle is still in the file --------------------------------
# Four source-text guards written on 2026-08-23 passed while the code they guard was deleted, all the
# same shape: the needle also occurs somewhere harmless in the SAME file, so the assertion is answered by
# that second occurrence rather than by the code (L135). `DetachConversationCopy.control` is a PREFIX of
# `.controlHelp` on the next line (#2797); `DraftedDeadEndCopy.line` survived inside an `if false` branch
# (#2674); `onConnectGmail: connectGmail` reaches ArchiveView as well as FollowUpsView (#2967). Every one
# was found by hand, after the SURVIVED, by grepping the file. mutate.sh already holds both the file and
# the needle, so it can say it.
printf 'struct Subject {\n    let a = Copy.control\n    let b = Copy.controlHelp\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/Copy\.control/Copy.gone/' 2>&1)"
assert_contains "a survived mutation is still survived" "${OUT}" "SURVIVED"
assert_contains "and says the needle is still in the file" "${OUT}" "still in Subject.swift"
assert_contains "and names the line it is still on" "${OUT}" "line 3"

# The other half, so silence never stands for a measurement (L11): a needle that genuinely went away is
# RULED OUT in one line, rather than being left to look like the unchecked case.
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"yes"/"no"/' 2>&1)"
assert_contains "a survived mutation whose needle went away is still survived" "${OUT}" "SURVIVED"
assert_contains "and rules the second occurrence out" "${OUT}" "no longer occurs anywhere in Subject.swift"
assert_not_contains "and does not claim it is still there" "${OUT}" "still in Subject.swift"

# And the third state gets its own words. An expression whose search half cannot be read as literal text
# was never measured, and an unmeasured check must not read as a passed one.
printf 'struct Subject {\n    static let answer = "yes"\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${GREEN_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/"y.s"/"no"/' 2>&1)"
assert_contains "a survived mutation with an unreadable needle is still survived" "${OUT}" "SURVIVED"
assert_contains "and says the recurrence could not be checked" "${OUT}" "could NOT be checked"
assert_not_contains "and claims nothing either way" "${OUT}" "no longer occurs anywhere"

# It is a reading of a SURVIVED and nothing else: a CAUGHT is already explained by the test that went red,
# and a note there would be noise on the ordinary outcome.
printf 'struct Subject {\n    let a = Copy.control\n    let b = Copy.controlHelp\n}\n' > "${SUBJECT}"
OUT="$(OVERTURE_MUTATE_RUNNER="${RED_RUNNER}" "${MUTATE}" "${SUBJECT}" 's/Copy\.control/Copy.gone/' 2>&1)"
assert_contains "a caught mutation is still caught" "${OUT}" "CAUGHT"
assert_not_contains "and carries no recurrence note" "${OUT}" "still in Subject.swift"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all mutate.sh checks passed"
