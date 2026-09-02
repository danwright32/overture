#!/usr/bin/env bash
# Where the "unusually busy" threshold actually lands in this Mac's own recorded load (#3464).
#
# WHY THIS EXISTS. `scripts/freeze-measure.sh` calls a process unusually busy at 25% CPU, and when that
# number was written it said so honestly: CHOSEN, not measured, because there was no distribution of this
# Mac's idle CPU to set it from. Phase 0 has since produced one. This is the command that reads it, so
# the premise behind the threshold is something anybody can re-run rather than a dated sentence somebody
# has to believe (L316, L32).
#
# WHAT IT READS. The `.processes.txt` files `freeze-measure.sh` writes beside every measurement, which
# hold the whole process table at each read. It reads those rather than the `.json` records because the
# tables carry every process, and the records carry only what already crossed the threshold: a reading
# taken through the threshold cannot say whether the threshold is well placed (L70).
#
# WHAT IT JUDGES. Not "is the number right", which nothing can answer, but the one thing L172 names: does
# the threshold sit inside the DENSE part of the distribution, where a small uniform shift carries many
# rows across at once and the count it produces is noise. Three outcomes:
#
#   0  DISCRIMINATING  the threshold is crossed by a small minority of observed rows.
#   1  INSIDE THE BULK the threshold is crossed by more than one row in twenty, so it is not separating
#                      the unusual from the ordinary. A finding to act on, never a refusal.
#   2  UNMEASURED      no recordings, no baseline list, or nothing readable in them. Never folded into 0,
#                      because an empty pile and a pile with nothing unusual in it leave the same empty
#                      result (L98, L11).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT_DIR="${OVERTURE_MEASURE_OUT:-${HOME}/.overture-mac-test-diagnostics}"
BASELINE_FILE="${OVERTURE_MEASURE_BASELINE_FILE:-${SCRIPT_DIR}/../fixtures/resting-baseline.txt}"
BUSY_CPU="${OVERTURE_MEASURE_BUSY_CPU:-25.0}"

# One row in twenty. A JUDGEMENT and labelled as one, which is what #3464 asks for where the number stays
# a judgement call: a threshold crossed by more than a twentieth of everything running is not naming what
# is unusual, it is naming the ordinary case. It sits two orders of magnitude above the reading this Mac
# actually gives (0.17% of rows crossed 25% over the first ten recordings), so it fires on a threshold
# that has genuinely slid into the data rather than on ordinary variation.
CROWDED_SHARE="${OVERTURE_ANALYSE_CROWDED_SHARE:-5.0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) OUT_DIR="${2:-}"; shift 2 ;;
    *) echo "UNMEASURED: unknown argument '$1'"; exit 2 ;;
  esac
done

# --- the always-present set, excluded for the same reason freeze-measure.sh excludes it ---------------
if [ ! -f "${BASELINE_FILE}" ]; then
  echo "UNMEASURED: no resting baseline list at ${BASELINE_FILE}."
  echo "            Without it the always-present daemons enter the distribution and the percentiles"
  echo "            describe a machine nobody is running."
  exit 2
fi
BASELINE_NAMES="$(grep -v '^[[:space:]]*#' "${BASELINE_FILE}" | grep -v '^[[:space:]]*$' || true)"
if [ -z "${BASELINE_NAMES}" ]; then
  echo "UNMEASURED: the resting baseline list at ${BASELINE_FILE} names no processes."
  exit 2
fi

# --- the recordings ----------------------------------------------------------------------------------
TABLES="$(find "${OUT_DIR}" -maxdepth 1 -name 'freeze-measure-*.processes.txt' 2>/dev/null | sort || true)"
TABLE_COUNT="$(printf '%s\n' "${TABLES}" | grep -c . || true)"
if [ "${TABLE_COUNT}" -eq 0 ]; then
  echo "UNMEASURED: no recorded process tables under ${OUT_DIR}."
  echo "            There is nothing to derive a threshold from, which is not the same as a threshold"
  echo "            that looks fine. Take some measurements with scripts/freeze-measure.sh first."
  exit 2
fi

# Every non-baseline, non-Overture row from every recording, as "LABEL<TAB>PCT<TAB>COMM".
#
# Overture's own CPU is left out for freeze-measure.sh's reason: it is the SUBJECT of the measurement, so
# counting it would put the thing being measured into the distribution that judges the measurement.
extract_rows() {
  local file label
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    label="$(basename "${file}")"
    label="${label#freeze-measure-}"
    label="${label%%-20[0-9][0-9][0-9][0-9]*}"
    awk -v label="${label}" -v names="$(printf %s "${BASELINE_NAMES}" | tr '\n' '|')" '
      BEGIN { n = split(names, base, "|") }
      /^===/ { next }
      /^%CPU/ { next }
      !/^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]+[0-9]+[[:space:]]/ { next }
      {
        pct = $1 + 0
        comm = ""
        for (i = 3; i <= NF; i++) comm = comm (i > 3 ? " " : "") $i
        if (index(comm, "Overture.app/Contents/MacOS/Overture") > 0) next
        for (i = 1; i <= n; i++) if (base[i] != "" && index(comm, base[i]) > 0) next
        printf "%s\t%s\t%s\n", label, pct, comm
      }' "${file}"
  done <<< "${TABLES}"
}

