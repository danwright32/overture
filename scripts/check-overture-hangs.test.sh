#!/usr/bin/env bash
# Fixture for scripts/check-overture-hangs.sh (#3425).
#
# It drives the script against directories of its own holding reports it wrote, never
# /Library/Logs/DiagnosticReports, for the reason every fixture here works that way: the real folder's
# contents are whatever this Mac happened to record, so a fixture reading it would assert about the
# machine rather than about the code (L2, L224). The reports it builds are trimmed copies of the real
# shape, taken from the two Overture hang reports measured on 2026-08-31, so the parsing is checked
# against what macOS actually writes rather than against an invention (L52).
#
# THE OUTCOME THAT MATTERS is the third one. A Mac that has recorded no hang and a reader that cannot
# see the folder leave the same empty list, so an unreadable directory is UNMEASURED and never a clean
# bill of health (L98, L11), and the clean bill itself names the directories it read so it cannot be
# mistaken for a statement about the whole machine.
set -uo pipefail
# #3481/L372: captured BEFORE the cd. `$0` and `BASH_SOURCE[0]` are the path the script was INVOKED
# by, so re-deriving a directory from either after a cd resolves against the NEW working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/check-overture-hangs.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# A hang report in the real shape: a header for the hung app, then a system-wide stackshot in which the
# Overture process block is one of several. The frames are the real ones from the 58 second hang of
# 2026-08-30, trimmed.
make_report() {
  local dir="$1" stamp="$2" duration="$3" unresponsive="$4" app_path="$5" own_frames="${6:-yes}"
  mkdir -p "${dir}"
  local f="${dir}/Overture_${stamp}_Daniels-MacBook-Pro-2.hang"
  {
    printf 'Date/Time:        %s\n' "${stamp}"
    printf 'OS Version:       macOS 26.5.1 (Build 25F80)\n'
    printf 'Command:          Overture\n'
    printf 'Path:             %s\n' "${app_path}"
    printf 'Identifier:       com.danwright.overture\n'
    printf '\n'
    printf 'Event:            hang\n'
    printf 'Duration:         %s\n' "${duration}"
    printf 'Note:             Unresponsive for %s seconds before sampling\n' "${unresponsive}"
    printf '\n'
    printf 'Process:          loginwindow [123] [unique pid 1]\n'
    printf '  Thread 0x1    DispatchQueue "com.apple.main-thread"(1)    11 samples\n'
    printf '  11  someone_elses_leaf + 4 (SkyLight + 1) [0x1]\n'
    printf '\n'
    printf 'Process:          Overture [89173] [unique pid 128030570]\n'
    printf 'Path:             %s\n' "${app_path}"
    printf 'Note:             Unresponsive for %s seconds before sampling\n' "${unresponsive}"
    printf '\n'
    printf '  Thread 0x10f364f2    DispatchQueue "com.apple.main-thread"(1)    11 samples (1-11)\n'
    printf '  <process frontmost, thread QoS user interactive>\n'
    printf '  11  start + 6992 (dyld + 130560) [0x1886cbe00] 1-11\n'
    if [ "${own_frames}" = "yes" ]; then
      printf '    11  main + 64 (OvertureApp.swift in Overture + 2238632) [0x104e3a8a8] 1-11\n'
      printf '      11  static OvertureApp.$main() + 52 (OvertureApp.swift in Overture + 2238632) [0x104e3a8a8] 1-11\n'
      printf '        11  -[NSAppleScript executeAndReturnError:] + 132 (Foundation + 1) [0x2] 1-11\n'
    else
      printf '    11  -[NSApplication run] + 368 (AppKit + 180540) [0x18cf6713c] 1-11\n'
    fi
    printf '          11  mach_msg2_trap + 8 (libsystem_kernel.dylib + 1) [0x3] 1-11\n'
    printf '\n'
    printf '  Thread 0x99   11 samples (1-11)\n'
    printf '  11  a_second_thread_leaf + 1 (libsystem + 1) [0x4] 1-11\n'
    printf '\n'
    printf 'Process:          1Password [30329] [unique pid 99426018]\n'
    printf '  Thread 0x2    DispatchQueue "com.apple.main-thread"(1)    11 samples\n'
    printf '  11  one_password_leaf + 8 (Electron + 1) [0x5] 1-11\n'
  } > "${f}"
  printf '%s' "${f}"
}

run_script() {
  OVERTURE_HANG_DIRS="$1" OVERTURE_HANG_OUT="$2" "${SCRIPT}" "${@:3}" 2>&1
}

