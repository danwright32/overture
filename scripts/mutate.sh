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
# Four outcomes, kept apart on purpose, because collapsing any two of them is how this lies:
#
#   CAUGHT        the mutation applied and the suite went red. The guard is real.
#   SURVIVED      the mutation applied and the suite stayed green. The guard protects nothing.
#   NOT APPLIED   the expression matched nothing. Says nothing about any guard.
#   NOTHING RAN   the run executed no tests. Also says nothing about any guard (L98).
#
# Usage:
#   scripts/mutate.sh <file> <perl-expression> [test-scope ...]
#
# Examples:
#   scripts/mutate.sh mac/Overture/Domain/RunSlot.swift 's/return .free/return .taken/' \
#       -only-testing:OvertureTests/RunSlotTests
#   scripts/mutate.sh scripts/run-shell-fixtures.sh 's/fixture_asserted_something/false/'

usage() {
  cat <<'USAGE'
usage: scripts/mutate.sh <file> <perl-expression> [test-scope ...]

Applies the perl expression to the file, runs the suite, restores the file, and reports whether the
mutation was CAUGHT (the suite went red, so the guard is real) or SURVIVED (it stayed green, so the
guard protects nothing).

Refuses, rather than reporting a result, when the expression matched nothing or the run executed no
tests: both of those look exactly like a passing suite and mean nothing about any guard.

  <file>              the file to break, relative to the repo root or absolute
  <perl-expression>   passed to `perl -0pi -e`, so it sees the whole file at once
  [test-scope ...]    optional, passed straight through to the test runner
                      (e.g. -only-testing:OvertureTests/RunSlotTests)

  OVERTURE_MUTATE_RUNNER   the command to run instead of the Swift suite. The seam this script's own
                           fixture uses; also how to drive the shell fixtures or vitest instead.
USAGE
}

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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${OVERTURE_MUTATE_RUNNER:-${REPO_ROOT}/mac/scripts/run-tests-locked.sh}"

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
rm -f "${RUN_LOG}"

if [[ "${RUN_STATUS}" -ne 0 ]]; then
  echo "CAUGHT - the suite went red, so something really is guarding this."
  if [[ -n "${FAILED}" ]]; then
    echo "  Red:"
    # Line by line, NOT `printf '%s\n' ${FAILED}`: a test name here is a sentence with spaces in it, and
    # an unquoted expansion word-splits it into one line per word. Found by running this script against a
    # real suite, which reported eleven "failing tests" that were the words of two.
    printf '%s\n' "${FAILED}" | sed 's/^/    /' 
  else
    echo "  The run failed without naming a test (a build failure counts: the compiler caught it)."
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
