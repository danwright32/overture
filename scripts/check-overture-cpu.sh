#!/usr/bin/env bash
# List the CPU resource reports macOS has already written for Overture (#3541).
#
# macOS writes `Overture_*.cpu_resource.diag` when the app burns processor time past a threshold, into
# the same directories as the `.hang` reports #3425 reads. Nothing here read them, so that whole
# population was invisible. Measured 2026-09-04: three on this Mac against two hang reports.
#
# WHY IT IS WORTH HAVING, and it is the same argument #3425 made: the OS writes it whether or not our own
# instrumentation is running or correct, it works BACKWARDS over what is already on disk, and it catches a
# case the hang reports structurally cannot. A hang report is written when the app stops answering the
# window server; a freeze that never quite stops answering while still burning a core leaves no hang
# report at all and one of these.
#
# A SIBLING rather than a mode of the hang reader, because it is a different file format with different
# fields, and folding it in would put a second parser inside a script whose subject is hang reports. What
# the two share (which directories could be read, how a report is kept, the three outcomes) is in
# `scripts/lib/diagnostic-reports.sh` and is written once (L263, L46).
#
# HOW TO READ ITS ANSWER. Three outcomes, and the third is the one that matters:
#
#   0  every directory it could read holds no Overture CPU report. It NAMES those directories.
#   1  CPU reports are on record, newest first.
#   2  UNMEASURED: not one directory could be read (L98, L11).
#
# AND HOW TO READ A REPORT, which is the trap this one has that the hang reader does not. The stack is a
# MICROSTACKSHOT sample, not a profile. A real one on this Mac holds 25 steps over 108 seconds with 22
# samples lost, so the frame counts beside each line say where the busiest thread USUALLY was and say
# nothing about what share of the time anything cost (L355). This prints the step count and the samples
# lost beside every stack for that reason: a count of 13 out of 25 is a shape, and reading it as "half the
# time" is the mistake this header exists to prevent.
set -uo pipefail
# #3481/L372: captured BEFORE the cd, because `$0` is the path the script was INVOKED by and re-deriving
# a directory from it after a cd resolves against the new working directory.
CPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${CPU_DIR}/.." || exit 1
# shellcheck source=./lib/diagnostic-reports.sh
. "${CPU_DIR}/lib/diagnostic-reports.sh"

# The SAME variables the hang reader uses, so a fixture pointing one somewhere points both, and somebody
# who has learned one has learned the other.
REPORT_DIRS="${OVERTURE_HANG_DIRS:-/Library/Logs/DiagnosticReports:${HOME}/Library/Logs/DiagnosticReports}"
OUT_DIR="${OVERTURE_HANG_OUT:-${HOME}/.overture-mac-test-diagnostics}"

# How many of the app's own frames reach the screen per report. The whole report is always kept, so the
# cap costs nothing but has to SAY what it dropped: a truncation that does not announce itself reads as
# the whole answer. Measured 2026-09-14 against this Mac's two real reports: 26 and 15 of the app's own
# frames in the heaviest stack, so the default sits well above both.
MAX_FRAMES="${OVERTURE_CPU_MAX_FRAMES:-120}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    *)
      # Refused rather than ignored: an argument silently dropped is indistinguishable from one that was
      # honoured (#3245).
      echo "UNMEASURED: unknown argument '$1'."
      echo "            Usage: scripts/check-overture-cpu.sh [--out DIR]"
      exit 2
      ;;
  esac
done

overture_classify_report_dirs "${REPORT_DIRS}"
if [ -z "${OVERTURE_REPORTS_READABLE}" ]; then
  overture_report_unmeasured "a CPU resource report for Overture"
  exit 2
fi

REPORTS="$(overture_find_reports '.cpu_resource.diag')"

if [ -z "${REPORTS}" ]; then
  echo "No Overture CPU resource report on record."
  echo "  read: $(printf '%s' "${OVERTURE_REPORTS_READABLE}" | tr '\n' ' ')"
  if [ -n "${OVERTURE_REPORTS_UNREADABLE}" ]; then
    echo "  NOT read (present but unreadable), so this answer is about the directories above only:"
    printf '%s' "${OVERTURE_REPORTS_UNREADABLE}" | sed 's/^/    /'
  fi
  exit 0
fi

