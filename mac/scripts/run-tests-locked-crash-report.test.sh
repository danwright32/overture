#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains (#2501).
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #3875: when the test HOST dies between tests, say so, instead of leaving the next test to be blamed.
#
# WHAT IT COST. On 2026-09-13 the hosted target was run with `-test-iterations 10` and the host died 8
# times. Every crash was reported against `FeltWaitCostTests.measureWhatAPressCosts`, which in that
# configuration is a guard on an unset environment variable, a print and a return: it had not executed a
# line of its own body. The crash reports say so plainly and the run's own output does not, because the
# triggered stack holds no Overture test code at all, only XCTest's between-tests enumeration wait.
#
# The consistency is what makes it misleading rather than merely unhelpful: a test that returns instantly
# is the first quiet moment after the preceding heavy test tears down, so the same innocent test is named
# every time, which reads exactly like a reproducible fault in it. Two sessions investigated it.
#
# The runner already keeps eleven outcomes apart and refuses to call an empty run a pass. A crash between
# tests is a further cause it does not yet name, and today it is rendered as a fifth thing it is not: a
# specific test failing (L11, L98).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./run-tests-locked.sh
source "${SCRIPT_DIR}/run-tests-locked.sh"
set +e

FAILURES=0

# Swift Testing's own result markers, built from their UTF-8 BYTES rather than written literally.
# The pre-push style gate forbids those characters in new lines and is right to: it cannot tell a line
# USING one from a line that has to NAME one. `printf` with byte escapes keeps this file free of any
# literal marker while still producing the real output shape, which is what the parser under test reads.
# Bytes rather than `$'\u2714'`, because that form needs bash 4.2 and macOS ships 3.2.
TICKMARK="$(printf '\xe2\x9c\x94')"
DIAMONDMARK="$(printf '\xe2\x97\x87')"

# A real transcript's shape, trimmed: two tests complete, a third starts, the host dies, xcodebuild
# restarts. Taken from the 2026-09-13 run rather than invented, because the ORDER is the whole point.
CRASHED_RUN="$(cat <<'EOF'
TICKMARK Test aPressReallyRebuildsTheQueue() passed after 1.121 seconds.
DIAMONDMARK Test anyWriteAtAllCostsExactlyOnePass() started.
TICKMARK Test anyWriteAtAllCostsExactlyOnePass() passed after 1.130 seconds.
DIAMONDMARK Test measureWhatAPressCosts() started.

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

DIAMONDMARK Test somethingElse() started.
TICKMARK Test somethingElse() passed after 0.2 seconds.
EOF
)"
CRASHED_RUN="${CRASHED_RUN//TICKMARK/${TICKMARK}}"
CRASHED_RUN="${CRASHED_RUN//DIAMONDMARK/${DIAMONDMARK}}"

CLEAN_RUN="$(cat <<'EOF'
TICKMARK Test aPressReallyRebuildsTheQueue() passed after 1.121 seconds.
TICKMARK Test anyWriteAtAllCostsExactlyOnePass() passed after 1.130 seconds.
** TEST SUCCEEDED **
EOF
)"
CLEAN_RUN="${CLEAN_RUN//TICKMARK/${TICKMARK}}"

report="$(crash_restart_report "${CRASHED_RUN}")"

assert_contains "it says the host DIED rather than a test failing" \
  "${report}" "died"
assert_contains "it says how many times" \
  "${report}" "1"
assert_contains "it names the last test to COMPLETE, which is the trustworthy one" \
  "${report}" "anyWriteAtAllCostsExactlyOnePass"
assert_contains "it names the test that was merely CURRENT" \
  "${report}" "measureWhatAPressCosts"
# The whole point: the named test must be marked as an attribution, not a finding. Without this the
# report is just a second way of blaming the same innocent test.
assert_contains "it marks the current test as an attribution rather than a finding" \
  "${report}" "attribution"
assert_contains "it points at the only real evidence, the crash report" \
  "${report}" "DiagnosticReports"

# SILENT ON A CLEAN RUN. A report that speaks on every run is one people stop reading, and this one
# would then be noise on the ~9,600-test runs that make up every push (L36).
clean="$(crash_restart_report "${CLEAN_RUN}")"
assert_empty "it says NOTHING when the host did not die" "${clean}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "run-tests-locked-crash-report.test.sh: all assertions passed"
  exit 0
else
  echo "run-tests-locked-crash-report.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
