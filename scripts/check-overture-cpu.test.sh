#!/usr/bin/env bash
# Fixture for scripts/check-overture-cpu.sh (#3541).
#
# It drives the script against directories of its own holding reports it wrote, never
# /Library/Logs/DiagnosticReports, for the reason every fixture here works that way: the real folder's
# contents are whatever this Mac happened to record, so a fixture reading it would assert about the
# machine rather than about the code (L2, L224). The reports it builds are trimmed copies of the real
# shape, taken from the two Overture CPU resource reports on this Mac on 2026-09-14, so the parsing is
# checked against what macOS actually writes rather than against an invention (L52).
#
# THE OUTCOME THAT MATTERS is the third one. A Mac that has recorded nothing and a reader that cannot see
# the folder leave the same empty list, so an unreadable directory is UNMEASURED and never a clean bill
# (L98, L11), and the clean bill names the directories it read so it cannot be mistaken for a statement
# about the whole machine.
set -uo pipefail
# #3481/L372: captured BEFORE the cd, because re-deriving a directory from $0 afterwards resolves
# against the NEW working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/check-overture-cpu.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# A CPU resource report in the real shape: a header of colon-aligned fields, then one "Heaviest stack for
# the target process:" block of indented frames.
make_report() {
  local dir="$1" stamp="$2" cpu_line="$3" app_path="$4" own_frames="${5:-yes}"
  # The calendar day out of the filename stamp (2026-09-13-222713 -> 2026-09-13).
  local day="${stamp%-*}"
  mkdir -p "${dir}"
  local f="${dir}/Overture_${stamp}_Daniels-MacBook-Pro-2.cpu_resource.diag"
  {
    # The stamp in the FILENAME and the Date/Time field are written separately, because the filename's
    # form (2026-09-13-222713) is not the field's form (2026-09-13 22:25:05.640 -0400), and building one
    # from the other put a filename stamp in a date field.
    printf 'Date/Time:        %s 22:25:05.640 -0400\n' "${day}"
    printf 'End time:         %s 22:27:12.238 -0400\n' "${day}"
    printf 'OS Version:       macOS 26.6.2 (Build 25G83)\n'
    printf 'Data Source:      Microstackshots\n'
    printf 'Command:          Overture\n'
    printf 'Path:             %s\n' "${app_path}"
    printf 'Identifier:       com.danwright.overture\n'
    printf '\n'
    printf 'Event:            cpu usage\n'
    printf 'CPU:              %s\n' "${cpu_line}"
    printf 'Duration:         127.00s\n'
    printf 'Duration Sampled: 96.01s (event starts 25.84s before samples, event ends 4.74s after samples)\n'
    printf 'Steps:            22 (12 gigacycles/step, 145 samples lost)\n'
    printf '\n'
    printf 'Heaviest stack for the target process:\n'
    printf '  16  start + 6992 (dyld + 132324) [0x1867984e4]\n'
    if [ "${own_frames}" = "yes" ]; then
      printf '  16  main + 64 (OvertureApp.swift in Overture + 2390748) [0x104567adc]\n'
      printf '  15  static HistoryMatch.matchRelationship(name:) + 28 (HistoryMatch.swift:223 in Overture + 4990292) [0x104866554]\n'
      printf '  3   NSRegularExpression.__allocating_init(pattern:options:) + 20 (<stdin> in Overture + 1642056) [0x104534e48]\n'
    fi
    printf '  13  -[NSApplication run] + 368 (AppKit + 180540) [0x18b04913c]\n'
    printf '\n'
    printf 'Binary Images:\n'
    printf '  0x104200000 - 0x105000000 Overture <EF349CB6> /Applications/Overture.app/Contents/MacOS/Overture\n'
  } > "${f}"
}

# Each call is written out rather than wrapped in a helper, and that is not verbosity. A helper that sets
# a status variable and is itself called inside `$( )` sets it in a SUBSHELL, so the caller reads whatever
# it held before: the first version of this fixture did exactly that and every status assertion compared
# against 0 (L184, and seen here).
#
# The status is captured DIRECTLY from the script, never through a pipe, because a pipe reports the LAST
# command's status and the script's own would be lost.

# 1. No reports anywhere: a clean bill that NAMES its own scope, and exit 0.
mkdir -p "${WORK}/empty" "${WORK}/out1"
out="$(OVERTURE_HANG_DIRS="${WORK}/empty" OVERTURE_HANG_OUT="${WORK}/out1" "${SCRIPT}" 2>&1)"; STATUS=$?
assert_equals "an empty readable directory is a clean bill" "0" "${STATUS}"
assert_contains "and it says so" "${out}" "No Overture CPU resource report on record"
assert_contains "and names the directory it read, so it is not a claim about the whole Mac" \
  "${out}" "${WORK}/empty"

# 2. Not one directory readable: UNMEASURED, never a clean bill. This is the whole point of the script.
out="$(OVERTURE_HANG_DIRS="${WORK}/not-there" OVERTURE_HANG_OUT="${WORK}/out2" "${SCRIPT}" 2>&1)"; STATUS=$?
assert_equals "a directory that is not there is UNMEASURED" "2" "${STATUS}"
assert_contains "and says so" "${out}" "UNMEASURED"
assert_contains "and says it is not the same as there being none" "${out}" "not the same as there being none"
assert_contains "and separates absent from unreadable" "${out}" "not there at all"
assert_not_contains "and never reports a clean bill" "${out}" "No Overture CPU resource report on record"