if ! mkdir -p "${OUT_DIR}" 2>/dev/null; then
  echo "UNMEASURED: could not create ${OUT_DIR}, so a report found here could not be kept."
  echo "            These reports rotate, so listing one without keeping it is a citation that expires."
  exit 2
fi

COUNT="$(printf '%s\n' "${REPORTS}" | grep -c '[^[:space:]]' || true)"
echo "${COUNT} Overture CPU resource report(s) on record, newest first."
echo "  read: $(printf '%s' "${OVERTURE_REPORTS_READABLE}" | tr '\n' ' ')"
if [ -n "${OVERTURE_REPORTS_UNREADABLE}" ]; then
  echo "  NOT read (present but unreadable): $(printf '%s' "${OVERTURE_REPORTS_UNREADABLE}" | tr '\n' ' ')"
fi
echo "  the stack below is a SAMPLE, not a profile: the counts say where the busiest thread usually was,"
echo "  never what share of the time anything cost. Read the steps and samples-lost lines with it."
echo

# A `|` delimiter rather than `/`, because one of the field names IS `Date/Time` and a slash inside the
# pattern half ends the substitution early: seen, reported as `bad flag in substitute command: '/'` with
# the field then reading "not stated in the report", which is a real value rendered as an absent one.
field() { grep -m1 "^$1:" "$2" 2>/dev/null | sed "s|^$1: *||"; }

while IFS= read -r report; do
  [ -n "${report}" ] || continue
  echo "  $(basename "${report}")"

  WHEN="$(field 'Date/Time' "${report}")"
  ENDED="$(field 'End time' "${report}")"
  # The app the report is about, so a Debug run is never read as the installed Release one.
  APP_PATH="$(field 'Path' "${report}")"
  # The whole CPU line, verbatim, because it carries the limit it exceeded as well as what it used, and a
  # reading that quotes only the usage cannot say whether it was close to the line or far past it.
  CPU_LINE="$(field 'CPU' "${report}")"
  STEPS="$(field 'Steps' "${report}")"
  SAMPLED="$(field 'Duration Sampled' "${report}")"

  echo "    when:         ${WHEN:-not stated in the report}"
  echo "    ended:        ${ENDED:-not stated in the report}"
  echo "    cpu:          ${CPU_LINE:-not stated in the report}"
  echo "    sampled:      ${SAMPLED:-not stated in the report}"
  echo "    steps:        ${STEPS:-not stated in the report}"
  echo "    app:          ${APP_PATH:-not stated in the report}"

  # The heaviest stack, which is what this report format leads with, and only Overture's OWN frames out
  # of it. A CPU report for one process is not a system-wide stackshot the way a hang report is, but its
  # stack is almost entirely system frames, and the app's own are what say which of Dan's code led there.
  STACK="$(awk '
    /^Heaviest stack for the target process:/ { inblock = 1; next }
    inblock && /^[^ ]/ { inblock = 0 }
    inblock { print }
  ' "${report}" 2>/dev/null)"

  if [ -z "${STACK}" ]; then
    echo "    stack:        the report carries no heaviest stack, so what the app was doing is not"
    echo "                  something this report answers."
  else
    OWN="$(printf '%s\n' "${STACK}" | grep -F ' in Overture ' || true)"
    if [ -n "${OWN}" ]; then
      OWN_COUNT="$(printf '%s\n' "${OWN}" | grep -c '[^[:space:]]' || true)"
      echo "    Overture's own frames (${OWN_COUNT}), deepest last:"
      if [ "${OWN_COUNT}" -gt "${MAX_FRAMES}" ]; then
        printf '%s\n' "${OWN}" | sed 's/^ */      /' | sed -n "1,${MAX_FRAMES}p"
        echo "      ... showing ${MAX_FRAMES} of ${OWN_COUNT}. The rest are in the kept report."
      else
        printf '%s\n' "${OWN}" | sed 's/^ */      /'
      fi
    else
      echo "    Overture's own frames: none in the heaviest stack. That is ordinary for time spent"
      echo "                  entirely below one system call, and it is said rather than left blank."
    fi
  fi

  echo "    kept:         $(overture_keep_report "${report}" "${OUT_DIR}")"
  echo
done <<REPORT_LIST
${REPORTS}
REPORT_LIST

exit 1