ROWS="$(extract_rows)"
ROW_COUNT="$(printf '%s\n' "${ROWS}" | grep -c . || true)"
if [ "${ROW_COUNT}" -eq 0 ]; then
  echo "UNMEASURED: ${TABLE_COUNT} recording(s) under ${OUT_DIR}, and not one readable process row in"
  echo "            them. That is a failed read, not a quiet machine."
  exit 2
fi

# --- the distribution --------------------------------------------------------------------------------
printf 'Recorded load on this Mac, from %s measurement(s) under %s\n' "${TABLE_COUNT}" "${OUT_DIR}"
printf '  %s process rows, excluding Overture itself and the %s always-present name(s) in %s\n\n' \
  "${ROW_COUNT}" "$(printf '%s\n' "${BASELINE_NAMES}" | grep -c .)" "$(basename "${BASELINE_FILE}")"

printf '%s\n' "${ROWS}" | cut -f2 | sort -n | awk -v cpu="${BUSY_CPU}" '
  { v[n++] = $1 + 0 }
  END {
    if (n == 0) exit
    printf "  where the CPU of one process sits, over every row recorded:\n"
    split("50 90 99 99.5 99.9", ps, " ")
    for (i = 1; i <= 5; i++) {
      idx = int(ps[i] / 100 * n); if (idx >= n) idx = n - 1
      printf "    p%-6s %8.2f%%\n", ps[i], v[idx]
    }
    printf "    max     %8.2f%%\n", v[n - 1]
    over = 0
    for (i = 0; i < n; i++) if (v[i] >= cpu) over++
    printf "\n  the threshold in force is %.1f%%, crossed by %d of %d rows (%.2f%%),\n", cpu, over, n, 100 * over / n
    printf "  which puts it at about the %.2f percentile of what this Mac actually runs.\n", 100 * (n - over) / n
  }'

# --- which processes cross it, per measurement -------------------------------------------------------
#
# The percentile alone cannot say whether the line is in the right place. What says it is WHICH processes
# are crossing: a name that crosses in every reading taken while the app was drawing is a property of the
# measurement rather than contamination of it, and belongs on the always-present list instead.
printf '\n  what crosses %.1f%% in each measurement:\n' "${BUSY_CPU}"
printf '%s\n' "${ROWS}" | awk -F'\t' -v cpu="${BUSY_CPU}" '
  ($2 + 0) >= cpu {
    key = $1 SUBSEP $3
    if (!(key in seen)) { seen[key] = 1; if (($2 + 0) > peak[$1 SUBSEP $3]) peak[$1 SUBSEP $3] = $2 + 0 }
    if (($2 + 0) > peak[key]) peak[key] = $2 + 0
    label[$1] = 1
  }
  { all[$1] = 1 }
  END {
    for (l in all) {
      line = ""
      for (k in peak) {
        split(k, parts, SUBSEP)
        if (parts[1] != l) continue
        line = line sprintf("%s %.0f%%, ", parts[2], peak[k])
      }
      if (line == "") line = "nothing, at rest"
      else line = substr(line, 1, length(line) - 2)
      printf "    %-28s %s\n", l, line
    }
  }' | sort

# --- the verdict -------------------------------------------------------------------------------------
CROWDED="$(printf '%s\n' "${ROWS}" | cut -f2 | awk -v cpu="${BUSY_CPU}" -v limit="${CROWDED_SHARE}" '
  { n++; if ($1 + 0 >= cpu) over++ }
  END { print (n > 0 && 100 * over / n > limit) ? "yes" : "no" }')"

if [ "${CROWDED}" = "yes" ]; then
  printf '\n  VERDICT: the threshold is INSIDE THE BULK. More than %.1f%% of everything running crosses\n' "${CROWDED_SHARE}"
  echo "  it, so it is not separating the unusual from the ordinary: a small uniform shift carries many"
  echo "  rows across at once and the count it produces reads as a regression (L172). Raise it, using the"
  echo "  percentiles above, and re-run this."
  exit 1
fi

printf '\n  VERDICT: DISCRIMINATING. The threshold is crossed by well under %.1f%% of what runs here, so\n' "${CROWDED_SHARE}"
echo "  it is naming the unusual rather than the ordinary. Read the per-measurement list above before"
echo "  trusting that: a name crossing in every reading is a candidate for the always-present list"
echo "  rather than evidence the threshold is wrong."
exit 0
