#!/usr/bin/env bash
# Take one labelled measurement of the running Overture, recording what else this Mac was doing (#3434
# Phase 0, with #3442).
#
# WHY IT CLASSIFIES RATHER THAN GATES. Phase 0 as written calls a machine quiet when no xcodebuild,
# xctest or agent worktree is running. Measured 2026-09-01 on this Mac: none of the three was running,
# load averages read 13.01 / 28.35 / 28.97, Synology's cloud-drive-daemon sat at 99.4% and Backblaze's
# bztransmit at 84.0%. Phase 0's check would have called that quiet, and #3442's proposed signal (the
# presence of run-tests-locked.sh's lock) would have agreed with it.
#
# Dan's correction the same day is what settles the design: Synology and Backblaze are ALWAYS running
# here, and Lightroom is something he uses rather than something to ban. A check refusing on any of them
# refuses every measurement he will ever take, which is the gate that fires on the ordinary case and is
# switched off within a day (L93, L36). And dropping the loaded samples is the one thing #3442 forbids
# outright, because a filtered-out freeze is a measurement nobody can re-examine.
#
# So what it judges is not quiet against busy:
#
#   0  BASELINE   only the always-present set was busy. The representative condition, and the one Dan's
#                 real freezes happen in.
#   1  ELEVATED   something NOT on that list was busy. Named, with its CPU, and the record is STILL
#                 written, so this is a caveat Dan can accept or retake against, never a refusal.
#   2  UNMEASURED nothing was measured: the process table, the baseline list, the app or the sample
#                 could not be read. Never folded into BASELINE, because the emptiest possible failure
#                 must not read as the cleanest possible pass (L98, L11).
#
# The always-present set is DERIVED from this Mac at rest and recorded in a file carrying its own
# measurement date, never hardcoded here: another Mac, or this one after Dan changes what he runs, would
# otherwise read as permanently ELEVATED and the tool would be useless there (L96, L153).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MEASURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/scratch.sh
. "${MEASURE_DIR}/lib/scratch.sh"

# The full executable path, never the app name or the bundle id. Two builds of Overture can run at once
# and both are called "Overture"; resolving by name once sent a Cmd+W to Dan's live app instead of the
# Debug one it was aimed at.
APP_EXEC="/Applications/Overture.app/Contents/MacOS/Overture"

PS_CMD="${OVERTURE_MEASURE_PS:-}"
PGREP_CMD="${OVERTURE_MEASURE_PGREP:-}"
SAMPLE_CMD="${OVERTURE_MEASURE_SAMPLE:-/usr/bin/sample}"
SECONDS_TO_SAMPLE="${OVERTURE_MEASURE_SECONDS:-10}"
OUT_DIR="${OVERTURE_MEASURE_OUT:-${HOME}/.overture-mac-test-diagnostics}"
BASELINE_FILE="${OVERTURE_MEASURE_BASELINE_FILE:-${MEASURE_DIR}/../fixtures/resting-baseline.txt}"

# A quarter of one core. CHOSEN, not measured: there is no distribution of this Mac's idle CPU to set it
# from yet, and Phase 0 is the thing that produces one. Named as chosen rather than dressed up as a
# measurement, so the next person re-derives it instead of trusting it (L172, L316).
BUSY_CPU="${OVERTURE_MEASURE_BUSY_CPU:-25.0}"

LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    --seconds) SECONDS_TO_SAMPLE="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    *) echo "UNMEASURED: unknown argument '$1'"; exit 2 ;;
  esac
done

if [ -z "${LABEL}" ]; then
  echo "UNMEASURED: no measurement label. Pass --label A or --label B, so the record says which"
  echo "            of Phase 0's two readings this is."
  exit 2
fi

# --- the always-present set ------------------------------------------------------------------------
if [ ! -f "${BASELINE_FILE}" ]; then
  echo "UNMEASURED: no resting baseline list at ${BASELINE_FILE}."
  echo "            Without it every ordinary run reads as ELEVATED, which is the same defect as"
  echo "            banning the daemons outright, arriving silently instead."
  exit 2
fi
BASELINE_NAMES="$(grep -v '^[[:space:]]*#' "${BASELINE_FILE}" | grep -v '^[[:space:]]*$' || true)"
if [ -z "${BASELINE_NAMES}" ]; then
  echo "UNMEASURED: the resting baseline list at ${BASELINE_FILE} names no processes."
  exit 2
