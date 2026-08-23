#!/usr/bin/env bash
# Moving the dates in a test fixture, and reading which tests changed verdict as a result.
#
# Extracted from scripts/check-fixtures-do-not-age.sh (#2669) when scripts/check-far-future-fixtures.sh
# (#2366) needed the same three things. The two checks ask OPPOSITE questions of the same machinery:
# #2669 moves every fixture FORWARD and asks which tests read the relationship between a stored date and
# the clock, and #2366 moves the far-future ones BACK and asks which tests were relying on their show
# being outside every window. One implementation rather than two, because a date shifter with a subtle
# bug in one copy and not the other would report a year sensitivity it caused itself, which is a mistake
# the header below records making once already.
#
# Everything here is PURE: it reads stdin and writes stdout, or parses text. Nothing touches the tree, so
# a fixture can drive it against throwaway text with no repository and no build.

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

# #2994: the OTHER way a fixture pins a moment, which the date shifter above cannot see.
#
# `Date(timeIntervalSince1970: 1_754_400_000)` is a date written as a number. #2986 was exactly that
# defect (a pinned clock compared against data that moves on its own every day) and this check could not
# have found it, because the shifter only recognises a `"yyyy-mm-dd"` literal.
#
# ONLY values that land inside the same 1980..2100 window the date shifter uses are moved. That window is
# doing real work here rather than being copied for symmetry: the overwhelming majority of these literals
# are `0`, `1`, `9_999`, `1_000`, arbitrary instants chosen because the test needed two moments in an
# order, and moving those would change the thing rather than move the clock. Measured 2026-08-21: 283
# test files carry such a literal and most are in that arbitrary shape.
#
# The shift is done as CALENDAR arithmetic (decompose to y/m/d, add the years, recompose) rather than by
# adding a fixed number of seconds, so an epoch literal and a `"yyyy-mm-dd"` literal in the same test move
# to the same day. Adding 3 * 365.25 days would drift them apart and the mismatch would be reported as a
# year sensitivity that the shifter itself caused, which is the mistake the date shifter's own header
# records making once already.
#
# Pure, so the fixture can drive it against throwaway text.
shift_epochs() {
  awk -v shift="$1" '
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
      CY = (m <= 2) ? y + 1 : y
      CM = m
      CD = d
      return 0
    }
    function shifted_epoch(v,   days, secs, out) {
      days = int(v / 86400)
      secs = v - days * 86400
      if (secs < 0) { days -= 1; secs += 86400 }
      civil_from_days(days)
      if (CY < 1980 || CY > 2100) return -1
      out = days_from_civil(CY + shift, CM, CD) * 86400 + secs
      return out
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
        moved = shifted_epoch(digits + 0)
        if (moved >= 0) {
          tok = "timeIntervalSince1970: " sprintf("%d", moved)
        }
        out = out pre tok
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  '
}

# The test names xcodebuild reported as failing, one per line, sorted. Reads the `Failing tests:` block,
# which names them as `Suite.testName()`; only the function name is kept, since that is what the marker
# above the test can be matched to.
failing_test_names() {
  awk '/^Failing tests:/ { on = 1; next } on && /^\t/ { print; next } on { on = 0 }' \
    | sed -E 's/^\t//; s/\(\)$//; s/^.*\.//' \
    | sort -u
}


