#!/usr/bin/env bash
set -uo pipefail

# #2755: break the code on purpose and watch the suite go red.
#
# Every guard in this repo is supposed to have been SEEN to fail (L1), and roughly 1600 of the suite's
# declarations are source-text guards, so this is done constantly. There was no tool for it, so each
# attempt was hand-rolled, and the hand-rolled version is easy to get wrong in ways that report success.
#
# Both of the ways it actually went wrong in one session are what this script exists to make impossible:
#
#   1. A perl substitution matched NOTHING. The file was untouched, the run that followed was green for
#      the most ordinary reason there is, and the report read as "the guard survived" rather than "the
#      mutation never happened" (L100).
#   2. A run was piped through a command that was not on PATH and exited 0 having tested nothing, so the
#      pipe's status was read instead of the runner's (AGENTS.md's own warning, #2502).
#
# Ten outcomes, kept apart on purpose, because collapsing any two of them is how this lies:
#
#   CAUGHT            the mutation applied where it was aimed and the suite went red. The guard is real.
#   SURVIVED          the mutation applied and the suite stayed green. The guard protects nothing.
#   NOT APPLIED       the expression matched nothing. Says nothing about any guard.
#   NOTHING RAN       the run executed no tests. Also says nothing about any guard (L98).
#   LANDED ELSEWHERE  the mutation applied somewhere other than where it was aimed (#2820).
#   NOT PROOF         nearly everything in the run went red, so the instrument misfired (#2820).
#   NO RUNNER         the runner is not something this shell can run, so nothing happened (#2846).
#   DID NOT BUILD     the code stopped compiling, so no test ran (#2995, #2859). Says nothing either.
#   MISPLACED FLAG    a flag was passed where a test scope goes, so it was never read (#2993).
#   PERL VARIABLE     the expression carries an unescaped perl variable, which is almost never meant.
#
# The last three are the three ways a MALFORMED INSTRUCTION used to be reported as a verdict. Each was
# measured: a build failure was folded into CAUGHT ("the compiler caught it"), which is true of a
# mutation whose point is that the code stops type-checking and false of every other one, where it means
# the guard under test never ran at all. A `--at` written after the expression fell into the trailing
# scopes, reached xcodebuild as an unrecognised option, and sent the runner to the PURE suite, so the aim
# check was off and a targeted proof became a full-suite run. And `$0` left unescaped in a replacement is
# perl's own program-name variable, so it interpolates away and produces code that does not compile,
# which is how the first of those was produced twice in one session (#2988).
#
# The last two are #2820, and they are the ones that lied in the CAUGHT direction, which is the worse
# one: roughly 1600 of the suite's declarations are source-text guards and CAUGHT is the verdict quoted
# as proof of each. Measured 2026-08-16: an expression using a pipe as its perl delimiter reached the
# regex engine as an alternation with an empty branch, matched the EMPTY STRING at offset 0, prepended
# text ahead of a shebang, and the file stopped parsing. Every fixture went red and this said CAUGHT.
#
# So, after applying, it confirms the change landed where it was aimed before it will run anything:
#
#   * A match that consumed NO CHARACTERS landed at an arbitrary offset rather than on any code, so it
#     can never be evidence about a guard whatever the suite then does. This needs nothing declared and
#     catches the incident above exactly, where a diff-based check cannot: the prepend happened on the
#     first line, so the diff reads as an ordinary one-line change.
#   * `--at <pattern>` declares the aim explicitly, and every line the mutation touched must be one the
#     pattern matches. Nothing else can tell the tool where a mutation was SUPPOSED to land.
#
# And a run in which nearly everything went red is treated as evidence the instrument misfired, not as
# proof. A SCOPED run is exempt: a scope naming the one suite holding the guard is expected to go
# entirely red, and a rule condemning that would fire on the common case and be switched off (L93).
#
# Usage:
#   scripts/mutate.sh [--at <pattern>] <file> <perl-expression> [test-scope ...]
#
# Examples:
#   scripts/mutate.sh mac/Overture/Domain/RunSlot.swift 's/return .free/return .taken/' \
#       -only-testing:OvertureTests/RunSlotTests
#   scripts/mutate.sh scripts/run-shell-fixtures.sh 's/fixture_asserted_something/false/'
#   scripts/mutate.sh --at 'func nextPromptDate' mac/Overture/Domain/PostEventPrompt.swift 's/>=/>/'

