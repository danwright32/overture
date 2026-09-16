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
# It records a SECOND fact beside that one, and they answer different questions (#3477). The load verdict
# says what the MACHINE was doing; the window verdict says what the APP was doing. Overture is a
# MenuBarExtra app and routinely sits with no window at all: measured 2026-09-02, osascript reported zero
# windows for the running app and a sample taken in that state recorded an app drawing nothing. That
# reading comes back looking excellent and is indistinguishable from a genuinely fast one, which is the
# emptiest possible measurement reading as the cleanest possible result (L98). It has the same three
# shapes as the load verdict, for the same reason: `open`, `none`, and `unknown` when the count could not
# be read, which is never folded into either of the other two.
#
# What it judges the LOAD on is every read it took: one before the sample, one after it, and one every
# POLL_INTERVAL seconds throughout. Anything unusual in ANY of them elevates the reading, because the
# window the measurement is about is the whole sample and not its two edges.
#
# The always-present set is DERIVED from this Mac at rest and recorded in a file carrying its own
# measurement date, never hardcoded here: another Mac, or this one after Dan changes what he runs, would
# otherwise read as permanently ELEVATED and the tool would be useless there (L96, L153).
set -uo pipefail
# #3481/L372: captured BEFORE the cd. `$0` and `BASH_SOURCE[0]` are the path the script was
# INVOKED by, so re-deriving a directory from either after a cd resolves against the NEW working
# directory: it works for one invocation and silently misses for another.
MEASURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${MEASURE_DIR}/.." || exit 1

# shellcheck source=./lib/scratch.sh
. "${MEASURE_DIR}/lib/scratch.sh"
# shellcheck source=./lib/overture-pid.sh
. "${MEASURE_DIR}/lib/overture-pid.sh"

# The full executable path, never the app name or the bundle id. Two builds of Overture can run at once
# and both are called "Overture"; resolving by name once sent a Cmd+W to Dan's live app instead of the
# Debug one it was aimed at.
APP_EXEC="$(overture_app_exec)"

PS_CMD="${OVERTURE_MEASURE_PS:-}"
PGREP_CMD="${OVERTURE_MEASURE_PGREP:-}"
SAMPLE_CMD="${OVERTURE_MEASURE_SAMPLE:-/usr/bin/sample}"
# How many windows the app has open, given its pid (#3477). A seam like every other collaborator that
# touches this Mac, so the fixture never asks System Events about the live app.
WINDOWS_CMD="${OVERTURE_MEASURE_WINDOWS:-}"
SECONDS_TO_SAMPLE="${OVERTURE_MEASURE_SECONDS:-10}"
OUT_DIR="${OVERTURE_MEASURE_OUT:-${HOME}/.overture-mac-test-diagnostics}"
BASELINE_FILE="${OVERTURE_MEASURE_BASELINE_FILE:-${MEASURE_DIR}/../fixtures/resting-baseline.txt}"

# A quarter of one core. It was CHOSEN when it was written, because there was no distribution of this
# Mac's idle CPU to set it from. Phase 0 has since produced one, and #3464 read it: the number is
# unchanged and its premise is now measured rather than assumed.
#
# The premise is recorded as a COMMAND rather than as a dated sentence, because a figure with a date on
# it reads as more trustworthy the older it gets (L316, L32):
#
#     scripts/analyse-freeze-load.sh
#
# What it said over the first eleven recordings: 25% is crossed by 38 of 24,420 recorded process rows,
# 0.16%, which is about the 99.84th percentile of what this Mac runs. The dense part of the distribution
# ends far below it (p99 is 1.9%, p99.5 is 6.4%), so this is nowhere near the dense middle L172 warns
# about, where a small uniform shift carries many rows across at once. That tool re-derives all of it and
# says INSIDE THE BULK if the number ever slides into the data.
#
# It remains a JUDGEMENT at the margin and is labelled as one, which is what #3464 asked to keep: at 25%
# a one-off `launchd` spike of 29% is named, and raising it to 40% would stop naming a competing `claude`
# at 30%, which is real contention. Neither is obviously wrong, so the number stays where the evidence
# puts it rather than being tuned to taste.
BUSY_CPU="${OVERTURE_MEASURE_BUSY_CPU:-25.0}"

