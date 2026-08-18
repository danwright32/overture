#!/usr/bin/env bash
set -uo pipefail

# #2762 (phase 6 of #2620): start a reachability check and a Prep run at the same time, and measure what
# the machine actually does.
#
# WHAT THIS ANSWERS, and why it has to be measured rather than reasoned about. #2620 asked whether two
# concurrent detached runs hit a plan rate limit. Nobody can answer that from the code: a check already
# fans out to ten concurrent claudes, a prep is one more, and scout-extract (four, fired hourly on its
# own) and reply-classify (one, auto-started at launch) can be going beside them, so the real budget is
# up to sixteen. The two that fire by themselves are the two Dan cannot schedule around.
#
# WHAT IT IS FOR. `PREP_STALL_LIMIT_SECONDS` (1200) and `RunTimeouts.reachabilityProbe` (600) were both
# derived from a SOLO measurement and they STOP a run. A chunk parked on a rate limit writes nothing,
# which is exactly what the stall guard reads as a stall, so the first thing new concurrency can break is
# the guard protecting paid runs, and the kill reads as a normal stop (L51, L36). Those limits get
# re-derived from what this prints, BEFORE #2765 or #2761 ships. That ordering is Dan's call, 2026-08-18.
#
# WHY IT DRIVES THE RUNNERS DIRECTLY rather than the app. The exclusion between the two slots is still in
# force (#2760 kept it; #2765 is what lifts it), so the app refuses to start the second run. Lifting that
# exclusion early, in shipped code, to take a measurement would mean weakening a live safety control for
# a session. Running the two runner scripts against a SCRATCH support directory needs no such change, and
# it measures the thing actually in question, which is the machine rather than the app.
#
# WHAT IT REFUSES, all before anything is spent. Every one of these is a way to spend Dan's usage and
# come home with a number that answers a question nobody asked:
#
#   a support directory that is (or is inside) the live one, which would drop hand-built queues beside
#   his real data and let a running Overture ingest whatever came back;
#   two queues that share a show, which is the one domain conflict #2765 has not been built yet to
#   prevent, closed here by hand because the measurement needs enough shows rather than particular ones;
#   a check queue too small to fan out, because split_queue_into_chunks makes min(items, MAX_PARALLEL)
#   chunks and a three-show run is three claudes, never the case being asked about (L101).
#
# THE EVIDENCE IS A COUNT, not only a wall clock (L102). A run whose two halves never actually overlapped
# produces a perfectly good duration and answers nothing, so the concurrent process count is sampled
# throughout and written out beside the summary rather than only summarised.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREP_QUEUE=""
CHECK_QUEUE=""
CONFIRMED=0
SAMPLE_SECONDS="${OVERTURE_MEASURE_SAMPLE_SECONDS:-5}"

# The runner and the process pattern are injectable so the fixture can drive every refusal, and the
# launch itself, without spending anything. Production values are the real runner and the real binary.
RUNNER="${OVERTURE_MEASURE_RUNNER:-${HERE}/../mac/scripts/prep-run.sh}"
PROCESS_PATTERN="${OVERTURE_MEASURE_PROCESS_PATTERN:-claude}"

# How the pattern is matched, and the default is the whole point. `pgrep -f` searches the full command
# line, and measured on this Mac on 2026-08-18 that returned FOUR processes for "claude", of which three
# were a shell hook and an fswatch whose command lines merely contain a ~/.claude path. A peak inflated by
# whatever else happens to name that directory is not evidence, and it inflates in the reassuring
# direction (L102). `-x` matches the process NAME exactly, which is what a chunk's claude is called.
PGREP_MODE="${OVERTURE_MEASURE_PGREP_MODE:--x}"

# MUST match OVERTURE_PREP_MAX_PARALLEL's default in mac/scripts/prep-run.sh. Read from the environment
# the same way the runner reads it, so a session run with a different cap measures against that cap.
MAX_PARALLEL="${OVERTURE_PREP_MAX_PARALLEL:-10}"

usage() {
  cat <<EOF
Usage: measure-concurrent-runs.sh --prep-queue <file> --check-queue <file> [--yes]
                                  [--sample-seconds N]

  OVERTURE_SUPPORT_DIR must be set to a SCRATCH directory. This refuses to run against the live one.

  Without --yes it plans and launches nothing. With --yes it starts two REAL detached runs, which
  spend real usage on Dan's plan.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prep-queue) PREP_QUEUE="${2:-}"; shift 2 ;;
    --check-queue) CHECK_QUEUE="${2:-}"; shift 2 ;;
    --sample-seconds) SAMPLE_SECONDS="${2:-5}"; shift 2 ;;
    --yes) CONFIRMED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "REFUSING: unknown argument '$1'."; usage; exit 2 ;;
  esac