usage() {
  cat <<'USAGE'
usage: scripts/mutate.sh [--at <pattern>] <file> <perl-expression> [test-scope ...]

Applies the perl expression to the file, runs the suite, restores the file, and reports whether the
mutation was CAUGHT (the suite went red, so the guard is real) or SURVIVED (it stayed green, so the
guard protects nothing).

Refuses, rather than reporting a result, when the expression matched nothing, when it landed somewhere
other than where it was aimed, when the run executed no tests, when nearly everything in the run went
red, when the runner is not something this shell can run, when the code stopped compiling, or when the
instruction itself is malformed: every one of those looks like a result and means nothing about any
guard.

  --at <pattern>      an extended regex naming the lines the mutation is aimed at. Every line the
                      mutation touches must match it, or the run is refused as LANDED ELSEWHERE.
  --breaks-the-build  this mutation is MEANT to stop the code compiling, so the compiler refusing it is
                      the guard firing. Without this, a run that did not build is refused as DID NOT
                      BUILD rather than reported as any verdict.
  <file>              the file to break, relative to the repo root or absolute
  <perl-expression>   passed to `perl -0pi -e`, so it sees the whole file at once
  [test-scope ...]    optional, passed straight through to the test runner
                      (e.g. -only-testing:OvertureTests/RunSlotTests)

  OVERTURE_MUTATE_RUNNER   the command to run instead of the Swift suite. The seam this script's own
                           fixture uses; also how to drive the shell fixtures or vitest instead. ONE
                           command, carrying no arguments of its own: to drive something that needs
                           them, point this at a small executable wrapper script. A value this shell
                           cannot run refuses the run as NO RUNNER rather than reporting a verdict.
USAGE
}

# The declared aim, empty when none was given. Read before the positional arguments, so `--at` cannot be
# mistaken for the file (the fixture proved that first: without this the refusal read "no file at --at").
AIM=""
# #2995: whether the compiler refusing this IS the finding. Declared, never inferred: the two cases look
# identical from here and only the author knows which one this is.
BREAKS_THE_BUILD="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --breaks-the-build)
      BREAKS_THE_BUILD="true"
      shift
      ;;
    --at)
      AIM="${2:-}"
      shift 2
      ;;
    --at=*)
      AIM="${1#--at=}"
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  usage
  exit 2
fi

TARGET="$1"; shift
EXPRESSION="$1"; shift

if [[ ! -f "${TARGET}" ]]; then
  echo "mutate: no file at ${TARGET}"
  exit 2
fi

# #2993: a flag sitting where a test scope goes was never read as a flag.
#
# The usage is `[--at <pattern>] <file> <perl-expression> [test-scope ...]`, and the parse above only
# looks BEFORE the positionals, which is right: `--at` must not be mistaken for the file. The cost was
# that a `--at` written after the expression fell into the trailing scopes, was forwarded to
# run-tests-locked.sh and from there to xcodebuild, which fails on the unrecognised option, and the
# runner then fell back to the PURE suite, which takes no scope at all. Two things went silently: the
# aim check was never active, so #2820's protection was off, and a proof that should take seconds ran
# the whole pure suite. Measured 2026-08-19 across several proofs during #2983 and #2988.
#
# `-only-testing:` is the one shape a Swift scope takes, so anything starting with `--` here is a
# misplaced flag rather than a scope. Refused rather than forwarded, and refused in a register that says
# nothing about any guard.
for scope in "$@"; do
  if [[ "${scope}" == --* ]]; then
    echo "MISPLACED FLAG - ${scope} was passed where a test scope goes, so it was never read."
    echo
    echo "  Flags come BEFORE the file: scripts/mutate.sh [--at <pattern>] [--breaks-the-build] \\"
    echo "      <file> <perl-expression> [test-scope ...]"
    echo
    echo "  Nothing was mutated and nothing was run. Forwarded to the runner it reaches xcodebuild as an"
    echo "  unrecognised option, which fails the run and sends it to the PURE suite, so the aim check is"
    echo "  off and the scope you asked for is not the scope that runs."
    exit 2
  fi
