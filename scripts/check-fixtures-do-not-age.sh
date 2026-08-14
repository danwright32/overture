#!/usr/bin/env bash
set -euo pipefail

# #2669: a test fixture pinned to a literal calendar date, evaluated against the live clock, silently
# changes which state it stands for as real time passes it. It was written when the show was in the
# future; months later the same test asserts about a show in the past, and nobody looked. That bit four
# times in one session while building #2645, and one of those tests had spent months asserting that a
# show 27 days in the past should still be chased, which is the exact defect #2645 exists to stop.
#
# WHAT THIS DOES. It asks the suite a question no source text can answer: does any test's verdict depend
# on WHAT YEAR IT IS? Every literal `"yyyy-mm-dd"` in the candidate test files is shifted forward by the
# same number of years, the Swift suite is run, and the tree is restored. A test that changes verdict was
# reading the relationship between a stored date and the clock, and shifting the fixture moved that
# relationship, which is precisely what real time will do to it on its own.
#
# WHY NOT THE SOURCE-TEXT GUARD THE ISSUE PROPOSED, which was "flag a file combining a literal
# performanceDate with a bare Date()". Measured on 2026-08-14: that rule flags 70 of 783 test files, and
# this experiment shows only SIX tests are year-sensitive at all, four of them because they assert a
# weekday name. A guard that fires on the common case is one that gets switched off within a day (L93),
# and it would have flagged two files written the same evening that carry no such defect.
#
# WHY EVERY DATE IN THE FILE MOVES, not only the aged ones. A first version shifted only the past-dated
# `performanceDate` literals and produced 35 failures, almost all of them noise: a fixture date is often
# one half of a literal-to-literal pair (a booking on the same night, a run's second night), and moving
# one end of that pair breaks it for a reason that has nothing to do with the clock. Shifting the whole
# file preserves every date-to-date relationship and changes only the date-to-clock one, which is the
# only relationship this is about (L130).
#
# WHAT IT ASSERTS, and why the size of the answer does not matter. It does NOT demand that no test is
# year-sensitive: measured on 2026-08-14, 39 are, and almost every one for a good reason (a weekday name,
# an Eastern calendar day, business-day arithmetic, a comparison against a checked-in fixture the shift
# cannot move). Demanding zero would be a gate nobody could ever go green on.
#
# It asserts the set has not CHANGED, against `fixtures/year-sensitive-tests.txt`, which this script
# writes itself with --record. That is the useful question, because the set grows on its own as real time
# passes: a fixture dated ahead of today is unaffected by the shift, and the day real time walks past it
# the same shift starts changing its state, so it joins the set and this names it.
#
# A NEW ENTRANT IS NOT A DEFECT, it is a test to look at, which is the whole of what #2669 asked for
# ("nobody looked"). Either the test still asserts what it meant to, in which case record the new
# baseline, or real time has walked it into a different case, which is the four-in-one-session defect.
#
# COST, and why it is not in scripts/test-all.sh. It runs the whole Swift suite a second time, which is
# most of three minutes on top of the run test-all.sh already does. It is meant to be run by hand before
# shipping a change that adds dated fixtures, and periodically.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SHIFT_YEARS="${OVERTURE_AGE_SHIFT_YEARS:-3}"
BASELINE_REL="fixtures/year-sensitive-tests.txt"

