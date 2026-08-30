#!/bin/sh

# #1995: when did the tests that check what the SCREENS render last actually pass?
#
# #1967 split the Swift suite so a launch fault costs the app-hosted tests instead of all of them, and
# that is the point: `run-tests-locked.sh` falls back to the pure scheme, reports "the PURE suite PASSED,
# the failure above is the APP HOST, not your code", and work carries on correctly.
#
# The gap it opens is that those hosted tests are the ONLY ones that render a real SwiftUI view, and
# nothing recorded when they last ran. Before the split a host that would not launch stopped everything,
# so it was noticed immediately. After it, a broken host is a WARNING, and if it stays broken across a
# stretch of UI work the screen tests go unverified for as long as that lasts, silently, while the work
# most likely to be happening in that window is exactly the work they cover. An unrun test and a passing
# test look identical from outside (L98).
#
# HOW A RUN PROVES IT VERIFIED THE SCREENS, and why it is not a count. The obvious signal is that two test
# BUNDLES reported instead of one, which is a proxy: it says two bundles ran, never which two, and a
# scoped run over two pure suites has the same shape. So the evidence is the hosted suites' OWN names,
# derived from `mac/OvertureHostedTests/` rather than listed here, and a run that names one of them as
# passed really did render a view. A derivation that comes back EMPTY is unmeasured and says so, because
# an empty name list would make every run report the screens as unverified, which is a different claim
# and the more alarming of the two (L11).
#
# WHERE THE STAMP LIVES, and both halves are #2991's precedent rather than a fresh decision. Beside the
# repository and gitignored, because it records what happened on THIS machine. And the date lives INSIDE
# the file rather than being its mtime, because a clone rewrites every mtime and would reset the age to
# zero, which is the one number this must never get wrong.

# hosted_suite_names <dir>: the display name of every `@Suite("...")` under dir, one per line.
#
# The DISPLAY name, not the type name, because that is what the test output prints
# (`Suite "The watch gap line on screen (#2091)" passed`). A suite declared with no display name
# contributes nothing here, which costs only the runs where it is the sole hosted suite to report.
hosted_suite_names() {
  dir="$1"
  [ -d "${dir}" ] || return 0
  grep -rhoE '@Suite\("[^"]+"' "${dir}" 2>/dev/null \
    | sed -E 's/^@Suite\("//; s/"$//' \
    | sort -u
}

# hosted_suite_types <dir>: the Swift TYPE name of every `@Suite` declaration under dir, one per line.
#
# #3233: the same question the display names answer, for a run under `-parallel-testing-enabled YES`,
# which prints no `Suite "..." passed` line anywhere (measured on the 2026-08-29 experiment log: zero of
# them in 6,489 lines). It reports each test on its own line and names the suite by its TYPE:
#
#   Test case 'ProspectRowViewReachabilityTests/theBadgeIsDrawn()' passed on 'My Mac - Overture (63823)'
#
# A suite carrying no display name contributes here even though it contributes nothing above, which is a
# small gain rather than the point: the point is that under that flag the display names find nothing at
# all, so every run would report the screens as unverified while rendering all 49 suites of them.
#
# Read by walking FORWARD from each `@Suite` to the first declaration line, rather than by taking a fixed
# number of following lines. `@MainActor` sits between them often enough here, and a fixed window is
# answered by whatever happens to be inside it: a `struct` three lines under a `@Suite` mentioned in a
# COMMENT would be collected as a hosted suite, and this list is trusted in the direction that says the
# screens were checked.
hosted_suite_types() {
  dir="$1"
  [ -d "${dir}" ] || return 0
  find "${dir}" -name '*.swift' -type f -exec awk '
    /^[[:space:]]*@Suite/ { pending = 1; next }
    pending {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "" || line ~ /^\/\// || line ~ /^@/) next
      if (match(line, /(^|[[:space:]])(class|struct|enum|actor)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
        n = split(substr($0, RSTART, RLENGTH), parts, /[[:space:]]+/)
        print parts[n]
      }
      pending = 0
    }
  ' {} + 2>/dev/null | sort -u
}

# hosted_suites_ran <output-text> <names> [types]: prints the first hosted suite the run reports as
# PASSED, or nothing.
#
# PASSED specifically, not merely mentioned: a run that started the bundle and died in it has verified
# nothing, and its output names those suites just as a passing run does.
#
# The run's output as TEXT, which is what `run-tests-locked.sh` holds and what every reporting helper
# beside this one already takes (`suite_report_for_run`, `live_corpus_report`). The first version took a
# PATH, and the cost of that mismatch is why it is spelled out here: handed text, its `[ -f ]` guard was
# false, it returned nothing, and a full run that had just passed all 49 hosted suites printed "NOT
# VERIFIED by this run, and no run on this clone has ever verified them". An unmeasured state read as a
# measurement, in the exact shape of the defect this file exists to prevent (L98). The fixture did not
# catch it because it wrote files and passed paths, which is not how the caller calls it (L52).
# WHY NEITHER MATCH BELOW USES `grep -q` (#3275). Both were written as
# `printf '%s\n' "${output}" | grep -q <pattern>`, and `mac/scripts/run-tests-locked.sh` runs under
# `set -euo pipefail`. Under pipefail that pipeline reports the PRODUCER being killed: grep -q exits the
# instant it matches, printf is still writing a megabyte into a 64KB pipe, it takes SIGPIPE, and the
# status is 141. Measured 2026-08-30 against a real 1.2MB parallel run log: an EARLY match gave 141, a
# LATE match 0, and NO match 1. So the condition read as "no match" for an early match and for no match
# alike, and the only case it read correctly was a match near the END of the stream (L183, L11).
#
# It looked fine because a SERIAL run puts the app-hosted bundle LAST, so the match lands near the end.
# That is luck. Under `-parallel-testing-enabled YES` the hosted lines are interleaved from the start,
# and four consecutive runs reported the screens as NOT VERIFIED having just passed all 49 of them.
#
# `grep` WITHOUT `-q` reads its whole input, so there is nothing left to kill. A herestring would do the
# same and is what `scripts/run-shell-fixtures.sh` recommends to fixtures, but this file is under
# `scripts/check-runner-posix.sh` and `<<<` is a bashism. Do not put the `-q` back to quieten it: the
# output is already discarded, and the `-q` is the defect rather than the tidying.
hosted_suites_ran() {
  output="$1"
  names="$2"
  types="${3:-}"
  [ -n "${output}" ] || return 0

  if [ -n "${names}" ]; then
    serial_hit="$(printf '%s\n' "${names}" | while IFS= read -r name; do
      [ -n "${name}" ] || continue
      if printf '%s\n' "${output}" | grep -aF "Suite \"${name}\" passed" >/dev/null; then
        printf '%s\n' "${name}"
        break
      fi
    done)"
    if [ -n "${serial_hit}" ]; then
      printf '%s\n' "${serial_hit}"
      return 0
    fi
  fi

  # #3233: the parallel format, asked only where the serial one found nothing. A run is one or the
  # other, so this costs a passing serial run nothing.
  #
  # Anchored at the SLASH, which is doing real work: `ProspectRowViewReachabilityTestsExtra` would
  # otherwise answer for `ProspectRowViewReachabilityTests`, and a near miss reads as a verified
  # screen. And `passed` specifically, as above: a hosted test that FAILED rendered something, but
  # this record is what a later reader trusts as "the screens were checked and were fine".
  [ -n "${types}" ] || return 0
  printf '%s\n' "${types}" | while IFS= read -r type; do
    [ -n "${type}" ] || continue
    if printf '%s\n' "${output}" | grep -aE "^Test case '${type}/[^']*' passed on " >/dev/null; then
      printf '%s\n' "${type}"
      break
    fi
  done
}