# How often the process table is read WHILE the sample runs (#3463). The cost of seeing a burst that
# begins and ends inside the window is one `ps` per interval: measured 2026-09-02 on this Mac, one read
# of `ps -Ao pcpu,pid,comm -r` costs 0.03 to 0.04s, so the default two seconds against a ten second
# sample adds about five reads, under 0.2s spread across the whole window. It is bounded by MAX_POLLS
# below, and how many reads a run actually took is printed and recorded, so the price is measured on
# every run rather than left as an estimate here (L353).
POLL_INTERVAL="${OVERTURE_MEASURE_POLL_SECONDS:-2}"

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

if ! awk -v i="${POLL_INTERVAL}" 'BEGIN { exit !(i + 0 > 0) }'; then
  echo "UNMEASURED: the poll interval '${POLL_INTERVAL}' is not a positive number of seconds."
  echo "            Carrying on with it would read the process table only at the two ends of the sample,"
  echo "            which is the blindness #3463 exists to remove, arriving silently instead."
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
# The rule lives in scripts/lib/overture-pid.sh, shared with scripts/sample-overture.sh so the two
# cannot come to disagree about which Overture they mean (L263, #3424).
APP_PID="$(overture_resolve_pid "${PGREP_CMD}")"
if [ $? -ne 0 ]; then
  echo "UNMEASURED: ${APP_PID}"
  exit 2
fi

# --- what else was busy ----------------------------------------------------------------------------
#
# Read THROUGHOUT the sample, never once before it and never only at its two ends (#3463). Measured
# 2026-09-01: a reading at 20:05 showed Lightroom, Synology and Backblaze; one at 20:16 additionally
# showed ffmpeg at 394% and four Python processes at ~45% each; by 20:17 all five had exited. Load here
# arrives and leaves inside a two minute window, so a table read once before the sample describes a
# moment the measurement is not about (L239), and a pair of end reads still cannot see a burst that
# begins and ends between them.
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

# How many windows Overture has open, on stdout, or nothing at all when that could not be established.
# Costs 0.19 to 0.45s, measured 2026-09-02 against the running app, and is deliberately taken OUTSIDE the
# sample window (once before it, once after) rather than on the poll, so it never perturbs the thing being
# sampled and its cost does not scale with the sample length.
read_windows() {
  local out
  if [ -n "${WINDOWS_CMD}" ]; then
    out="$("${WINDOWS_CMD}" "${APP_PID}" 2>/dev/null)"
  else
    out="$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${APP_PID}) to count windows" 2>/dev/null)"
  fi
  printf '%s' "${out}" | grep -E '^[0-9]+$' || true
}

# The pids named by a block of elevated lines.
pids_of() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i == "pid") print $(i + 1) }'
}

# Lines from $1 whose pid is not in the newline-separated pid list $2, keeping the FIRST line per pid.
# Deduplicating matters now that the same burst can be seen by several polls: without it one ffmpeg is
# reported once per read and the list reads as a machine under far more load than it was.
new_pids_only() {
  printf '%s\n' "$1" | awk -v seen="$(printf %s "$2" | tr '\n' '|')" '
    BEGIN { n = split(seen, s, "|") }
    NF == 0 { next }
    {
      pid = ""
      for (i = 1; i <= NF; i++) if ($i == "pid") pid = $(i + 1)
      if (pid == "") next
      for (i = 1; i <= n; i++) if (s[i] != "" && s[i] == pid) next
      if (pid in emitted) next
      emitted[pid] = 1
      print
    }'
}

TABLE_BEFORE="$(read_table)"
if [ -z "${TABLE_BEFORE}" ]; then
  echo "UNMEASURED: the process table could not be read, so what else this Mac was doing is unknown."
  echo "            That is not the same as nothing else running, and is not recorded as such."
  exit 2
fi
ELEVATED_BEFORE="$(elevated_from "${TABLE_BEFORE}")"
WINDOWS_BEFORE="$(read_windows)"

# --- sample, reading the process table THROUGHOUT rather than at its two ends ------------------------
#
# The two end reads catch load that is already there when the window opens, or still there when it closes.
# What they structurally cannot see is a burst that begins AND ends inside the window, and that is the
# ordinary shape here: measured 2026-09-01, ffmpeg at 394.1% and four Python processes at ~45% each were
# running at 20:16 and all five had exited by 20:17. A default sample is ten seconds, so such a burst sits
# wholly inside one and the reading comes back BASELINE with several cores busy for its whole duration,
# which is the failure that reads as a clean result (L98).
mkdir -p "${OUT_DIR}" || { echo "UNMEASURED: could not create ${OUT_DIR}"; exit 2; }
STAMP="$(date +%Y%m%d-%H%M%S)"
SAMPLE_OUT="${OUT_DIR}/freeze-measure-${LABEL}-${STAMP}.sample.txt"
RECORD="${OUT_DIR}/freeze-measure-${LABEL}-${STAMP}.json"

