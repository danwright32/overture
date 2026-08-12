#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #1037: a scout Dan started can be stopped. The detached read has no trackable PID (DetachedRunner
# backgrounds it via `sh -c '... &'`), so a hard kill is off the table; the stop is COOPERATIVE. Overture
# writes a cancel-request file, and the runner checks for it on each heartbeat tick and exits cleanly.
# This covers that check: a one-line predicate whose whole job is to read the sentinel the app writes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert() {
  local desc="$1"; shift
  if "$@"; then echo "ok - ${desc}"; else echo "FAIL - ${desc}"; FAILURES=$((FAILURES + 1)); fi
}
refute() {
  local desc="$1"; shift
  if "$@"; then echo "FAIL - ${desc}"; FAILURES=$((FAILURES + 1)); else echo "ok - ${desc}"; fi
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scout-cancel.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
CANCEL="${TMP}/scout-extract-cancel"

# No file: no cancel requested. This is the normal case on every healthy run, so it must never read as
# cancelled (which would stop every run instantly).
refute "no cancel file means no cancel requested" cancel_requested "${CANCEL}"

# The app wrote the sentinel: cancel IS requested.
: > "${CANCEL}"
assert "the cancel sentinel is detected once written" cancel_requested "${CANCEL}"

# Cleared again (a fresh run clears any stale sentinel before it starts, so a leftover from a cancelled
# run can never kill the next one): back to not requested.
clear_cancel "${CANCEL}"
refute "clearing the sentinel returns to not-requested" cancel_requested "${CANCEL}"

# Clearing an already-absent sentinel is a quiet no-op, never an error that could fail a run.
assert "clearing an absent sentinel is a no-op" clear_cancel "${CANCEL}"

# #1053: the heartbeat now polls the cancel sentinel far more often than it touches the marker, so a
# Cancel stops the read within a few seconds instead of up to a minute. marker_due gates the expensive
# 60s work (marker touch, chunk merge, progress derive) so the two cadences stay decoupled: the sentinel
# is read every short poll, this fires only once the accrued time reaches the interval. If this ever
# regressed to firing every poll, the merge/derive cost would balloon; if it never fired, the marker
# would go stale and a live run would look crashed.
refute "marker work is not due before the interval" marker_due 3 60
refute "marker work is not due one poll short of the interval" marker_due 57 60
assert "marker work is due exactly at the interval" marker_due 60 60
assert "marker work is due once past the interval" marker_due 63 60

if [[ ${FAILURES} -gt 0 ]]; then echo "${FAILURES} failure(s)"; exit 1; fi
echo "all scout-cancel.sh checks passed"