fi

# --- which Overture -------------------------------------------------------------------------------
if [ -n "${PGREP_CMD}" ]; then
  APP_PIDS="$("${PGREP_CMD}" 2>/dev/null || true)"
else
  APP_PIDS="$(pgrep -f "${APP_EXEC}" 2>/dev/null || true)"
fi
APP_PIDS="$(printf '%s\n' "${APP_PIDS}" | grep -E '^[0-9]+$' || true)"
APP_COUNT="$(printf '%s\n' "${APP_PIDS}" | grep -cE '^[0-9]+$' || true)"

if [ "${APP_COUNT}" -eq 0 ]; then
  echo "UNMEASURED: Overture is not running, so there is nothing to sample."
  echo "            Launch it and take the measurement again."
  exit 2
fi
if [ "${APP_COUNT}" -gt 1 ]; then
  echo "UNMEASURED: two copies of Overture are running, pids $(printf '%s' "${APP_PIDS}" | tr '\n' ' ')."
  echo "            Which one this would have measured is not something the pid alone can settle, so it"
  echo "            measures neither. Quit the build you are not measuring and run this again."
  exit 2
fi
APP_PID="${APP_PIDS}"

# --- what else was busy ----------------------------------------------------------------------------
#
# Read on BOTH sides of the sample, never once before it. Measured 2026-09-01: a reading at 20:05 showed
# Lightroom, Synology and Backblaze; one at 20:16 additionally showed ffmpeg at 394% and four Python
# processes at ~45% each; by 20:17 all five had exited. Load here arrives and leaves inside a two minute
# window, so a table read once before the sample describes a moment the measurement is not about (L239).
read_table() {
  if [ -n "${PS_CMD}" ]; then
    "${PS_CMD}" 2>/dev/null
  else
    ps -Ao pcpu,pid,comm -r 2>/dev/null
  fi
}

# Every process at or above the threshold that is neither Overture itself (it is the SUBJECT of the
# measurement, so its own CPU is the thing being measured) nor on the always-present list.
elevated_from() {
  printf '%s\n' "$1" | awk -v cpu="${BUSY_CPU}" -v app="${APP_PID}" -v names="$(printf %s "${BASELINE_NAMES}" | tr '\n' '|')" '
    BEGIN { n = split(names, base, "|") }
    NR == 1 { next }
    {
      pct = $1 + 0
      pid = $2
      if (pct < cpu) next
      if (pid == app) next
      comm = ""
      for (i = 3; i <= NF; i++) comm = comm (i > 3 ? " " : "") $i
      for (i = 1; i <= n; i++) {
        if (base[i] != "" && index(comm, base[i]) > 0) next
      }
      printf "  %6.1f%%  pid %-7s %s\n", pct, pid, comm
    }'
}

TABLE_BEFORE="$(read_table)"
if [ -z "${TABLE_BEFORE}" ]; then
  echo "UNMEASURED: the process table could not be read, so what else this Mac was doing is unknown."
  echo "            That is not the same as nothing else running, and is not recorded as such."
  exit 2
fi
ELEVATED_BEFORE="$(elevated_from "${TABLE_BEFORE}")"

# --- sample ----------------------------------------------------------------------------------------
mkdir -p "${OUT_DIR}" || { echo "UNMEASURED: could not create ${OUT_DIR}"; exit 2; }
STAMP="$(date +%Y%m%d-%H%M%S)"
SAMPLE_OUT="${OUT_DIR}/freeze-measure-${LABEL}-${STAMP}.sample.txt"
RECORD="${OUT_DIR}/freeze-measure-${LABEL}-${STAMP}.json"

# The real interface, checked against /usr/bin/sample itself on 2026-09-01:
#   sample <pid | partial-process-name> [duration [samplingInterval]] [options...] [-file <filename>]
# The output path is NOT a positional argument. Passing it as one, which this script did first, makes
# the real tool read it as the sampling interval in milliseconds and write to a default path instead.
if ! "${SAMPLE_CMD}" "${APP_PID}" "${SECONDS_TO_SAMPLE}" -mayDie -file "${SAMPLE_OUT}" >/dev/null 2>&1; then
  echo "UNMEASURED: sampling pid ${APP_PID} failed, so this run measured nothing."
  echo "            A failed sample is not a quiet reading."
  exit 2