# The real interface, checked against /usr/bin/sample itself on 2026-09-01:
#   sample <pid | partial-process-name> [duration [samplingInterval]] [options...] [-file <filename>]
# The output path is NOT a positional argument. Passing it as one, which this script did first, makes
# the real tool read it as the sampling interval in milliseconds and write to a default path instead.
"${SAMPLE_CMD}" "${APP_PID}" "${SECONDS_TO_SAMPLE}" -mayDie -file "${SAMPLE_OUT}" >/dev/null 2>&1 &
SAMPLE_PID=$!

# BOUNDED, never open ended: past the bound this stops POLLING and still waits for the sampler, so a
# sampler that never returns fails exactly the way it did before rather than polling forever (L110).
MAX_POLLS="$(awk -v s="${SECONDS_TO_SAMPLE}" -v i="${POLL_INTERVAL}" \
  'BEGIN { n = int(s / i) + 2; if (n < 1) n = 1; print n }')"

# The interval is waited out in SLICES, re-checking the sampler between them, rather than as one sleep.
# A single sleep cannot be interrupted, so every run ended up paying a whole interval of dead time after
# the sample had already finished: with the default two seconds that is two seconds added to each of the
# fixture's nine cases, which is the fixed wait that measures the machine rather than the code (L290).
# `kill -0` is a shell builtin, so the check between slices costs nothing measurable.
POLL_SLICE=0.05
SLICES_PER_POLL="$(awk -v i="${POLL_INTERVAL}" -v w="${POLL_SLICE}" \
  'BEGIN { n = int(i / w + 0.5); if (n < 1) n = 1; print n }')"
POLLS=0
TABLES_DURING=""
ELEVATED_DURING=""
while kill -0 "${SAMPLE_PID}" 2>/dev/null; do
  if [ "${POLLS}" -ge "${MAX_POLLS}" ]; then break; fi
  SAMPLE_ALIVE=1
  SLICE=0
  while [ "${SLICE}" -lt "${SLICES_PER_POLL}" ]; do
    if ! kill -0 "${SAMPLE_PID}" 2>/dev/null; then SAMPLE_ALIVE=0; break; fi
    sleep "${POLL_SLICE}"
    SLICE=$((SLICE + 1))
  done
  if [ "${SAMPLE_ALIVE}" -eq 0 ]; then break; fi
  kill -0 "${SAMPLE_PID}" 2>/dev/null || break
  POLLS=$((POLLS + 1))
  TABLE_POLL="$(read_table)"
  # A poll that could not read the table is skipped rather than ending the polling: the run still has
  # its two end reads, and one failed read is not evidence about the whole window.
  if [ -z "${TABLE_POLL}" ]; then continue; fi
  TABLES_DURING="${TABLES_DURING}
=== during the sample, read ${POLLS} ===
${TABLE_POLL}"
  ELEVATED_DURING="${ELEVATED_DURING}
$(elevated_from "${TABLE_POLL}")"
done

wait "${SAMPLE_PID}"
SAMPLE_STATUS=$?
if [ "${SAMPLE_STATUS}" -ne 0 ]; then
  echo "UNMEASURED: sampling pid ${APP_PID} failed, so this run measured nothing."
  echo "            A failed sample is not a quiet reading."
  exit 2
fi

# --- what was busy AFTER, and what was busy DURING but not at the start -----------------------------
TABLE_AFTER="$(read_table)"
ELEVATED_AFTER=""
if [ -n "${TABLE_AFTER}" ]; then
  ELEVATED_AFTER="$(elevated_from "${TABLE_AFTER}")"
fi

WINDOWS_AFTER="$(read_windows)"

# The window verdict, keyed on the SMALLEST count observed: a sample the app spent any part of with
# nothing on screen is not a measurement of drawing, whichever end that was. Both raw counts go into the
# record, so a reader can tell 0 and 0 from 0 and 1 rather than taking the verdict's word for it.
if [ -z "${WINDOWS_BEFORE}" ] || [ -z "${WINDOWS_AFTER}" ]; then
  WINDOWS_VERDICT="unknown"