# Shift every date literal on stdin forward by $1 years, leaving everything else byte for byte alone.
#
# It matches an opening quote followed by yyyy-mm-dd and does NOT require the quote to close there, so a
# date inside a longer string moves too: `"2026-08-06 14:00"` and `"2026-08-06T03:00:00Z"` are the same
# fixture date as `"2026-08-06"`, and a shifter that moved only the bare ones would leave one end of a
# pair behind and report the mismatch it caused itself. That was measured, not guessed: the first version
# required the closing quote and produced two failures that were entirely its own doing.
#
# Years outside 1980..2100 are left alone: those are sentinels and format examples, not fixture dates, and
# moving them would be changing the thing rather than moving the clock.
#
# Pure, so the fixture can drive it against throwaway text with no repository and no build.
shift_dates() {
  awk -v shift="$1" '
    {
      out = ""
      line = $0
      while (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        pre = substr(line, 1, RSTART - 1)
        tok = substr(line, RSTART, RLENGTH)
        year = substr(tok, 2, 4) + 0
        if (year >= 1980 && year <= 2100) {
          tok = "\"" (year + shift) "-" substr(tok, 7)
        }
        out = out pre tok
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  '
}

# The recorded baseline: the test functions known to be year-sensitive, one name per line, sorted.
# Written by --record, so it is generated from the suite rather than maintained by hand (L96).
# `|| true` on every grep in the pipeline, and it is load-bearing rather than defensive. This script runs
# under `pipefail`, so a grep that legitimately matches NOTHING (no marker in the tree, which is the
# healthy state) fails the whole pipeline, fails the command substitution around it, and `set -e` then
# kills the script with no output at all. That happened on this check's first real run: it exited 1
# having found six genuine failures and printed none of them (the AGENTS.md "no output at all means it
# died rather than passed" tell, from the other side of a pipe).
declared_year_sensitive() {
  local file="${1:-${REPO_ROOT}/${BASELINE_REL}}"
  { grep -vE '^[[:space:]]*(#|$)' "${file}" 2>/dev/null || true; } | sort -u
}

# The test names xcodebuild reported as failing, one per line, sorted. Reads the `Failing tests:` block,
# which names them as `Suite.testName()`; only the function name is kept, since that is what the marker
# above the test can be matched to.
failing_test_names() {
  awk '/^Failing tests:/ { on = 1; next } on && /^\t/ { print; next } on { on = 0 }' \
    | sed -E 's/^\t//; s/\(\)$//; s/^.*\.//' \
    | sort -u
}


# The test files worth shifting: the ones that carry a literal performance date at all. Anything else has
# no dated fixture for the clock to walk past.
candidate_files() {
  { grep -rlE 'performanceDate[:=][[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}"' \
      "${REPO_ROOT}/mac/OvertureTests" "${REPO_ROOT}/mac/OvertureHostedTests" 2>/dev/null || true; } | sort
}

main() {
  cd "${REPO_ROOT}"

  RECORD=0
  [[ "${1:-}" == "--record" ]] && RECORD=1

  # Refuse on a dirty tree rather than risk restoring over somebody's work. The restore below is a
  # `git checkout --`, which would take uncommitted edits with it (L5: never destroy good state).
  if [[ -n "$(git status --porcelain -- mac/)" ]]; then
    echo "check-fixtures-do-not-age: REFUSED, mac/ has uncommitted changes."
    echo "  This shifts every dated fixture and restores the tree with 'git checkout --', which would"
    echo "  take your edits with it. Commit or stash them first."
    exit 1
  fi

  local files
  files="$(candidate_files)"
  if [[ -z "${files}" ]]; then
    # Finding nothing is not success: it means the pattern stopped matching, and a check that reports a
    # pass having examined nothing is indistinguishable from one that examined everything (L98).
    echo "check-fixtures-do-not-age: FAILED, no test file carries a literal performanceDate."
    echo "  That is almost certainly this check's own pattern going stale, not a suite with no dated"
    echo "  fixtures. Nothing was run."
    exit 1
  fi

  local count
  count="$(printf '%s\n' "${files}" | wc -l | tr -d ' ')"
  echo "check-fixtures-do-not-age: shifting every dated fixture in ${count} files forward ${SHIFT_YEARS} years."

  # Always put the tree back, whatever happens next, including a Ctrl-C mid-run.
  trap 'git checkout -- mac/OvertureTests mac/OvertureHostedTests 2>/dev/null || true' EXIT INT TERM

  local file shifted
  while IFS= read -r file; do
    shifted="$(shift_dates "${SHIFT_YEARS}" < "${file}")"
    printf '%s\n' "${shifted}" > "${file}"
  done <<< "${files}"

  local log
  log="$(mktemp -t overture-ageless)"
  echo "check-fixtures-do-not-age: running the Swift suite against the shifted tree (this takes minutes)."
  set +e
  mac/scripts/run-tests-locked.sh > "${log}" 2>&1
  local status=$?
  set -e

  local failing declared joined left
  failing="$(failing_test_names < "${log}")"
  declared="$(declared_year_sensitive)"

  # A suite that could not even build tells us nothing about aging, and must not read as a pass.
  if [[ ${status} -ne 0 && -z "${failing}" ]]; then
    echo "check-fixtures-do-not-age: the shifted suite did not report any failing test but exited ${status}."
    echo "  It probably failed to build, which says nothing about aging. Full log: ${log}"
    exit 1
  fi
  # And a suite that passed ENTIRELY means the shift did nothing, which after 39 known year-sensitive
  # tests can only be the shifter having stopped shifting. Finding nothing is its own outcome (L98).
  if [[ ${status} -eq 0 ]]; then
    echo "check-fixtures-do-not-age: FAILED, the shifted suite passed outright."
    echo "  Something is year-sensitive in this suite and always has been, so a clean pass means the"
    echo "  shift never reached the fixtures. Check shift_dates against a real test file."
    exit 1
  fi

  if [[ "${RECORD}" == "1" ]]; then
    {
      echo "# Generated by scripts/check-fixtures-do-not-age.sh --record. Do not edit by hand."
      echo "#"
      echo "# Every test whose verdict changes when every dated fixture moves ${SHIFT_YEARS} years forward."
      echo "# Being here is not a defect: most of these read a weekday, an Eastern calendar day, business-day"
      echo "# arithmetic, or a checked-in fixture the shift cannot move. What matters is that the set does not"
      echo "# change without somebody looking, because a fixture that ages joins it on its own (#2669)."
      printf '%s\n' "${failing}"
    } > "${REPO_ROOT}/${BASELINE_REL}"
    echo "check-fixtures-do-not-age: recorded $(printf '%s\n' "${failing}" | grep -cv '^$') tests into ${BASELINE_REL}."
    exit 0
  fi

  joined="$(comm -23 <(printf '%s\n' "${failing}" | grep -v '^$' || true) \
                     <(printf '%s\n' "${declared}" | grep -v '^$' || true))"
  left="$(comm -13 <(printf '%s\n' "${failing}" | grep -v '^$' || true) \
                   <(printf '%s\n' "${declared}" | grep -v '^$' || true))"

  local bad=0
  if [[ -n "${joined}" ]]; then
    bad=1
    echo
    echo "check-fixtures-do-not-age: these tests newly depend on what year it is:"
    printf '  %s\n' ${joined}
    echo
    echo "Read each one. Real time may have walked its fixture into a different case than the one it was"
    echo "written for, which is the defect this exists to catch: a show written as upcoming becomes a show"
    echo "in the past, and the test goes on asserting about a case nobody chose (L130). If it still says"
    echo "what it meant to, re-record the baseline:"
    echo "    scripts/check-fixtures-do-not-age.sh --record"
  fi

  if [[ -n "${left}" ]]; then
    bad=1
    echo
    echo "check-fixtures-do-not-age: these tests are in the baseline and no longer depend on the year:"
    printf '  %s\n' ${left}
    echo
    echo "If you pinned their clock, re-record the baseline so a later regression is visible again."
  fi

  if [[ ${bad} -ne 0 ]]; then
    echo
    echo "Full log: ${log}"
    exit 1
  fi

  echo "check-fixtures-do-not-age: OK, the same $(printf '%s\n' "${declared}" | grep -cv '^$') tests read the calendar as before."
  exit 0
}

# Sourceable without running, so the fixture can drive shift_dates, declared_year_sensitive and
# failing_test_names directly. Mirrors check-live-store-claims.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
