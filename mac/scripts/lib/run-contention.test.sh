#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains, assert_equals,
# assert_eq, assert_empty (#2501). Haystack second, needle third.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #2762 (phase 6 of #2620): did this run share the machine with another run slot?
#
# The wait the selection bar quotes is learned from the checks that have actually run, and it pools the
# last ten. Once a check can run beside a Prep run, three co-runs would retrain the figure Dan reads
# before deciding to spend, and it would read as evidence rather than as a different measurement. So the
# runner records which it was, and the app refuses to pool the two.
#
# Two properties matter here and neither is obvious. It LATCHES rather than reading live, because
# contention is a fact about the run's whole span and the other run may well end first. And it never
# counts the run's OWN marker, which is always present: prep-run.sh creates it before the work starts.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT
# A SPACE in the path, because the live one has one: "~/Library/Application Support/Overture". A fixture
# on a tidy path cannot see the class of defect where an unquoted expansion word-splits.
SUPPORT_DIR="${WORK}/Application Support/Overture"
mkdir -p "${SUPPORT_DIR}"

STATE="${SUPPORT_DIR}/check-contended"

# Sourced the way prep-run.sh sources it: SUPPORT set, then the slot resolved, then this.
observe_as() {
  slot="$1"
  (
    SUPPORT="${SUPPORT_DIR}"
    OVERTURE_RUN_SLOT="${slot}"
    export OVERTURE_RUN_SLOT
    . "${HERE}/run-slot.sh"
    . "${HERE}/run-contention.sh"
    resolve_run_slot
    contention_observe "${STATE}"
  )
}

report_state() {
  (
    SUPPORT="${SUPPORT_DIR}"
    . "${HERE}/run-slot.sh"
    . "${HERE}/run-contention.sh"
    if contention_observed "${STATE}"; then
      echo "CONTENDED=1 NAMES=$(contention_names "${STATE}")"
    else
      echo "CONTENDED=0"
    fi
  )
}

reset_state() { rm -f "${STATE}" "${SUPPORT_DIR}"/*-running 2>/dev/null || true; }

# --- a run with the machine to itself -------------------------------------------------------------
reset_state
observe_as check
assert_equals "a run alone latches nothing" "CONTENDED=0" "$(report_state)"

# --- its OWN marker is not contention -------------------------------------------------------------
# The one that would fire on every single run: prep-run.sh writes its own marker before the work starts,
# so a rule that counted "any -running file" would report every run as contended and the flag would carry
# no information at all.
reset_state
: > "${SUPPORT_DIR}/check-running"
observe_as check
assert_equals "a run's own marker is not contention" "CONTENDED=0" "$(report_state)"

# --- the other slot being alive IS contention -----------------------------------------------------
reset_state
: > "${SUPPORT_DIR}/check-running"
: > "${SUPPORT_DIR}/prep-running"
observe_as check
assert_equals "a check beside a live prep is contended, and says which" \
  "CONTENDED=1 NAMES=prep" "$(report_state)"

# --- and it is derived, so it reads both ways ------------------------------------------------------
# From slot_others rather than a name written out here, so a third slot cannot leave a run unchecked
# against it: the list only ever holds what somebody remembered (L96).
reset_state
: > "${SUPPORT_DIR}/prep-running"
: > "${SUPPORT_DIR}/check-running"
observe_as prep
assert_equals "a prep beside a live check is contended too" \
  "CONTENDED=1 NAMES=check" "$(report_state)"

# --- the latch survives the other run ending -------------------------------------------------------
# The reason this latches instead of reading live. A prep that starts and finishes inside a six minute
# check shared the machine with it for real, and asking the question at the end would answer no.
reset_state
: > "${SUPPORT_DIR}/prep-running"
observe_as check
rm -f "${SUPPORT_DIR}/prep-running"
observe_as check
assert_equals "a run that ended part way through still counted" \
  "CONTENDED=1 NAMES=prep" "$(report_state)"

# --- a tick every 60 seconds does not say it six times ---------------------------------------------
reset_state
: > "${SUPPORT_DIR}/prep-running"
observe_as check
observe_as check
observe_as check
assert_equals "repeated ticks name the other run once" \
  "CONTENDED=1 NAMES=prep" "$(report_state)"

# --- a stale state file from a previous run cannot be inherited ------------------------------------
# Assume it runs twice: prep-run.sh removes this on entry as well as in its trap, exactly as it does for
# the stall state, so a previous run's contention can never be reported as this one's.
assert_contains "the runner clears the latch on entry" \
  "$(cat "${HERE}/../prep-run.sh")" 'rm -f "$CONTENDED_STATE"'

exit "${FAILURES:-0}"
