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
BASELINE_REL="fixtures/far-future-sensitive-tests.txt"

# The tests already read and judged deliberate, one name per line. Same shape and same reason as
# `fixtures/year-sensitive-tests.txt`: this check does NOT demand that no test is far-future sensitive,
# because some legitimately are (a range refused for being absurdly long needs an absurdly long range),
# and a gate nobody can go green on gets switched off (L93). What it asserts is that the SET has not
# changed, so a NEW entrant is a test to look at.
declared_far_future_sensitive() {
  local file="${1:-${REPO_ROOT}/${BASELINE_REL}}"
  { grep -vE '^[[:space:]]*(#|$)' "${file}" 2>/dev/null || true; } | sed -E 's/[[:space:]]*#.*$//' | sort -u
}

is_far_future() {
  local year="$1" today_year="$2"
  [[ "${year}" -gt $(( today_year + FAR_YEARS_AHEAD )) ]]
}

# The year this file measures ITSELF against, which is not always the year the run happens in.
#
# A test that pins its own clock (`private let now = Date(timeIntervalSince1970: 1_800_000_000)`, which
# is 2027) and dates its show to 2099 is asking a question about a show 72 years ahead OF THAT CLOCK.
# Pulling the show back to the year this script runs in puts it BEHIND the test's own clock, which is a
# different case entirely, and the suite then reports failures that are the check's own doing.
#
# Measured: the first corrected run reported six tests, and five of them were exactly this. They are all
# in `NativePathGuardTests`, which pins 2027 and dates its shows 2099, and every one of them went green
# again once the shift was computed against the pinned clock instead.
#
# The LATEST such clock decides, since a suite usually pins one moment and derives the rest from it. A
# file with no pinned clock measures itself against the real one, so today's year is the answer.
reference_year() {
  local file="$1" today_year="$2"
  awk -v today="${today_year}" -v far="${FAR_YEARS_AHEAD}" '
    function civil_year(z,   era, doe, yoe, y, doy, mp, m) {
      z += 719468
      era = int((z >= 0 ? z : z - 146096) / 146097)
      doe = z - era * 146097
      yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
      y = yoe + era * 400
      doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
      mp = int((5 * doy + 2) / 153)
      m = mp + (mp < 10 ? 3 : -9)
      return (m <= 2) ? y + 1 : y
    }
    {
      line = $0
      while (match(line, /timeIntervalSince1970:[ ]*[0-9_]{9,}/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^timeIntervalSince1970:[ ]*/, "", tok)
        gsub(/_/, "", tok)
        v = tok + 0
        days = int(v / 86400)
        if (v - days * 86400 < 0) days -= 1
        y = civil_year(days)
        # Only a clock that is NOT itself far in the future: a 2099 epoch literal is a fixture date, not
        # the moment the test judges from.
        if (y >= 1980 && y <= today + far && y > latest) latest = y
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { print (latest == 0) ? today : latest }
  ' "${file}"
}

# How many years this file has to move so its far-future fixtures land inside the coming year. Computed
# for the WHOLE FILE and from BOTH forms, then handed to the two passes below, so a fixture written as a
# `"yyyy-mm-dd"` string and one written as `Date(timeIntervalSince1970:)` in the same test land on the
# same day.
#
# That is not symmetry for its own sake. `WentByRetirementOnTheTickTests` pins its opening night as a
# string and the clock it is judged against as an epoch literal, both in 2096, so it is CORRECT and is
# not this issue's defect at all. Moving only the string broke that pair and the suite reported three
# failures which were entirely this check's own doing, which is the mistake `shift_dates`' own header
# records making once already (L130).
#
# The EARLIEST far-future year decides, so the whole span moves together and the gaps survive.
far_future_shift_years() {
  local file="$1" today_year="$2"
  awk -v today="${today_year}" -v far="${FAR_YEARS_AHEAD}" '
    function civil_year(z,   era, doe, yoe, y, doy, mp, m) {
      z += 719468
      era = int((z >= 0 ? z : z - 146096) / 146097)
      doe = z - era * 146097
      yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
      y = yoe + era * 400
      doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
      mp = int((5 * doy + 2) / 153)
      m = mp + (mp < 10 ? 3 : -9)
      return (m <= 2) ? y + 1 : y
    }
    function consider(y) { if (y > today + far && (earliest == 0 || y < earliest)) earliest = y }
    {
      line = $0
      while (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        consider(substr(line, RSTART + 1, 4) + 0)
        line = substr(line, RSTART + RLENGTH)
      }
      line = $0
      while (match(line, /timeIntervalSince1970:[ ]*[0-9_]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^timeIntervalSince1970:[ ]*/, "", tok)
        gsub(/_/, "", tok)
        v = tok + 0
        days = int(v / 86400)
        if (v - days * 86400 < 0) days -= 1
        y = civil_year(days)
        if (y >= 1980 && y <= 2200) consider(y)
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { print (earliest == 0) ? 0 : earliest - today }
  ' "${file}"
}

# Move every far-future date literal on stdin back by the given number of years. Whole years, so the
# month and day survive and a fixture that means "the 19th" still means it, and the same number for all
# of them, so the gaps between a run's nights survive.
pull_far_future_dates_near() {
  local shift="$1" today_year="$2"
  awk -v shift="${shift}" -v today="${today_year}" -v far="${FAR_YEARS_AHEAD}" '
    {
      out = ""
      line = $0
      while (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        pre = substr(line, 1, RSTART - 1)
        tok = substr(line, RSTART, RLENGTH)
        year = substr(tok, 2, 4) + 0
        if (year > today + far) tok = "\"" (year - shift) "-" substr(tok, 7)
        out = out pre tok
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  '
}

# The same move for a date written as a NUMBER, which is the other way a fixture pins a moment and the
# one the string pass cannot see. Reuses the shared shifter with a negative shift, and applies it only to
# values that are themselves far in the future, so an arbitrary instant (`0`, `1`, `9_999`) is untouched.
pull_far_future_epochs_near() {
  local shift="$1" today_year="$2"
  local floor
  floor="$(epoch_at_year_start $(( today_year + FAR_YEARS_AHEAD + 1 )))"
  awk -v shift="${shift}" -v floor="${floor}" '
    function days_from_civil(y, m, d,   era, yoe, doy, doe) {
      y = (m <= 2) ? y - 1 : y
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    function civil_from_days(z,   era, doe, yoe, y, doy, mp, d, m) {
      z += 719468
      era = int((z >= 0 ? z : z - 146096) / 146097)
      doe = z - era * 146097
      yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
      y = yoe + era * 400
      doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
      mp = int((5 * doy + 2) / 153)
      d = doy - int((153 * mp + 2) / 5) + 1
      m = mp + (mp < 10 ? 3 : -9)
      CY = (m <= 2) ? y + 1 : y; CM = m; CD = d
      return 0
    }
    {
      out = ""
      line = $0
      while (match(line, /timeIntervalSince1970:[ ]*[0-9_]+/)) {
        pre = substr(line, 1, RSTART - 1)
        tok = substr(line, RSTART, RLENGTH)
        digits = tok
        sub(/^timeIntervalSince1970:[ ]*/, "", digits)
        gsub(/_/, "", digits)
        v = digits + 0
        if (v >= floor) {
          days = int(v / 86400); secs = v - days * 86400
          if (secs < 0) { days -= 1; secs += 86400 }
          civil_from_days(days)
          tok = "timeIntervalSince1970: " sprintf("%d", days_from_civil(CY - shift, CM, CD) * 86400 + secs)
        }
        out = out pre tok
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  '
}

# The first instant of a given year, so the epoch pass has a numeric floor to compare against rather than
# decoding every literal twice.
epoch_at_year_start() {
  awk -v y="$1" '
    function days_from_civil(yy, m, d,   era, yoe, doy, doe) {
      yy = (m <= 2) ? yy - 1 : yy
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    BEGIN { print days_from_civil(y, 1, 1) * 86400 }
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

  RECORD=0
  [[ "${1:-}" == "--record" ]] && RECORD=1

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
  local shift reference
  while IFS= read -r file; do
    # Against the file's OWN clock where it pins one, not against the year this runs in: a test judging
    # from a pinned 2027 is asking about a show 72 years ahead of THAT, and pulling the show back to
    # today puts it behind the clock the test uses.
    reference="$(reference_year "${file}" "${today_year}")"
    # Per FILE, from both forms, so a string and an epoch literal in the same test land on the same day.
    shift="$(far_future_shift_years "${file}" "${reference}")"
    [[ "${shift}" -gt 0 ]] || continue
    pull_far_future_dates_near "${shift}" "${reference}" < "${file}" \
      | pull_far_future_epochs_near "${shift}" "${reference}" > "${file}.shifted"
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

  local declared changed fresh
  declared="$(declared_far_future_sensitive)"
  changed="$(printf '%s\n%s\n' "${went_red}" "${went_green}" | sed '/^$/d' | sort -u)"
  fresh="$(comm -23 <(printf '%s\n' "${changed}" | sed '/^$/d') <(printf '%s\n' "${declared}"))"
  local gone
  gone="$(comm -13 <(printf '%s\n' "${changed}" | sed '/^$/d') <(printf '%s\n' "${declared}"))"

  if [[ "${RECORD}" -eq 1 ]]; then
    {
      echo "# Tests whose verdict depends on their show being far in the future (#2366)."
      echo "#"
      echo "# Written by scripts/check-far-future-fixtures.sh --record. A line here means somebody read the"
      echo "# test and judged the distance deliberate. The file may grow: a new deliberate one is fine."
      echo "#"
      echo "# READ THE LIMIT OF THE INSTRUMENT BEFORE ADDING TO IT. The shift is by whole YEARS, so a show"
      echo "# lands anywhere from a few days to twelve months from the clock its test judges from, and a"
      echo "# test that breaks because its show became imminent is this check's doing rather than a"
      echo "# finding. Both entries below are exactly that shape or deliberate by design. What the check"
      echo "# genuinely rules out is the #2366 defect: a test that goes GREEN once its show is near, which"
      echo "# means its assertion could never fire while the show sat outside every window. None was found."
      echo
      printf '%s\n' "${changed}"
    } > "${REPO_ROOT}/${BASELINE_REL}"
    echo "check-far-future-fixtures: recorded $(printf '%s\n' "${changed}" | sed '/^$/d' | wc -l | tr -d ' ') test(s) in ${BASELINE_REL}."
    exit 0
  fi

  echo
  if [[ -z "${fresh}" && -z "${gone}" ]]; then
    if [[ -z "${changed}" ]]; then
      echo "check-far-future-fixtures: no test changed verdict at all. Every far-future date in those"
      echo "  ${count} files is decoration: nothing asserts anything about where the show sits."
    else
      echo "check-far-future-fixtures: the same tests are far-future sensitive as last time, and every one"
      echo "  of them has been read. Nothing new."
    fi
    exit 0
  fi
  if [[ -n "${gone}" ]]; then
    echo "${BASELINE_REL} lists test(s) that are no longer far-future sensitive:"
    printf '  %s\n' ${gone}
    echo "  Delete those lines with --record."
    echo
  fi
  went_red="$(comm -12 <(printf '%s\n' "${went_red}" | sed '/^$/d') <(printf '%s\n' "${fresh}"))"
  went_green="$(comm -12 <(printf '%s\n' "${went_green}" | sed '/^$/d') <(printf '%s\n' "${fresh}"))"
  if [[ -z "${went_red}" && -z "${went_green}" ]]; then exit 1; fi
  if [[ -n "${went_red}" ]]; then
    echo "These tests PASS with the show far in the future and FAIL once it is near:"
    printf '  %s\n' ${went_red}
    echo '  Each was asserting something true only of a show outside every window. Either say so in its'
    echo '  name, or pin a today beside the date so the pair cannot drift.'
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
