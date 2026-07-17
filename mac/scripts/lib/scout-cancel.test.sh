#!/usr/bin/env bash
set -uo pipefail

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

if [[ ${FAILURES} -gt 0 ]]; then echo "${FAILURES} failure(s)"; exit 1; fi
echo "all scout-cancel.sh checks passed"