# --- 1. two reports on record: listed newest first, with what a person needs ------------------------
DIR_A="${WORK}/reports-a"
OUT_A="${WORK}/kept-a"
make_report "${DIR_A}" "2026-08-30-130402" "6.60s" "6" "/Applications/Overture.app/Contents/MacOS/Overture" >/dev/null
make_report "${DIR_A}" "2026-08-30-214817" "58.01s" "57" "/Applications/Overture.app/Contents/MacOS/Overture" >/dev/null
RESULT="$(run_script "${DIR_A}" "${OUT_A}")"
STATUS=$?
assert_equals "reports on record is its own outcome, never a clean pass" "1" "${STATUS}"
assert_contains "it says how many" "${RESULT}" "2 Overture hang report(s) on record"
assert_contains "the long hang's duration is stated" "${RESULT}" "58.01s"
assert_contains "so is the short one's, rather than only the worst" "${RESULT}" "6.60s"
assert_contains "the unresponsive line is carried through, without the report's own Note label" \
  "${RESULT}" "unresponsive: Unresponsive for 57 seconds"
assert_not_contains "the report's column padding does not reach the screen" "${RESULT}" "Note:  "
assert_contains "and the app the report is about, so Debug and Release are distinguishable" \
  "${RESULT}" "/Applications/Overture.app/Contents/MacOS/Overture"

# Newest first. Both stamps are in the output, so the order is asserted on their positions.
# awk rather than `grep -n | head -1`: `head` closes the pipe at its first line, which kills the
# producer with SIGPIPE, and under `set -o pipefail` that 141 becomes the pipeline's status (#3401).
POS_NEW="$(awk '/2026-08-30-214817/ { print NR; exit }' <<< "${RESULT}")"
POS_OLD="$(awk '/2026-08-30-130402/ { print NR; exit }' <<< "${RESULT}")"
if [[ -n "${POS_NEW}" && -n "${POS_OLD}" && "${POS_NEW}" -lt "${POS_OLD}" ]]; then
  pass "the newest report is listed first"
else
  fail "the newest report is listed first" "newest at line ${POS_NEW:-?}, older at ${POS_OLD:-?}"
fi

# --- 2. the stack is Overture's, not the stackshot's --------------------------------------------------
# A hang report is a system-wide stackshot, so every other running process is in the same file. Reading
# across the block boundary would attribute somebody else's stack to this app.
assert_contains "the app's own frames are printed" "${RESULT}" "OvertureApp.swift in Overture"
assert_contains "and what the main thread was blocked in" "${RESULT}" "mach_msg2_trap"
assert_not_contains "never a frame from another process in the same stackshot" \
  "${RESULT}" "one_password_leaf"
assert_not_contains "nor from the process listed above Overture" "${RESULT}" "someone_elses_leaf"
assert_not_contains "and the leaf is the main thread's, not a later thread's" \
  "${RESULT}" "a_second_thread_leaf"

# --- 3. the reports are kept, because they rotate ---------------------------------------------------
KEPT_COUNT="$(ls "${OUT_A}" 2>/dev/null | grep -c '\.hang$' || true)"
assert_equals "both reports are copied out of the rotating folder" "2" "${KEPT_COUNT}"

# Running it again does not duplicate them, and says the copy was already there.
RESULT_AGAIN="$(run_script "${DIR_A}" "${OUT_A}")"
KEPT_AGAIN="$(ls "${OUT_A}" 2>/dev/null | grep -c '\.hang$' || true)"
assert_equals "a second run keeps the same two, not four" "2" "${KEPT_AGAIN}"
assert_contains "and says the copy was already there" "${RESULT_AGAIN}" "already there"

# --- 4. a readable directory with nothing in it is a CLEAN bill that states its scope ----------------
DIR_EMPTY="${WORK}/reports-empty"
mkdir -p "${DIR_EMPTY}"
RESULT="$(run_script "${DIR_EMPTY}" "${WORK}/kept-empty")"
STATUS=$?
assert_equals "no reports in a readable directory exits 0" "0" "${STATUS}"
assert_contains "it says so plainly" "${RESULT}" "No Overture hang report on record"
assert_contains "and names what it actually read, so the answer carries its own scope" \
  "${RESULT}" "${DIR_EMPTY}"

# --- 5. nothing readable is UNMEASURED, never a clean bill -------------------------------------------
RESULT="$(run_script "${WORK}/not-there:${WORK}/also-not-there" "${WORK}/kept-none")"
STATUS=$?
assert_equals "no readable directory is UNMEASURED" "2" "${STATUS}"
assert_contains "it says UNMEASURED" "${RESULT}" "UNMEASURED"
assert_not_contains "and never reports it as no hangs on record" "${RESULT}" "No Overture hang report on record"
assert_contains "it says that is not the same as there being none" "${RESULT}" "not the same as there being none"

