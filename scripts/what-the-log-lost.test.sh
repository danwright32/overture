#!/usr/bin/env bash
# Fixture for scripts/what-the-log-lost.sh (#3789).
#
# Every case builds its own throwaway log rather than reading the real one: a fixture pointed at
# ~/Library/Application Support would assert about whatever this Mac's launches happen to have written,
# and the store backup log in particular is Dan's own data (L2).
set -uo pipefail
# #3481/L372: captured BEFORE the cd. `$0` and `BASH_SOURCE[0]` are the path the script was INVOKED
# by, so re-deriving a directory from either after a cd resolves against the NEW working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/what-the-log-lost.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# The exact sentences LogRotation writes. Spelled out here rather than generated, so a reworded note in
# the app goes red here instead of quietly leaving this reader matching nothing (L58 is the reason it is
# not read back out of the Swift: two readings of one rule that drift apart both keep passing).
KEPT_NOTE='log rotation: moved 4096 bytes into some.log.1. Nothing older was being kept, so nothing was lost.'
LOST_NOTE='log rotation: moved 4096 bytes into some.log.1, and deleted the 2048 bytes it was holding from the rotation before. That older content is gone.'
REFUSED_NOTE='log rotation: this file is over its cap, but the copy beside it could not be written, so it was left alone rather than emptied. It will keep growing until that works.'

# --- UNMEASURED: no log at all -------------------------------------------------------------------
OUT="$("${SCRIPT}" --log "${WORK}/missing.log" 2>&1)"; STATUS=$?
assert_equals "a log that is not there is UNMEASURED, not clean" "2" "${STATUS}"
assert_contains "it names the path it looked at" "${OUT}" "${WORK}/missing.log"
assert_contains "and says which fact it cannot tell" "${OUT}" "different facts"

# --- a log that has never rotated ----------------------------------------------------------------
mkdir -p "${WORK}/fresh"
printf '2026-09-11 success\n' > "${WORK}/fresh/some.log"
OUT="$("${SCRIPT}" --log "${WORK}/fresh/some.log" 2>&1)"; STATUS=$?
assert_equals "a log with no rotation in it is clean" "0" "${STATUS}"
assert_contains "and says so plainly" "${OUT}" "Nothing has been lost."
assert_contains "naming the live file it read" "${OUT}" "${WORK}/fresh/some.log"

# --- a rotation that kept everything -------------------------------------------------------------
mkdir -p "${WORK}/kept"
printf '%s\n2026-09-11 success\n' "${KEPT_NOTE}" > "${WORK}/kept/some.log"
printf 'older content\n' > "${WORK}/kept/some.log.1"
OUT="$("${SCRIPT}" --log "${WORK}/kept/some.log" 2>&1)"; STATUS=$?
assert_equals "a rotation that deleted nothing is clean" "0" "${STATUS}"
assert_contains "the note is shown" "${OUT}" "Nothing older was being kept"
assert_contains "the .1 is named as part of the history" "${OUT}" "some.log.1  14 bytes"
assert_contains "and the verdict says nothing went" "${OUT}" "deleted nothing"

# --- a rotation that destroyed the generation before it -------------------------------------------
mkdir -p "${WORK}/lost"
printf '%s\n2026-09-11 success\n' "${LOST_NOTE}" > "${WORK}/lost/some.log"
printf 'the generation that survived\n' > "${WORK}/lost/some.log.1"
OUT="$("${SCRIPT}" --log "${WORK}/lost/some.log" 2>&1)"; STATUS=$?
assert_equals "content that is gone is not a clean reading" "1" "${STATUS}"
assert_contains "it says so in those words" "${OUT}" "CONTENT IS GONE"
assert_contains "and quotes the bytes the app recorded" "${OUT}" "deleted the 2048 bytes"

# --- the note living in the .1 rather than the live file ------------------------------------------
# The rotation AFTER a loss moves that note into the `.1`, so a reader of the live file alone sees a
# clean log. This is the case the whole two-file read exists for.
mkdir -p "${WORK}/inbackup"
printf '2026-09-11 success\n' > "${WORK}/inbackup/some.log"
printf '%s\n' "${LOST_NOTE}" > "${WORK}/inbackup/some.log.1"
OUT="$("${SCRIPT}" --log "${WORK}/inbackup/some.log" 2>&1)"; STATUS=$?
assert_equals "a loss recorded only in the .1 is still found" "1" "${STATUS}"
assert_contains "and named" "${OUT}" "CONTENT IS GONE"

# --- a refused rotation ---------------------------------------------------------------------------
mkdir -p "${WORK}/refused"
printf '%s\n' "${REFUSED_NOTE}" > "${WORK}/refused/some.log"
OUT="$("${SCRIPT}" --log "${WORK}/refused/some.log" 2>&1)"; STATUS=$?
assert_equals "a refused rotation is worth looking at" "1" "${STATUS}"
assert_contains "and is told apart from a deletion" "${OUT}" "REFUSED"
assert_not_contains "nothing was destroyed, so it must not say it was" "${OUT}" "CONTENT IS GONE"

# --- a .1 from before the app said anything --------------------------------------------------------
# The state every install is in on the day #3789 ships: a `.1` exists, and no note anywhere says what
# making it cost. That is a finding rather than a clean log, and saying nothing about it would be the
# same silence the issue is about.
mkdir -p "${WORK}/silent"
printf '2026-09-11 success\n' > "${WORK}/silent/some.log"
printf 'whatever was moved aside before #3789\n' > "${WORK}/silent/some.log.1"
OUT="$("${SCRIPT}" --log "${WORK}/silent/some.log" 2>&1)"; STATUS=$?
assert_equals "an unexplained .1 is not a clean reading" "1" "${STATUS}"
assert_contains "and says why it cannot answer" "${OUT}" "cannot be recovered"

# --- --print shows the .1 before the live file ------------------------------------------------------
OUT="$("${SCRIPT}" --log "${WORK}/kept/some.log" --print 2>&1)"
# grep -m2 and a herestring rather than `printf | head`: `head` closes the pipe at its Nth line and a
# BUILTIN producer then prints `write error: Broken pipe`, at random, depending on how much was left to
# write (#3401, and this fixture was caught by that guard on its first run).
FIRST_OF_EACH="$(grep -n -m2 -e 'older content' -e '2026-09-11 success' <<< "${OUT}")"
assert_contains "the retained history runs oldest first" "${FIRST_OF_EACH}" "older content"
assert_equals "and the .1 line comes first" "older content" \
  "$(sed -n '1s/^[0-9]*: *//p' <<< "${FIRST_OF_EACH}")"

# --- an unknown argument is refused, never ignored ----------------------------------------------------
OUT="$("${SCRIPT}" --nonsense 2>&1)"; STATUS=$?
assert_equals "an argument it does not understand is refused" "2" "${STATUS}"
assert_contains "and named" "${OUT}" "unknown argument"

if [ "${FAILURES}" -eq 0 ]; then
  echo "what-the-log-lost.test.sh: all assertions passed"
  exit 0
fi
echo "what-the-log-lost.test.sh: ${FAILURES} assertion(s) failed"
exit 1
