#!/bin/sh

# #3191: the rules the per-machine stamp files share, in one place.
#
# WHAT THESE FILES ARE. Three (so far) sit BESIDE the repository recording when something last happened
# on THIS machine: `.overture-eval-last-run` (#1867, when the paid eval last completed),
# `.overture-live-corpus-seen` (#2991, when each live-store invariant last measured anything) and
# `.overture-hosted-suite-seen` (#1995, when the screen tests last passed).
#
# THE THREE DECISIONS THEY SHARE, stated once here rather than restated in each. Every one of them was
# reasoned out for #1867 and then copied by HAND into the next two, which is the shape L501 records: a
# new thing built by cloning a proven pattern copies it AS FIRST WRITTEN.
#
#   1. BESIDE the repository, not inside it. They record what happened on one machine, and a machine's
#      history is not something to merge or review.
#   2. GITIGNORED, for the same reason. A tracked file rewritten by every run is git noise on every
#      branch and a conflict on every merge.
#   3. The date lives INSIDE the file, never as its mtime. A clone rewrites every mtime and would reset
#      the age to zero, which is the one number these must never get wrong.
#
# AND THE ONE RULE THAT IS CODE RATHER THAN A DECISION, which is why this file exists at all: an
# unreadable date answers NOTHING, never zero. Zero days is a measurement and an unreadable date is not
# one, so a caller printing "0 days ago" over a date it could not read states a fact nobody measured
# (L11). Both existing copies of the arithmetic already honoured that. A third, in
# `check-live-store-claims.sh`, did NOT: it neither suppressed the error nor refused, so an unreadable
# date reached the subtraction. That one was found by the guard in `scripts/machine-stamp.test.sh`
# rather than by anybody remembering it, which is the whole argument for the guard.
#
# `#!/bin/sh` deliberately: one of its callers is POSIX (`hosted-suite-stamp.sh`), so a bash-only
# spelling would be a shared helper only half the callers could share.

# machine_stamp_days_since <from> <to>: whole days between two yyyy-mm-dd dates, or NOTHING when either
# cannot be read.
#
# Through `date -j`, which is what this Mac has. Silent rather than wrong when it cannot parse: a
# missing age costs a clause, and a wrong one is a number somebody would act on.
machine_stamp_days_since() {
  from="$1"
  to="$2"
  [ -n "${from}" ] && [ -n "${to}" ] || return 0
  a="$(date -j -f "%Y-%m-%d" "${from}" "+%s" 2>/dev/null)" || return 0
  b="$(date -j -f "%Y-%m-%d" "${to}" "+%s" 2>/dev/null)" || return 0
  [ -n "${a}" ] && [ -n "${b}" ] || return 0
  printf '%s\n' "$(( (b - a) / 86400 ))"
}

# machine_stamp_field <field> <contents>: the value recorded against one field, or nothing.
#
# The LAST occurrence wins, so a record appended to rather than rewritten reads as its newest value.
# Anchored at both ends of the name, so a field that is a PREFIX of another cannot answer for it, which
# is how one stamp comes to read another's date.
#
# One `awk` rather than a `printf` piped into `head`: `head` closes the pipe as soon as it has its line,
# which kills the builtin `printf` with SIGPIPE and makes the shell print `write error: Broken pipe`,
# read by the fixture runner as a fixture breaking a pipe while asserting. Whether it happens depends on
# how much was left to write, so it is a race (#3401).
machine_stamp_field() {
  printf '%s\n' "$2" | awk -v field="$1" '
    index($0, field "=") == 1 { value = substr($0, length(field) + 2) }
    END { if (value != "") print value }
  '
}
