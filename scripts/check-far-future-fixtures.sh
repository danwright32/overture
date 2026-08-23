#!/usr/bin/env bash
set -euo pipefail

# #2366: which tests stopped asserting anything when a rule bounded the future?
#
# THE DEFECT. A fixture dated `2099-09-19` was written to mean "always upcoming". Once #2359 gave the
# queue a triage window, the same date also came to mean "always OUTSIDE the window", so an assertion
# about triage on that show went on passing while covering nothing at all. #2359 re-dated the five files
# it touched. Measured 2026-08-09 on main, 55 tests use `2099-09-19` alone, plus 10 on `2099-10-01`, 8
# on `2099-10-03` and more besides, across at least twelve files. Most are probably harmless, and that
# is exactly the problem: nobody can tell which, and a test that silently stopped asserting is
# indistinguishable from one that still does (L1).
#
# WHAT THIS DOES. It moves every far-future date in the test sources BACK so the show lands inside the
# coming year, runs the Swift suite, restores the tree, and names every test whose VERDICT changed. A
# test that changes verdict was reading the distance between its fixture and the clock, which is exactly
# the property a far-future sentinel silently encodes. A test that does not change verdict does not care
# where its show sits, so its sentinel is harmless and it needs no attention.
#
# IT IS THE MIRROR OF `check-fixtures-do-not-age.sh` (#2669) and shares its machinery through
# `scripts/lib/fixture-date-shift.sh`. That one moves fixtures FORWARD and asks which tests read the
# relationship between a stored date and the clock. This one moves the far ones BACK and asks which were
# relying on being outside every window. Same instrument, opposite question.
#
# WHY ONLY THE FAR-FUTURE LITERALS MOVE, where #2669 deliberately moves every date in a file. #2669 is
# preserving date-to-date pairs while changing the date-to-clock relationship, and shifting everything is
# what does that. Here the whole point is to change one fixture's distance from the clock, and dragging a
# same-file 2026 date back by the same 73 years would put it in 1953, breaking a pair for a reason that
# has nothing to do with the question. Files that hold BOTH kinds are named separately, because those are
# the ones where this shift changes a relationship rather than a distance, and a finding from one of
# those may be this check's own doing.
#
# BOTH DIRECTIONS ARE FINDINGS. A test that goes RED under the shift was asserting something that is only
# true of a far-future show. A test that goes GREEN was asserting something that could never fire while
# its show sat outside the window, which is the #2366 defect exactly. Reporting only the red half would
# report half the answer.
#
# COST, and why it is not in scripts/test-all.sh. Two full Swift suite runs. Run it after adding dated
# fixtures, and whenever a new rule bounds the future.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/fixture-date-shift.sh"

# How many years ahead counts as "far". Two, so next season's fixture is left alone and a sentinel is
# caught. Derived against the year the run happens in and never written down as a literal cutoff: a
# hard-coded year is a date fixture of its own and would age exactly like the ones this exists to find.
FAR_YEARS_AHEAD="${OVERTURE_FAR_FUTURE_YEARS:-2}"

is_far_future() {
  local year="$1" today_year="$2"
  [[ "${year}" -gt $(( today_year + FAR_YEARS_AHEAD )) ]]
}