elif [ "${WINDOWS_BEFORE}" -eq 0 ] || [ "${WINDOWS_AFTER}" -eq 0 ]; then
  WINDOWS_VERDICT="none"
else
  WINDOWS_VERDICT="open"
fi

# By PID, so the same process merely changing its CPU between reads is not reported as new.
BEFORE_PIDS="$(pids_of "${ELEVATED_BEFORE}")"
ARRIVED="$(new_pids_only "${ELEVATED_DURING}
${ELEVATED_AFTER}" "${BEFORE_PIDS}")"

# The union, deduplicated by pid: anything busy at either end of the sample OR at any point inside it
# contaminates it.
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
  printf '  "process_polls": %s,\n' "${POLLS}"
  printf '  "process_poll_seconds": %s,\n' "${POLL_INTERVAL}"
  printf '  "windows": "%s",\n' "${WINDOWS_VERDICT}"
  printf '  "windows_before": %s,\n' "${WINDOWS_BEFORE:-null}"
  printf '  "windows_after": %s,\n' "${WINDOWS_AFTER:-null}"
  printf '  "baseline_list": "%s",\n' "${BASELINE_FILE}"
  printf '  "sample": "%s",\n' "${SAMPLE_OUT}"
  printf '  "elevated_processes": ['
  if [ -n "${ELEVATED}" ]; then
    printf '\n'
    # The separator goes BETWEEN elements, never after each one (#3483). Appending it to every element
    # leaves a trailing comma, which no JSON parser accepts, and the EMPTY array never reaches this line
    # at all: so a BASELINE record parsed and every ELEVATED one did not, and a reader that skips what it
    # cannot parse kept the clean readings and silently dropped the contaminated ones, which is exactly
    # the population #3442 forbids dropping. Measured 2026-09-02 over the 10 records taken so far: 8
    # unparseable, 2 parseable, and the 2 were the 2 with nothing elevated.
    printf '%s\n' "${ELEVATED}" | awk '
      {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        line[n++] = $0
      }
      END {
        for (i = 0; i < n; i++) printf "    \"%s\"%s\n", line[i], (i < n - 1 ? "," : "")
      }'
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
  if [ -n "${TABLES_DURING}" ]; then
    printf '%s\n' "${TABLES_DURING}"
    echo
  else
    echo "=== during the sample ==="
    echo "(the sample finished before the first poll was due, so there are no mid-run reads)"
    echo
  fi
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
else
  echo "  load:         ELEVATED. These were busy and are not on the always-present list."
  echo "                Read ${POLLS} time(s) during the sample, every ${POLL_INTERVAL}s, plus once at each end."
  if [ -n "$(printf '%s' "${ELEVATED_BEFORE}" | tr -d '[:space:]')" ]; then
    echo "  busy before the sample began:"
    printf '%s\n' "${ELEVATED_BEFORE}" | grep -v '^[[:space:]]*$' || true
  fi
  if [ -n "${ARRIVED}" ]; then
    echo "  and these were busy DURING the run without being there when it began:"
    printf '%s\n' "${ARRIVED}"
  fi
fi

# Said as its own line, never folded into the load verdict: what the machine was doing and what the app
# was doing are two independent readings, and one status field cannot carry both (L53).
case "${WINDOWS_VERDICT}" in
  open)
    echo "  drawing:      a window was open at both ends (${WINDOWS_BEFORE} then ${WINDOWS_AFTER})."
    ;;
  none)
    echo "  drawing:      NO WINDOW open (${WINDOWS_BEFORE:-?} then ${WINDOWS_AFTER:-?}). Overture is a menu bar"
    echo "                app, so this is a real reading of it drawing nothing rather than a fast one."
    echo "                Open the screen Dan freezes on and take it again."
    ;;
  *)
    echo "  drawing:      COULD NOT TELL how many windows were open, so whether this reading is about an"
    echo "                app that was drawing is not something it can answer. That is a different state"
    echo "                from having none open, and it is recorded as one. Grant the terminal automation"
    echo "                access to System Events and take it again, or keep it and carry the caveat."
    ;;
esac

# Exits 0 only when BOTH readings say this measurement is comparable with another.
if [ "${VERDICT}" = "baseline" ] && [ "${WINDOWS_VERDICT}" = "open" ]; then
  exit 0
fi

echo
echo "  The record is written anyway. This reading is still real; what it is not is comparable"
echo "  against one taken without the above. Retake it when they are done, or keep it and let the"
echo "  comparison carry the caveat."
exit 1
