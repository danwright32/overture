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

# hosted_suites_ran <output-text> <names>: prints the first hosted suite the run reports as PASSED, or
# nothing.
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
hosted_suites_ran() {
  output="$1"
  names="$2"
  [ -n "${names}" ] || return 0
  [ -n "${output}" ] || return 0
  printf '%s\n' "${names}" | while IFS= read -r name; do
    [ -n "${name}" ] || continue
    if printf '%s\n' "${output}" | grep -aqF "Suite \"${name}\" passed"; then
      printf '%s\n' "${name}"
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