# --- 6. present but unreadable is a DIFFERENT state from not there at all ----------------------------
# Only one of the two is a permissions problem somebody can fix, so they get different words (L11).
DIR_LOCKED="${WORK}/reports-locked"
mkdir -p "${DIR_LOCKED}"
chmod 000 "${DIR_LOCKED}"
RESULT="$(run_script "${DIR_LOCKED}" "${WORK}/kept-locked")"
STATUS=$?
chmod 755 "${DIR_LOCKED}"
assert_equals "an unreadable directory alone is UNMEASURED" "2" "${STATUS}"
assert_contains "it is named as present but unreadable" "${RESULT}" "present but unreadable"
assert_not_contains "and is not reported as missing" "${RESULT}" "not there at all"

RESULT="$(run_script "${WORK}/definitely-absent" "${WORK}/kept-absent")"
assert_contains "a directory that is simply absent gets the other wording" "${RESULT}" "not there at all"
assert_not_contains "and is not reported as a permissions problem" "${RESULT}" "present but unreadable"

# --- 7. one readable directory beside an unreadable one still answers, and says what it missed --------
# The partial case is where a clean-looking answer is most dangerous: it is true of half the machine.
DIR_LOCKED2="${WORK}/reports-locked-2"
mkdir -p "${DIR_LOCKED2}"
chmod 000 "${DIR_LOCKED2}"
RESULT="$(run_script "${DIR_A}:${DIR_LOCKED2}" "${WORK}/kept-partial")"
STATUS=$?
chmod 755 "${DIR_LOCKED2}"
assert_equals "a partial read still reports the reports it did find" "1" "${STATUS}"
assert_contains "and names the directory it could not read" "${RESULT}" "NOT read"

DIR_EMPTY2="${WORK}/reports-empty-2"
mkdir -p "${DIR_EMPTY2}"
DIR_LOCKED3="${WORK}/reports-locked-3"
mkdir -p "${DIR_LOCKED3}"
chmod 000 "${DIR_LOCKED3}"
RESULT="$(run_script "${DIR_EMPTY2}:${DIR_LOCKED3}" "${WORK}/kept-partial-2")"
chmod 755 "${DIR_LOCKED3}"
assert_contains "a clean bill taken over half the machine says which half it could not see" \
  "${RESULT}" "NOT read"

# --- 8. a hang with no frames of the app's own says so rather than printing nothing -------------------
# Ordinary for a hang spent entirely below one system call, and silence there reads as the tool having
# found nothing to say.
DIR_SYS="${WORK}/reports-system"
make_report "${DIR_SYS}" "2026-08-29-101010" "12.00s" "11" \
  "/Applications/Overture.app/Contents/MacOS/Overture" "no" >/dev/null
RESULT="$(run_script "${DIR_SYS}" "${WORK}/kept-system")"
assert_contains "it says there are none rather than leaving a gap" \
  "${RESULT}" "Overture's own frames: none in this report"
assert_contains "and still names what the app was blocked in" "${RESULT}" "mach_msg2_trap"

# --- 8b. a long frame list is capped, and the cap SAYS what it dropped ---------------------------------
# A truncation that does not announce itself reads as the whole answer. The real report measured on
# 2026-09-04 carries 60 of the app's own frames, so the default cap is above it and this case drives the
# seam rather than waiting for a pathological report to appear.
RESULT="$(OVERTURE_HANG_MAX_FRAMES=1 run_script "${DIR_A}" "${WORK}/kept-capped")"
assert_contains "the frame list says how many there were" "${RESULT}" "Overture's own frames (2)"
assert_contains "and the cap names what it dropped" "${RESULT}" "showing 1 of 2"
assert_contains "the first frame is still shown" "${RESULT}" "main + 64"
assert_not_contains "and the frame past the cap is not" "${RESULT}" "OvertureApp.\$main()"

# --- 9. a Debug hang is distinguishable from a Release one -------------------------------------------
DIR_DEBUG="${WORK}/reports-debug"
make_report "${DIR_DEBUG}" "2026-08-28-090000" "7.00s" "6" \
  "/Users/dan/Build/Products/Debug/Overture.app/Contents/MacOS/Overture" >/dev/null
RESULT="$(run_script "${DIR_DEBUG}" "${WORK}/kept-debug")"
assert_contains "the Debug build's own path is printed" "${RESULT}" "Products/Debug/Overture.app"

# --- 10. an unknown argument refuses rather than being ignored ----------------------------------------
RESULT="$(run_script "${DIR_A}" "${WORK}/kept-arg" --nonsense)"
STATUS=$?
assert_equals "an unknown argument is UNMEASURED" "2" "${STATUS}"
assert_contains "and names the argument it refused" "${RESULT}" "--nonsense"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All check-overture-hangs.sh fixtures passed."
else
  echo "${FAILURES} check-overture-hangs.sh fixture(s) failed."
  exit 1
fi