# Move every far-future date on stdin back so the EARLIEST of them lands about a month ahead of the given
# year, in whole years so the month and day survive. Whole years rather than a day count because a shift
# of a few days is not enough to leave the window, and because month-and-day survival keeps a fixture
# that means "the 19th" still meaning it.
#
# All of them move by the SAME number of years, so the gaps between them survive: a fixture whose two
# nights are twelve days apart still has two nights twelve days apart.
pull_far_future_dates_near() {
  local today_year="$1"
  awk -v today="${today_year}" -v far="${FAR_YEARS_AHEAD}" '
    # First pass is not available on a stream, so the shift is computed from the FIRST far-future date
    # seen and then held. A file whose dates span decades keeps that span, which is what preserving the
    # gaps means.
    {
      out = ""
      line = $0
      while (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        pre = substr(line, 1, RSTART - 1)
        tok = substr(line, RSTART, RLENGTH)
        year = substr(tok, 2, 4) + 0
        if (year > today + far) {
          if (shift == 0) shift = year - today
          tok = "\"" (year - shift) "-" substr(tok, 7)
        }
        out = out pre tok
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  '
}

# A file holding far-future dates AND ordinary ones. Named rather than skipped: the shift moves only half
# of such a file, so a relationship between the two halves changes, and a finding there may be this
# check's own doing rather than a defect (the mistake #2669's own header records making once).
mixes_far_and_near() {
  awk -v today="$(date +%Y)" -v far="${FAR_YEARS_AHEAD}" '
    {
      line = $0
      while (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        year = substr(line, RSTART + 1, 4) + 0
        if (year > today + far) hasFar = 1
        else if (year >= 1980) hasNear = 1
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { exit (hasFar && hasNear) ? 0 : 1 }
  '
}

# Tests failing in the SECOND log that were not failing in the first.
newly_failing() {
  comm -13 <(failing_test_names < "$1") <(failing_test_names < "$2")
}

# And the other direction, which is the same finding with the other sign.
newly_passing() {
  comm -13 <(failing_test_names < "$2") <(failing_test_names < "$1")
}

# A log that never reported a run at all. Two such logs produce an empty difference, and an empty
# difference is exactly what a clean answer looks like, so this has to be its own outcome (L98).
run_reported_nothing() {
  ! grep -qE 'Test run with [0-9]+ tests|\*\* TEST (SUCCEEDED|FAILED) \*\*' "$1"
}

candidate_files() {
  local today_year; today_year="$(date +%Y)"
  local cutoff=$(( today_year + FAR_YEARS_AHEAD ))
  local file
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    if awk -v cutoff="${cutoff}" '
         {
           line = $0
           while (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
             if (substr(line, RSTART + 1, 4) + 0 > cutoff) { found = 1 }
             line = substr(line, RSTART + RLENGTH)
           }
         }
         END { exit found ? 0 : 1 }' "${file}"; then
      printf '%s\n' "${file}"
    fi
  done < <({ grep -rlE '"[0-9]{4}-[0-9]{2}-[0-9]{2}' \
               "${REPO_ROOT}/mac/OvertureTests" "${REPO_ROOT}/mac/OvertureHostedTests" 2>/dev/null || true; } | sort)
}

main() {
  cd "${REPO_ROOT}"

  if [[ -n "$(git status --porcelain -- mac/)" ]]; then
    echo "check-far-future-fixtures: REFUSED, mac/ has uncommitted changes."
    echo "  This rewrites dated fixtures and restores the tree with 'git checkout --', which would take"
    echo "  your edits with it. Commit or stash them first."
    exit 1
  fi

  local files count
  files="$(candidate_files)"
  if [[ -z "${files}" ]]; then
    echo "check-far-future-fixtures: FAILED, no test file carries a date more than ${FAR_YEARS_AHEAD}"
    echo "  years ahead. That is almost certainly this check's own pattern going stale rather than a"
    echo "  suite with no sentinels left. Nothing was run."
    exit 1
  fi
  count="$(printf '%s\n' "${files}" | wc -l | tr -d ' ')"

  local mixed=()
  local file
  while IFS= read -r file; do
    if mixes_far_and_near < "${file}"; then mixed+=("${file#"${REPO_ROOT}/"}"); fi
  done <<< "${files}"

  echo "check-far-future-fixtures: ${count} test file(s) carry a date beyond the horizon."
  if [[ "${#mixed[@]}" -gt 0 ]]; then
    echo
    echo "  ${#mixed[@]} of them ALSO hold ordinary dates, so the shift moves half the file:"
    printf '    %s\n' "${mixed[@]}"
    echo "  A finding in one of those may be this check moving one end of a pair. Read those first."
    echo
  fi

  local before after
  before="$(mktemp -t overture-farfuture-before)"
  after="$(mktemp -t overture-farfuture-after)"
  trap 'git checkout -- mac/OvertureTests mac/OvertureHostedTests 2>/dev/null || true' EXIT INT TERM

  echo "check-far-future-fixtures: running the suite as it stands (this takes minutes)."
  set +e
  mac/scripts/run-tests-locked.sh > "${before}" 2>&1
  set -e
  if run_reported_nothing "${before}"; then
    echo "check-far-future-fixtures: UNMEASURED. The baseline run never reported a suite result, so"
    echo "  there is nothing to compare against. Its log is at ${before}."
    exit 2
  fi

  local today_year; today_year="$(date +%Y)"
  while IFS= read -r file; do
    pull_far_future_dates_near "${today_year}" < "${file}" > "${file}.shifted"
    mv "${file}.shifted" "${file}"
  done <<< "${files}"

  echo "check-far-future-fixtures: running the suite with those shows pulled into the coming year."
  set +e
  mac/scripts/run-tests-locked.sh > "${after}" 2>&1
  set -e
  if run_reported_nothing "${after}"; then
    echo "check-far-future-fixtures: UNMEASURED. The shifted run never reported a suite result, so no"
    echo "  comparison is possible. Its log is at ${after}."
    exit 2
  fi

  local went_red went_green
  went_red="$(newly_failing "${before}" "${after}")"
  went_green="$(newly_passing "${before}" "${after}")"

  echo
  if [[ -z "${went_red}" && -z "${went_green}" ]]; then
    echo "check-far-future-fixtures: no test changed verdict. Every far-future date in those ${count}"
    echo "  files is decoration: nothing asserts anything about where the show sits."
    exit 0
  fi
  if [[ -n "${went_red}" ]]; then
    echo "These tests PASS with the show far in the future and FAIL once it is near:"
    printf '  %s\n' ${went_red}
    echo "  Each was asserting something true only of a show outside every window. Either say so in its"
    echo "  name, or pin a `today` beside the date so the pair cannot drift."
    echo
  fi
  if [[ -n "${went_green}" ]]; then
    echo "These tests FAIL with the show far in the future and PASS once it is near:"
    printf '  %s\n' ${went_green}
    echo "  This is #2366 exactly: the assertion could never fire while the show sat outside the window."
    echo
  fi
  exit 1
}

# Sourceable without running, so the fixture can drive the pure halves above with no repository and no
# build, the same shape check-fixtures-do-not-age.sh uses.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