# 3. A real report: the fields, the app path, and the app's own frames.
mkdir -p "${WORK}/found" "${WORK}/out3"
make_report "${WORK}/found" "2026-09-13-222713" \
  "90 seconds cpu time over 127 seconds (71% cpu average), exceeding limit of 50% cpu over 180 seconds" \
  "/Applications/Overture.app/Contents/MacOS/Overture"
out="$(OVERTURE_HANG_DIRS="${WORK}/found" OVERTURE_HANG_OUT="${WORK}/out3" "${SCRIPT}" 2>&1)"; STATUS=$?
assert_equals "a report on record exits 1" "1" "${STATUS}"
assert_contains "it counts them" "${out}" "1 Overture CPU resource report(s) on record"
# The Date/Time field holds a slash, which broke the field reader's own sed delimiter when it was
# written with one: the value came back EMPTY and printed as "not stated in the report", which is a real
# value rendered as an absent one (L11).
assert_contains "the date is read despite the slash in its field name" "${out}" "2026-09-13 22:25:05.640"
assert_not_contains "and is never reported as absent" "${out}" "when:         not stated"
assert_contains "the whole cpu line, with the limit it exceeded" "${out}" "exceeding limit of 50% cpu"
assert_contains "the steps and the samples lost, so the stack is read as a sample" "${out}" "145 samples lost"
assert_contains "the app path, so a Debug run is never read as the installed one" \
  "${out}" "/Applications/Overture.app/Contents/MacOS/Overture"
assert_contains "the app's own frames" "${out}" "HistoryMatch.matchRelationship"
assert_not_contains "and not the system frames around them" "${out}" "NSApplication run"
assert_contains "and it warns that the counts are a shape, not a share of the time" \
  "${out}" "SAMPLE, not a profile"

# 4. The report is KEPT, because these rotate, and a second run does not duplicate it.
kept_copy="${WORK}/out3/Overture_2026-09-13-222713_Daniels-MacBook-Pro-2.cpu_resource.diag"
assert_equals "the report was copied, because these rotate" "yes" \
  "$([ -f "${kept_copy}" ] && echo yes || echo no)"
out="$(OVERTURE_HANG_DIRS="${WORK}/found" OVERTURE_HANG_OUT="${WORK}/out3" "${SCRIPT}" 2>&1)"; STATUS=$?
assert_contains "a second run leaves the copy alone" "${out}" "already there, left alone"

# 5. A report whose heaviest stack holds none of the app's own frames says so rather than printing an
#    empty space, because an absent list and a list nobody printed read alike (L98).
mkdir -p "${WORK}/nofr" "${WORK}/out5"
make_report "${WORK}/nofr" "2026-09-09-125514" \
  "90 seconds cpu time over 112 seconds (80% cpu average), exceeding limit of 50% cpu over 180 seconds" \
  "/Applications/Overture.app/Contents/MacOS/Overture" "no"
out="$(OVERTURE_HANG_DIRS="${WORK}/nofr" OVERTURE_HANG_OUT="${WORK}/out5" "${SCRIPT}" 2>&1)"; STATUS=$?
assert_contains "no frames of ours is said, not left blank" "${out}" "none in the heaviest stack"

# 6. A Debug build's report is distinguishable from the installed one at a glance.
mkdir -p "${WORK}/debug" "${WORK}/out6"
make_report "${WORK}/debug" "2026-09-10-101010" \
  "90 seconds cpu time over 120 seconds (75% cpu average), exceeding limit of 50% cpu over 180 seconds" \
  "/Users/dan/Library/Developer/Xcode/DerivedData/Overture/Build/Products/Debug/Overture.app/Contents/MacOS/Overture"
out="$(OVERTURE_HANG_DIRS="${WORK}/debug" OVERTURE_HANG_OUT="${WORK}/out6" "${SCRIPT}" 2>&1)"; STATUS=$?
assert_contains "the Debug build's own path is printed" "${out}" "Debug/Overture.app"

# 7. An unknown argument is refused rather than ignored (#3245).
out="$(OVERTURE_HANG_DIRS="${WORK}/found" "${SCRIPT}" --nonsense 2>&1)"; status=$?
assert_equals "an unknown argument is UNMEASURED" "2" "${status}"
assert_contains "and names the argument it refused" "${out}" "--nonsense"

# 8. Newest first, by the stamp in the filename rather than by mtime, because a copy rewrites an mtime.
mkdir -p "${WORK}/many" "${WORK}/out8"
make_report "${WORK}/many" "2026-09-01-000000" "10 seconds cpu time over 20 seconds" "/Applications/Overture.app/Contents/MacOS/Overture"
make_report "${WORK}/many" "2026-09-13-222713" "90 seconds cpu time over 127 seconds" "/Applications/Overture.app/Contents/MacOS/Overture"
# The OLDER file is touched last, so an mtime sort would put it first.
touch "${WORK}/many/Overture_2026-09-01-000000_Daniels-MacBook-Pro-2.cpu_resource.diag"
out="$(OVERTURE_HANG_DIRS="${WORK}/many" OVERTURE_HANG_OUT="${WORK}/out8" "${SCRIPT}" 2>&1)"; STATUS=$?
# A herestring, not a builtin piped into `grep -m1`: an early-exiting consumer closes the pipe and kills
# the builtin producer with SIGPIPE, which fails a push at random rather than every time (#3401).
first="$(grep -m1 'cpu_resource.diag$' <<< "${out}" || true)"
assert_contains "the newest report is listed first" "${first}" "2026-09-13"

if [ "${FAILURES}" -eq 0 ]; then
  echo "All check-overture-cpu.sh fixtures passed."
else
  echo "check-overture-cpu.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
