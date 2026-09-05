#!/usr/bin/env bash
set -uo pipefail

# #3191: the per-machine stamp files, and the one place their shared rules live.
#
# Three files sit beside the repository recording when something last happened on THIS machine:
# `.overture-eval-last-run` (#1867), `.overture-live-corpus-seen` (#2991) and
# `.overture-hosted-suite-seen` (#1995). All three share the same three decisions, and each restated
# them in its own comments, which is the shape L501 records: the newest one copied them BY HAND from the
# previous one. A fourth is plausible and the failure direction is silent.
#
# What is consolidated is what was genuinely written twice: the day arithmetic between two `yyyy-mm-dd`
# dates, and reading a `key=value` line out of a record's text. `days_since` in `suite-stats.sh` and
# `hosted_stamp_age_days` in `hosted-suite-stamp.sh` were the same function under two names, down to the
# refusal that matters most: NOTHING rather than zero when a date cannot be read, because zero days is a
# measurement and an unreadable date is not one (L11).
#
# The helper is `#!/bin/sh` because one of its two callers is, so a bash-only spelling would be a helper
# only half the callers could use.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"
FAILURES=0
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/machine-stamp.sh
. "${SCRIPT_DIR}/lib/machine-stamp.sh"

assert_equals "whole days between two dates" "7" \
  "$(machine_stamp_days_since 2026-09-01 2026-09-08)"
assert_equals "the same day is zero, which is a real measurement" "0" \
  "$(machine_stamp_days_since 2026-09-08 2026-09-08)"
# The refusal that matters: an unreadable date answers NOTHING, never zero, because a caller printing
# "0 days ago" over a date it could not read states a fact nobody measured (L11).
assert_equals "an unreadable start date answers nothing" "" \
  "$(machine_stamp_days_since "not-a-date" 2026-09-08)"
assert_equals "an unreadable end date answers nothing" "" \
  "$(machine_stamp_days_since 2026-09-01 "not-a-date")"
assert_equals "an empty date answers nothing" "" \
  "$(machine_stamp_days_since "" 2026-09-08)"

record="screens=2026-09-01
writer=2026-08-30"
assert_equals "a field is read out of the record's text" "2026-09-01" \
  "$(machine_stamp_field screens "${record}")"
assert_equals "a second field in the same record" "2026-08-30" \
  "$(machine_stamp_field writer "${record}")"
assert_equals "a field that is not there answers nothing" "" \
  "$(machine_stamp_field missing "${record}")"
# A field name that is a PREFIX of another must not answer for it, which is the shape that makes one
# stamp read another's date.
assert_equals "a prefix of a field name does not answer for it" "" \
  "$(machine_stamp_field screen "${record}")"
# The LAST line wins, so a record appended to rather than rewritten reads as its newest value.
assert_equals "the newest value of a repeated field wins" "2026-09-05" \
  "$(machine_stamp_field screens "screens=2026-09-01
screens=2026-09-05")"

# The half that stops a fourth stamp getting it wrong: nobody computes this arithmetic themselves.
# Derived from the tree rather than a list somebody maintains (L96). The helper has to CONTAIN the
# spelling in order to be the one place it lives, so it is the single exemption.
offenders=""
scanned=0
while IFS= read -r f; do
  case "${f}" in
    scripts/lib/machine-stamp.sh|scripts/machine-stamp.test.sh) continue ;;
  esac
  scanned=$((scanned + 1))
  if grep -q "date -j -f" "${REPO_ROOT}/${f}" 2>/dev/null; then
    offenders="${offenders}${f}
"
  fi
done <<EOF
$(cd "${REPO_ROOT}" && git ls-files '*.sh')
EOF

assert_equals "nobody computes the stamp day arithmetic outside the helper" "" "${offenders}"

if [ "${scanned}" -lt 20 ]; then
  fail "the scan read only ${scanned} scripts, so it measured nothing"
else
  pass "scanned ${scanned} scripts for a second copy of the date arithmetic"
fi

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all machine-stamp checks passed"