done

# #2995: a perl variable left unescaped in the expression.
#
# In a `s///` replacement `$0` is perl's own program-name variable, so `isCandidate($0, ...)` interpolates
# away and produces code that does not compile. Measured twice in one session on #2988, and both times the
# result was reported as CAUGHT for a guard that had never run. `$&` is the same trap. `$1` through `$9`
# are only flagged when the expression has no capture group for them to refer to, since with one they are
# ordinary and correct.
unescaped_perl_variable() {
  local expression="$1"
  if [[ "${expression}" =~ (^|[^\\])(\$[0&]) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi
  local without_escaped_parens="${expression//\\(/}"
  if [[ "${without_escaped_parens}" != *"("* && "${expression}" =~ (^|[^\\])(\$[1-9]) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

if PERL_VARIABLE="$(unescaped_perl_variable "${EXPRESSION}")"; then
  echo "PERL VARIABLE - ${EXPRESSION} carries an unescaped ${PERL_VARIABLE}, which perl reads as its own."
  echo
  echo "  Nothing was mutated and nothing was run. ${PERL_VARIABLE} interpolates away, so the text that"
  echo "  lands is not the text you wrote, and what usually follows is code that does not compile."
  echo "  To put the characters ${PERL_VARIABLE} into the file, escape it: write \\${PERL_VARIABLE}."
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${OVERTURE_MUTATE_RUNNER:-${REPO_ROOT}/mac/scripts/run-tests-locked.sh}"

# The runner has to be one command this shell can actually run, and that is proved BEFORE anything is
# mutated (#2846).
#
# What went wrong: the runner is invoked as a single command word, so the seam this script's own usage
# text advertises ("also how to drive the shell fixtures or vitest instead") cannot be given arguments.
# Set it to `bash scripts/lib/some.test.sh`, which is the natural thing to reach for, and the shell
# looks for a FILE of that whole name, does not find one, exits 127, and NOTHING RUNS. Measured
# 2026-08-16 while proving the guards for #2818, where this then printed:
#
#   CAUGHT - the suite went red, so something really is guarding this.
#
# That is the same class as the two outcomes #2820 added, and the worst possible direction: CAUGHT is
# the verdict quoted as proof for roughly 1,700 source-text guards in this suite. NOTHING RAN cannot
# catch it either, because that is decided from a total the runner never printed. So it is caught here,
# before the file is touched, and refused rather than reported as any verdict at all.
#
# It stays ONE WORD rather than being split into an argument list, which was tried first and is worse:
# this repo's own default runner path contains a space (the checkout lives under "Photography Assets"),
# so splitting on whitespace breaks the ordinary case outright. A runner needing arguments is a wrapper
# script, which is what the message says.
if ! command -v "${RUNNER}" >/dev/null 2>&1; then
  echo "NO RUNNER - nothing was mutated and nothing was run."
  echo "  The runner is ${RUNNER:-empty}, which is not one command this shell can run."
  echo
  echo "  It is passed as a single command, so it cannot carry arguments. To drive something that needs"
  echo "  them (a shell fixture, vitest), point OVERTURE_MUTATE_RUNNER at a small executable wrapper"
  echo "  script that runs it."
  echo
  echo "  Refused rather than reported, because a runner that cannot start exits non-zero having tested"
  echo "  nothing, and this script would otherwise call that CAUGHT (#2846)."
  exit 2
fi

# How many characters the expression's LAST match consumed, asked of perl itself on a COPY (#2820).
# Prints the length, or "unknown" when it could not be measured.
#
# Why perl rather than the diff: the misfire this exists for prepended text at offset 0, on the same line
# as the code, so the diff reads as an ordinary one-line change and no textual rule separates it from a
# real mutation. What separates it is that the match consumed NOTHING, which only the regex engine knows.
#
# The capture sits at the same block level as the substitution because perl's match variables are
# dynamically scoped to the enclosing BLOCK: measured 2026-08-16, reading $& after `do { s/wor/WOR/ }`
# gives undef while the same read on the next line of the same block gives "wor". That also means a
# multi-statement expression will not compile here, which is why this reports "unknown" rather than
# refusing: it is an extra reading, and the declared `--at` aim is the check that does not guess.
probe_matched_length() {
  local file="$1" expression="$2"
  local prog report copy status out
  prog="$(mktemp)"; report="$(mktemp)"; copy="$(mktemp)"
  cp "${file}" "${copy}"
  {
    echo 'my ($f, $r) = @ARGV;'
    echo 'open my $in, "<", $f or exit 3;'
    echo 'my $src = do { local $/; <$in> };'
    echo 'close $in;'
    echo '$_ = $src;'
    printf 'my $n = ( %s );\n' "${expression}"
    echo 'my $len = defined($&) ? length($&) : -1;'
    echo 'open my $out, ">", $r or exit 3;'
    echo 'print $out "$len\n";'
    echo 'close $out;'
  } > "${prog}"
  perl "${prog}" "${copy}" "${report}" >/dev/null 2>&1
  status=$?
  out="$(cat "${report}" 2>/dev/null)"
  rm -f "${prog}" "${report}" "${copy}"
  if [[ "${status}" -ne 0 || -z "${out}" ]]; then
    echo "unknown"
    return 0
  fi
  echo "${out}"
}

# The ORIGINAL line numbers a mutation touched, one per line. Read off diff's own change commands, whose
# left-hand range is always stated in the original file's numbering. An append (`Na M`) happens BETWEEN
# two original lines, so both sides of the seam are named: an insertion is aimed at a place, not a line.
mutation_touched_original_lines() {
  local before="$1" after="$2"
  diff "${before}" "${after}" | awk '
    /^[0-9]/ {
      left = $0
      sub(/[acd].*$/, "", left)
      split(left, r, ",")
      start = r[1] + 0
      end = (r[2] == "" ? start : r[2] + 0)
      if ($0 ~ /^[0-9,]+a/) {
        if (start > 0) print start
        print start + 1
      } else {
        for (i = start; i <= end; i++) print i
      }
    }
  ' | sort -n -u
}

# "<failed> <total>" for the run, read off whichever runner's OWN summary the log carries, or nothing
# when neither shape is there. Both shapes are read because which one turns up depends on the runner
# given, and the incident that motivated this was on the shell fixtures rather than the Swift suite
# (L147: a guard seen to fail on one chosen shape has only been shown to work on that shape).
#
# The Swift half is handed the count of NAMED failing tests rather than counting them again, so there is
# one extraction of those names in this file rather than two that can drift apart.
#
# The shell half counts only FAIL lines naming a `.test.sh` path, which is what run-shell-fixtures.sh
# prints per failing fixture; a fixture's own failing assertions print `FAIL - <description>` and must
# not be counted as fixtures, or one chatty fixture would read as the whole run collapsing.
mutation_failure_breadth() {
  local log="$1" named_failures="$2" total
  total="$(grep -oE 'Test run with [0-9]+ tests? in' "${log}" 2>/dev/null | tail -n 1 | grep -oE '[0-9]+' | head -n 1)"
  if [[ -n "${total}" ]]; then
    echo "${named_failures} ${total}"
    return 0
  fi
  total="$(grep -oE 'Running [0-9]+ shell fixture' "${log}" 2>/dev/null | tail -n 1 | grep -oE '[0-9]+' | head -n 1)"
  if [[ -n "${total}" ]]; then
    echo "$(grep -cE '^FAIL - .*\.test\.sh$' "${log}" 2>/dev/null) ${total}"
    return 0
  fi
  return 1
}

# The saved copy and the restore. A TRAP rather than a line at the end, because the case that matters is
# the one where this script does not reach its end: a killed run, a Ctrl-C, an error under `set -e`. A
# restore that only happens on the happy path leaves the repo holding a deliberate defect, which is the
# single worst thing this tool could do.
BACKUP="$(mktemp)"
cp "${TARGET}" "${BACKUP}"
restore() {
  cp "${BACKUP}" "${TARGET}"
  rm -f "${BACKUP}"
}
trap restore EXIT INT TERM

BEFORE="$(cksum < "${TARGET}")"
perl -0pi -e "${EXPRESSION}" "${TARGET}"
AFTER="$(cksum < "${TARGET}")"

# Compared by CONTENT, so an expression that rewrites a line to itself counts as no change too.
if [[ "${BEFORE}" == "${AFTER}" ]]; then
  echo "NOT APPLIED - the expression changed nothing in ${TARGET}"
  echo "  ${EXPRESSION}"
  echo
  echo "  Nothing was run, because there is nothing to learn from it: an unapplied mutation leaves the"
  echo "  suite green for the ordinary reason, and reading that as a surviving guard is how a vacuous"
  echo "  guard gets signed off (L100)."
  exit 2
fi

echo "mutating ${TARGET}"
echo "  ${EXPRESSION}"
diff <(cat "${BACKUP}") "${TARGET}" | sed 's/^/  /' || true
echo

# --- did it land where it was aimed? (#2820) --------------------------------------------------------
# Asked BEFORE the runner starts, so a misfire costs no suite run and, more importantly, can never reach
# the point where a red run would be read as a guard firing.
MATCHED_LENGTH="$(probe_matched_length "${BACKUP}" "${EXPRESSION}")"
if [[ "${MATCHED_LENGTH}" == "0" ]]; then
  echo "LANDED ELSEWHERE - the expression matched the empty string, so it changed no existing text."
  echo "  ${EXPRESSION}"
  echo
  echo "  Nothing was run. A match that consumes no characters lands at whatever offset the engine"
  echo "  reached first (usually the very start of the file) rather than on the code you named, so the"
  echo "  suite's verdict afterwards is about a file broken somewhere else entirely."
  echo "  The usual cause is a delimiter: in s|a\\|b|c| the \\| reads as an escaped DELIMITER and reaches"
  echo "  the regex as a bare pipe, making an alternation with an empty branch. Re-run with / delimiters."
  exit 2
fi

if [[ -n "${AIM}" ]]; then
  AIMED_LINES="$(grep -nE -- "${AIM}" "${BACKUP}" 2>/dev/null | cut -d: -f1)"
  TOUCHED_LINES="$(mutation_touched_original_lines "${BACKUP}" "${TARGET}")"
  OUTSIDE_LINES=""
  while IFS= read -r touched_line; do
    [[ -z "${touched_line}" ]] && continue
    if ! printf '%s\n' "${AIMED_LINES}" | grep -qx -- "${touched_line}"; then
      OUTSIDE_LINES="${OUTSIDE_LINES}${touched_line} "
    fi
  done <<< "${TOUCHED_LINES}"

  if [[ -n "${OUTSIDE_LINES}" ]]; then
    echo "LANDED ELSEWHERE - the mutation touched line(s) ${OUTSIDE_LINES}, which --at does not name."
    echo "  --at ${AIM}"
    echo
    echo "  Nothing was run. The suite's verdict would be about whatever this broke, not about the guard"
    echo "  on the line you aimed at, and a red run there reads exactly like the guard firing."
    exit 2
  fi
  if [[ -z "${TOUCHED_LINES}" ]]; then
    echo "LANDED ELSEWHERE - the mutation touched no line that --at names."
    echo "  --at ${AIM}"
    exit 2
  fi
fi

# #2755: for the fixture only. There is no way to observe "restored after being killed" from outside
# without a kill, and a restore written at the end of the script would pass every other test in that
# fixture while failing exactly here.
if [[ -n "${OVERTURE_MUTATE_SELF_KILL:-}" ]]; then
  kill -TERM $$
  sleep 5
fi

# The runner's own status, captured directly. NOT through a pipe: `runner | tail -5` reports tail's
# status, so a runner that died instantly and printed nothing reads as a clean pass (#2502). The output
# goes to a file and is printed afterwards.
RUN_LOG="$(mktemp)"
"${RUNNER}" "$@" > "${RUN_LOG}" 2>&1
RUN_STATUS=$?

sed 's/^/  | /' "${RUN_LOG}" | tail -n 25
echo

# How much actually ran, quoted back on a SURVIVED. A scope naming a suite that exists but does not hold
# the guard under test runs a real suite, passes, and reads as a surviving guard, and no gate can see it:
# something did run. The count is the one thing that makes it visible to a person. Found by making that
# exact mistake with this script (a test in ProbePaceWiringGuardTests, scoped to ProbeDurationHistoryTests).
SHAPE="$(grep -oE "Test run with [0-9]+ tests? in [0-9]+ suites?" "${RUN_LOG}" | tail -n 1 || true)"

# A run that executed nothing is its own outcome. It is the one most likely to be believed, because it
# arrives looking exactly like a suite with no complaints (L98), and here it would be read as a guard
# that survived, which is the opposite of what happened.
if grep -q "NOTHING RAN" "${RUN_LOG}"; then
  echo "NOTHING RAN - the run executed no tests, so this says nothing about any guard."
  echo "  Check the scope: $*"
  rm -f "${RUN_LOG}"
  exit 2
fi

# Which tests went red, from the runner's own lines, so the report names them rather than saying "some".
FAILED="$(grep -oE '✘ Test "[^"]+"|✘ Test [A-Za-z_][A-Za-z0-9_]*\(\)' "${RUN_LOG}" | sed 's/✘ Test //' | sort -u || true)"

# How MUCH went red, read before the log is removed (#2820). A mutation that breaks a file badly enough
# makes every check fail, and a run in which everything went red is indistinguishable from one in which
# the guard under test fired.
NAMED_FAILURES="$(printf '%s' "${FAILED}" | grep -c . )"
BREADTH="$(mutation_failure_breadth "${RUN_LOG}" "${NAMED_FAILURES}" || true)"
BREADTH_FAILED=""
BREADTH_TOTAL=""
NEAR_TOTAL="false"
if [[ -n "${BREADTH}" ]]; then
  BREADTH_FAILED="${BREADTH%% *}"
  BREADTH_TOTAL="${BREADTH##* }"
  if [[ "${BREADTH_TOTAL}" -gt 1 && $(( BREADTH_FAILED * 10 )) -ge $(( BREADTH_TOTAL * 9 )) ]]; then
    NEAR_TOTAL="true"
  fi
fi
# Did the run fail to COMPILE? (#2995, #2859)
#
# The tell is the compiler's own file:line:column shape, xcodebuild's build-commands banner, or the
# runner's own sentence, NEVER the bare word "error": every run of this suite prints CoreData noise
# carrying "error:". The same three tells run-tests-locked.sh reads (#1465), because it is the runner
# this script is pointed at by default.
#
# BOTH other halves are required with it, and they are what keep this from stealing a real CAUGHT: no
# test was NAMED, and no run total was printed. A build failure cannot produce either, because nothing
# ran; a genuine test failure that happens to quote a compiler-shaped line produces at least one.
DID_NOT_BUILD="false"
if [[ "${RUN_STATUS}" -ne 0 && -z "${FAILED}" && -z "${BREADTH}" ]]; then
  if grep -q '^The following build commands failed:' "${RUN_LOG}" 2>/dev/null \
     || grep -q 'the code did not COMPILE' "${RUN_LOG}" 2>/dev/null \
     || grep -qE '^[^[:space:]].*:[0-9]+:[0-9]+: (fatal )?error: ' "${RUN_LOG}" 2>/dev/null; then
    DID_NOT_BUILD="true"
  fi
fi

rm -f "${RUN_LOG}"

if [[ "${RUN_STATUS}" -ne 0 ]]; then
  # The mutation stopped the code compiling. Whether that is the FINDING or the instrument misfiring is
  # not something this can read off the output: it depends entirely on what the author was trying to
  # prove, so it is declared with --breaks-the-build and never inferred.
  if [[ "${DID_NOT_BUILD}" == "true" ]]; then
    if [[ "${BREAKS_THE_BUILD}" == "true" ]]; then
      echo "CAUGHT - the compiler refused it, which is what you declared this mutation would do."
      echo "  ${EXPRESSION}"
      exit 0
    fi
    echo "DID NOT BUILD - the code stopped compiling, so no test ran and no guard was exercised."
    echo "  ${EXPRESSION}"
    echo
    echo "  Refused rather than reported. A build failure used to count as CAUGHT, on the reasoning that"
    echo "  the compiler caught something, which is true only of a mutation whose POINT is that the code"
    echo "  stops type-checking. For an ordinary behavioural mutation it means the INSTRUCTION was"
    echo "  malformed and the guard under test never ran at all (#2995)."
    echo
    echo "  If breaking the build IS the proof (a guard the type system enforces), say so with"
    echo "  --breaks-the-build and it will be judged as a catch."
    exit 2
  fi
  # A SCOPED run is exempt and deliberately so: a scope naming the one suite that holds the guard is
  # expected to go entirely red, and that is the ordinary proof shape. Condemning it would fire on the
  # common case and be switched off within a day (L93).
  if [[ "${NEAR_TOTAL}" == "true" && $# -eq 0 ]]; then
    echo "NOT PROOF - ${BREADTH_FAILED} of ${BREADTH_TOTAL} went red, so the instrument misfired."
    echo "  ${EXPRESSION}"
    echo
    echo "  A whole run going red is what a broken FILE looks like, not what one guard firing looks like."
    echo "  Read the diff above: if the mutation damaged the file outside the line it was aimed at, this"
    echo "  says nothing about any guard. Re-run it with --at naming the lines you meant to break, or"
    echo "  with a scope, and see the specific test go red."
    exit 2
  fi
  echo "CAUGHT - the suite went red, so something really is guarding this."
  if [[ -n "${FAILED}" ]]; then
    echo "  Red:"
    # Line by line, NOT `printf '%s\n' ${FAILED}`: a test name here is a sentence with spaces in it, and
    # an unquoted expansion word-splits it into one line per word. Found by running this script against a
    # real suite, which reported eleven "failing tests" that were the words of two.
    printf '%s\n' "${FAILED}" | sed 's/^/    /' 
  else
    # #2995: this no longer says "a build failure counts". A build failure is DID NOT BUILD above, so
    # what is left here is a run that failed, named no test, and does not look like a build failure,
    # which is genuinely unexplained and must read that way rather than borrowing a reason.
    echo "  The run failed without naming a test, and its output does not carry a compiler error."
  fi
  # Say when the breadth could not be read rather than letting silence stand for "and only that failed".
  # An unmeasured breadth and a narrow one look identical from this line otherwise (L11).
  if [[ -z "${BREADTH}" ]]; then
    echo "  This runner printed no total, so how much of the run went red could not be measured."
  fi
  exit 0
fi

echo "SURVIVED - the suite stayed green with the code broken, so nothing is guarding this."
echo "  A guard that cannot go red is protecting nothing, and reads exactly like one that works (L1)."
if [[ -n "${SHAPE}" ]]; then
  echo "  ${SHAPE}"
fi
if [[ $# -gt 0 ]]; then
  echo
  echo "  Before believing it: was the scope the right one? A scope naming a suite that EXISTS but does"
  echo "  not hold the guard you are testing runs happily and reports exactly this. NOTHING RAN cannot"
  echo "  catch that, because something did run. Check the count above against what you expected."
  echo "  Scope: $*"
fi
exit 1