fi

# --- what was busy AFTER, and what ARRIVED while the sample ran --------------------------------------
TABLE_AFTER="$(read_table)"
ELEVATED_AFTER=""
ARRIVED=""
if [ -n "${TABLE_AFTER}" ]; then
  ELEVATED_AFTER="$(elevated_from "${TABLE_AFTER}")"
  # By PID, so the same process merely changing its CPU between the two reads is not reported as new.
  BEFORE_PIDS="$(printf '%s\n' "${ELEVATED_BEFORE}" | awk '{ for (i=1;i<=NF;i++) if ($i == "pid") print $(i+1) }')"
  ARRIVED="$(printf '%s\n' "${ELEVATED_AFTER}" | awk -v seen="$(printf %s "${BEFORE_PIDS}" | tr '\n' '|')" '
    BEGIN { n = split(seen, s, "|") }
    NF == 0 { next }
    {
      pid = ""
      for (i = 1; i <= NF; i++) if ($i == "pid") pid = $(i+1)
      for (i = 1; i <= n; i++) if (s[i] != "" && s[i] == pid) next
      print
    }')"
fi

# The union, deduplicated by pid: anything busy at either end of the sample contaminates it.
ELEVATED="$(printf '%s\n%s\n' "${ELEVATED_BEFORE}" "${ARRIVED}" | grep -v '^[[:space:]]*$' || true)"

if [ -n "${ELEVATED}" ]; then
  VERDICT="elevated"
else
  VERDICT="baseline"
fi

# --- the record --------------------------------------------------------------------------------------
BUNDLE_DATE="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "${APP_EXEC}" 2>/dev/null || echo 'unknown')"
{
  printf '{\n'
  printf '  "label": "%s",\n' "${LABEL}"
  printf '  "measured": "%s",\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
  printf '  "load": "%s",\n' "${VERDICT}"
  printf '  "app_pid": %s,\n' "${APP_PID}"
  printf '  "bundle_built": "%s",\n' "${BUNDLE_DATE}"
  printf '  "busy_cpu_threshold": %s,\n' "${BUSY_CPU}"
  printf '  "baseline_list": "%s",\n' "${BASELINE_FILE}"
  printf '  "sample": "%s",\n' "${SAMPLE_OUT}"
  printf '  "elevated_processes": ['
  if [ -n "${ELEVATED}" ]; then
    printf '\n'
    printf '%s\n' "${ELEVATED}" | sed 's/"/\\"/g; s/^[[:space:]]*/    "/; s/[[:space:]]*$/",/'
    printf '  '
  fi
  printf '],\n'
  printf '  "process_table": "see the sample beside this record"\n'
  printf '}\n'
} > "${RECORD}"

# The full table goes in the record, never to the screen: the screen names only what was UNUSUAL, so a
# reader is not left picking the one line that matters out of the always-present ones.
{
  echo "=== before the sample ==="
  printf '%s\n' "${TABLE_BEFORE}"
  echo
  echo "=== after the sample ==="
  if [ -n "${TABLE_AFTER}" ]; then
    printf '%s\n' "${TABLE_AFTER}"
  else
    echo "(the process table could not be read on this side)"
  fi
} > "${OUT_DIR}/freeze-measure-${LABEL}-${STAMP}.processes.txt"

echo "Measurement ${LABEL}, taken $(date +%Y-%m-%d\ %H:%M)"
echo "  bundle built: ${BUNDLE_DATE}   Overture pid: ${APP_PID}"
echo "  sample:       ${SAMPLE_OUT}"
echo "  record:       ${RECORD}"
if [ "${VERDICT}" = "baseline" ]; then
  echo "  load:         BASELINE. Only the always-present set was above ${BUSY_CPU}% CPU."
  exit 0
fi
echo "  load:         ELEVATED. These were busy and are not on the always-present list:"
printf '%s\n' "${ELEVATED_BEFORE}" | grep -v '^[[:space:]]*$' || true
if [ -n "${ARRIVED}" ]; then
  echo "  and these STARTED during the run, so they were not visible when it began:"
  printf '%s\n' "${ARRIVED}"
fi
echo
echo "  The record is written anyway. This reading is still real; what it is not is comparable"
echo "  against one taken without the above. Retake it when they are done, or keep it and let the"
echo "  comparison carry the caveat."
exit 1