done

refuse() {
  echo "REFUSING: $1"
  shift
  for line in "$@"; do echo "  ${line}"; done
  exit 2
}

# --- the support directory ------------------------------------------------------------------------

SUPPORT="${OVERTURE_SUPPORT_DIR:-}"
[ -n "${SUPPORT}" ] || refuse "OVERTURE_SUPPORT_DIR is not set." \
  "This starts real runs, and a run with no scratch directory writes into the live handoff folder" \
  "beside Dan's store. Point it somewhere disposable, for example:" \
  "  export OVERTURE_SUPPORT_DIR=\"\$HOME/overture-2762-measure\""

# Both live folders, and anything under them. Compared after resolving, so a path reaching the live
# folder through a symlink or a `..` is refused too rather than passing on its spelling.
resolve() { ( cd "$1" 2>/dev/null && pwd -P ) || echo "$1"; }
mkdir -p "${SUPPORT}" 2>/dev/null || true
SUPPORT_REAL="$(resolve "${SUPPORT}")"
for live in "${HOME}/Library/Application Support/Overture" \
            "${HOME}/Library/Application Support/Overture-Debug"; do
  live_real="$(resolve "${live}")"
  case "${SUPPORT_REAL}/" in
    "${live_real}/"*)
      refuse "OVERTURE_SUPPORT_DIR is the live handoff directory." \
        "  ${SUPPORT_REAL}" \
        "That folder holds Dan's store and the files a running Overture ingests, so a measurement" \
        "run there would put hand-built queues and their answers into his real data." \
        "Use a disposable directory instead."
      ;;
  esac
done

# --- the queues -----------------------------------------------------------------------------------

[ -n "${PREP_QUEUE}" ] && [ -n "${CHECK_QUEUE}" ] || { usage; exit 2; }
[ -f "${PREP_QUEUE}" ] || refuse "no prep queue at ${PREP_QUEUE}"
[ -f "${CHECK_QUEUE}" ] || refuse "no check queue at ${CHECK_QUEUE}"

JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
[ -x "${JQ}" ] || refuse "jq is not available, and every count below is read with it."

# Every show a queue answers for: its items plus the ones a grouped item answers for. The same reading
# prep-run.sh seeds its progress count from, so "how many shows" means one thing here and there.
keys_in() {
  "${JQ}" -r '[.items[] | (.naturalKey // empty), ((.alsoAnswersFor // [])[])] | .[]' "$1" 2>/dev/null
}

PREP_KEYS="$(keys_in "${PREP_QUEUE}")"
CHECK_KEYS="$(keys_in "${CHECK_QUEUE}")"
[ -n "${CHECK_KEYS}" ] || refuse "the check queue names no shows, so this would measure nothing (L98)."
[ -n "${PREP_KEYS}" ] || refuse "the prep queue names no shows, so this would measure nothing (L98)."

CHECK_SHOWS="$(printf '%s\n' "${CHECK_KEYS}" | grep -c .)"
PREP_SHOWS="$(printf '%s\n' "${PREP_KEYS}" | grep -c .)"

OVERLAP="$(printf '%s\n' "${PREP_KEYS}" "${CHECK_KEYS}" | sort | uniq -d)"
[ -z "${OVERLAP}" ] || refuse "the two runs would take the same show." \
  "$(printf '%s' "${OVERLAP}" | tr '\n' ' ')" \
  "#2765 is what makes an overlap safe and it has not been built, so the measurement session closes" \
  "this by hand instead (Dan's call, 2026-08-18). It needs the check to carry ENOUGH shows, never" \
  "particular ones, so making the two sets disjoint costs the measurement nothing."

[ "${CHECK_SHOWS}" -ge "${MAX_PARALLEL}" ] || refuse \
  "the check carries ${CHECK_SHOWS} shows and needs at least ${MAX_PARALLEL}." \
  "split_queue_into_chunks makes min(items, ${MAX_PARALLEL}) chunks, so a smaller check runs fewer" \
  "claudes than the case in question and its number would answer a question nobody asked (L101)."

# --- the plan -------------------------------------------------------------------------------------

STAMP="$(date -u '+%Y%m%d-%H%M%S')"
SAMPLES="${SUPPORT}/concurrency-samples-${STAMP}.csv"