# hosted_stamp_update <verified> <today> <existing>: the file's new contents, or the existing ones.
#
# A run that did NOT verify the screens leaves the record alone, which is the whole mechanism: stamping
# every run would move the date forward while the host stayed broken, the age would always read zero, and
# the gap would be invisible behind a date that looks like a measurement. That is #2991's own refusal,
# and it is the same defect wearing a date.
hosted_stamp_update() {
  verified="$1"
  today="$2"
  existing="$3"
  if [ -z "${verified}" ]; then
    printf '%s' "${existing}"
    return 0
  fi
  printf 'screens=%s\n' "${today}"
}

# hosted_stamp_date <contents>: the recorded date, or nothing.
hosted_stamp_date() {
  printf '%s\n' "$1" | sed -n 's/^screens=\([0-9][0-9-]*\).*/\1/p' | head -1
}

# hosted_stamp_age_days <recorded> <today>: whole days between two yyyy-mm-dd dates, or nothing.
#
# Through `date -j`, which is what this Mac has, and silent rather than wrong when it cannot parse: a
# missing age costs a clause, and a wrong one is a number somebody would act on.
hosted_stamp_age_days() {
  recorded="$1"
  today="$2"
  a="$(date -j -f '%Y-%m-%d' "${recorded}" '+%s' 2>/dev/null)" || return 0
  b="$(date -j -f '%Y-%m-%d' "${today}" '+%s' 2>/dev/null)" || return 0
  [ -n "${a}" ] && [ -n "${b}" ] || return 0
  printf '%s\n' "$(( (b - a) / 86400 ))"
}

# hosted_freshness_line <verified> <recorded-date> <today> <names-found>
#
# FOUR states, kept apart because three of them are quiet and only one of those is good (L11):
#   verified today            this run rendered views and they passed
#   NOT VERIFIED, last passed the run did not, and here is when one last did, with the age
#   NOT VERIFIED, never       no run on this clone has ever verified them
#   UNMEASURED                no hosted suite name could be read, so nothing was asked
hosted_freshness_line() {
  verified="$1"
  recorded="$2"
  today="$3"
  found="$4"

  if [ -z "${found}" ]; then
    printf 'Screen tests: UNMEASURED. No @Suite name could be read from mac/OvertureHostedTests, so this\n'
    printf 'run could not tell whether the tests that render a real view ran at all (#1995).\n'
    return 0
  fi
  if [ -n "${verified}" ]; then
    printf 'Screen tests: verified by this run (#1995).\n'
    return 0
  fi
  if [ -z "${recorded}" ]; then
    printf 'Screen tests: NOT VERIFIED by this run, and no run on this clone has ever verified them. The\n'
    printf 'tests that render a real SwiftUI view are the only ones checking what the screens show (#1995).\n'
    return 0
  fi
  days="$(hosted_stamp_age_days "${recorded}" "${today}")"
  printf 'Screen tests: NOT VERIFIED by this run. They last passed on %s' "${recorded}"
  if [ -n "${days}" ]; then
    printf ' (%s days ago)' "${days}"
  fi
  printf '.\n'
  printf 'A run that skipped them and a run that passed them look identical from outside (#1995, L98).\n'
}