echo "measure-concurrent-runs: would start two runs against ${SUPPORT_REAL}"
echo "  check: ${CHECK_SHOWS} shows (fans out to $((CHECK_SHOWS < MAX_PARALLEL ? CHECK_SHOWS : MAX_PARALLEL)) chunks)"
echo "  prep:  ${PREP_SHOWS} shows"
echo "  the two share no show"
echo "  counting processes named '${PROCESS_PATTERN}' (pgrep ${PGREP_MODE}) every ${SAMPLE_SECONDS}s"

if [ "${CONFIRMED}" -ne 1 ]; then
  echo
  echo "Nothing was started. This spends real usage on Dan's plan, so add --yes to actually run it."
  exit 0
fi

# --- the run --------------------------------------------------------------------------------------

cp "${CHECK_QUEUE}" "${SUPPORT}/overture-check-queue.json"
cp "${PREP_QUEUE}" "${SUPPORT}/overture-prep-queue.json"

# prep-run.sh derives IS_PROBE from this marker's presence, which is what makes the check fan out into
# chunks at all. Written with the size the check was launched with, as the app writes it.
printf '{"version":1,"startedAt":"%s","lookups":%s}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${CHECK_SHOWS}" > "${SUPPORT}/reachability-probe-run.json"

# The machine is never empty. The interactive Claude Code session driving this is itself a claude
# process, so a peak of 11 with one already running means ten new ones. Sampled BEFORE anything starts and
# REPORTED beside the peak rather than silently subtracted: the raw count and what was already there are
# two facts, and folding them into one would leave nobody able to check the arithmetic.
count_processes() { pgrep "${PGREP_MODE}" "${PROCESS_PATTERN}" 2>/dev/null | grep -c . || true; }
BASELINE="$(count_processes)"

started_at="$(date +%s)"

OVERTURE_SUPPORT_DIR="${SUPPORT}" OVERTURE_RUN_SLOT=check "${RUNNER}" &
CHECK_PID=$!
OVERTURE_SUPPORT_DIR="${SUPPORT}" OVERTURE_RUN_SLOT=prep "${RUNNER}" &
PREP_PID=$!

echo "elapsed_s,processes" > "${SAMPLES}"
echo "baseline,${BASELINE}" >> "${SAMPLES}"
peak=0
while kill -0 "${CHECK_PID}" 2>/dev/null || kill -0 "${PREP_PID}" 2>/dev/null; do
  now="$(( $(date +%s) - started_at ))"
  # -c on pgrep counts matches; a pattern matching nothing exits non-zero, which is a count of zero and
  # not an error. Zero is itself a reading worth recording: it is what a run parked on a rate limit
  # looks like from outside.
  count="$(count_processes)"
  [ "${count}" -le "${peak}" ] || peak="${count}"
  echo "${now},${count}" >> "${SAMPLES}"
  sleep "${SAMPLE_SECONDS}"
done

wait "${CHECK_PID}" 2>/dev/null; CHECK_STATUS=$?
wait "${PREP_PID}" 2>/dev/null; PREP_STATUS=$?
elapsed="$(( $(date +%s) - started_at ))"

# --- what it found --------------------------------------------------------------------------------

report_run() {
  slot="$1"; status="$2"
  results="${SUPPORT}/overture-${slot}-results.json"
  echo "  ${slot}: exit ${status}"
  if [ -f "${results}" ]; then
    "${JQ}" -r '"    runCost: recorded=\(.runCost.recorded // "absent") durationMs=\(.runCost.durationMs // "none") streams=\(.runCost.streams // "none") contended=\(.runCost.contended // "ABSENT")"' \
      "${results}" 2>/dev/null || echo "    results file did not parse"
  else
    echo "    no results file: this run wrote nothing at all, which is what a stall stop leaves behind"
  fi
  log="${SUPPORT}/${slot}-run.log"
  if [ -f "${log}" ] && grep -q "STOPPING" "${log}" 2>/dev/null; then
    echo "    STALL GUARD STOPPED THIS RUN. That is the reading #2762 exists for: check whether it was"
    echo "    genuinely stalled or parked waiting on a rate limit before re-deriving the limit."
  fi
}

echo
echo "measure-concurrent-runs: done in ${elapsed}s"
echo "  peak concurrent '${PROCESS_PATTERN}' processes: ${peak}"
echo "  ${BASELINE} were already running before it started, so at most $((peak - BASELINE)) belonged to these two runs"
echo "  samples: ${SAMPLES}"
report_run check "${CHECK_STATUS}"
report_run prep "${PREP_STATUS}"
echo
echo "Record the peak, both wall clocks and both stall outcomes on #2762. Two limits are re-derived from"
echo "them before #2765 or #2761 ships: PREP_STALL_LIMIT_SECONDS and RunTimeouts.reachabilityProbe."
