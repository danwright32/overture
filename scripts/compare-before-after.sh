#!/usr/bin/env bash
# Compare an opt in cost probe between a BEFORE checkout and an AFTER checkout, in balanced order (#4615).
#
#   scripts/compare-before-after.sh --before <checkout> --after <checkout> \
#     --scope '-only-testing:OvertureTests/MemoPathDerivationCostProbeTests' \
#     --env TEST_RUNNER_MEASURE_4358_E4A=1 [--rounds 4] [--out <dir>]
#   scripts/compare-before-after.sh --analyse <readings.tsv>
#
# WHY IT EXISTS. A probe measures ONE side per run, so a "no slower" claim has always been two runs of it,
# one per checkout, under the one shared test lock, compared by hand. Measured by #4371 (PR #4614,
# 2026-10-08, six rounds of median of 7): whichever side ran SECOND read about 32 ms slower at 4x, in all six
# rounds. A single before then after round therefore reads a change as a regression or hides one, and every
# later E4 and Phase 4b PR quotes that probe as its proof (L395, L656). A rule saying "alternate the order"
# in prose would be a hope (L27), so the comparison runs here and refuses to judge when it cannot.
#
# WHAT IT DOES. Round 1 runs before then after, round 2 after then before, and so on: ABBA. Each run's log is
# kept, and every `probe reading: <metric> <ms>` line in it (printed by `Phase0.Reading.probeLine`, one
# shared fixture at fixtures/probe-reading/lines.txt keeps the two sides agreeing, L26) goes into
# readings.tsv. Then, per metric, over the rounds in which both sides read it exactly once:
#
#   pooled median per side   the median of that side's run medians
#   order effect             half the gap between the after minus before difference in rounds where after ran
#                            second and in rounds where it ran first: how much slower the second run reads
#   order balanced change    the mean of those two group means, in which the order effect cancels
#   spread                   the wider of the two sides' own ranges of run medians
#
# and calls the change SLOWER or FASTER only when it is larger than the spread, WITHIN NOISE otherwise.
#
# WHEN IT REFUSES. A metric with no round in one of the two orders is UNMEASURED, because one order alone
# cannot tell the change from the order the runs went in: one round, every round but one failed, or a metric
# only one side printed. A run that failed or printed no reading is named with its log, never read as a pass
# (L98). `--rounds` must be even and at least 2, refused before anything takes the lock.
#
# Exit 0 no slower (every metric within noise or faster), 1 SLOWER (a measured regression, said even when
# another metric is unmeasured), 2 UNMEASURED or refused.
#
# COST. Every run takes the shared test lock, builds, and runs the probe; four rounds are eight of them. The
# report states how long each took, including any wait for the lock, and the total.
#
# Seams, so its own fixture never takes the lock or waits (L2, L524): OVERTURE_COMPARE_RUN is the command for
# one run (called as `<cmd> <checkout> <scope> [NAME=VALUE ...]`, its output is the log, its exit code the
# run's), OVERTURE_COMPARE_EPOCH prints the current time in whole seconds.
set -uo pipefail
COMPARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/scratch.sh
. "${COMPARE_DIR}/lib/scratch.sh" || { echo "compare-before-after: UNMEASURED: cannot read lib/scratch.sh" >&2; exit 2; }

READING_PREFIX="probe reading: "

usage() {
  sed -n '4,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

refuse() {
  echo "compare-before-after: UNMEASURED: $1" >&2
  exit 2
}

# One run of the probe in <checkout>, through the test runner, with the opt in set.
default_probe_run() {
  local checkout="$1" scope="$2"
  shift 2
  [[ -x "${checkout}/mac/scripts/run-tests-locked.sh" ]] || {
    echo "compare-before-after: no mac/scripts/run-tests-locked.sh in ${checkout}"
    return 2
  }
  (cd "${checkout}" && env "$@" mac/scripts/run-tests-locked.sh "${scope}")
}

epoch_now() {
  if [[ -n "${OVERTURE_COMPARE_EPOCH:-}" ]]; then "${OVERTURE_COMPARE_EPOCH}"; else date +%s; fi
}

# <epoch>: that moment in US Eastern time, which is how every time here is read.
eastern() {
  TZ=America/New_York date -r "$1" '+%Y-%m-%d %H:%M ET' 2>/dev/null \
    || TZ=America/New_York date -d "@$1" '+%Y-%m-%d %H:%M ET'
}

# <log> <round> <position> <side>: the log's reading lines as readings.tsv rows. A value that is not a plain
# number is dropped rather than guessed at, so it shows up as a missing reading.
readings_from_log() {
  awk -v prefix="${READING_PREFIX}" -v round="$2" -v pos="$3" -v side="$4" '
    {
      at = index($0, prefix)
      if (at == 0) next
      n = split(substr($0, at + length(prefix)), f, " ")
      if (n < 2 || f[1] !~ /^[A-Za-z0-9._-]+$/ || f[2] !~ /^[0-9]+(\.[0-9]+)?$/) next
      printf "%s\t%s\t%s\t%s\t%s\n", round, pos, side, f[1], f[2]
    }' "$1"
}

# <readings.tsv>: the per metric report and the verdict, exiting 0, 1 or 2 as the header says.
analyse() {
  awk '
    function sorted_median(arr, n,   s, i, j, t) {
      for (i = 1; i <= n; i++) s[i] = arr[i]
      for (i = 2; i <= n; i++) {
        t = s[i]; j = i - 1
        while (j >= 1 && s[j] > t) { s[j + 1] = s[j]; j-- }
        s[j + 1] = t
      }
      if (n % 2 == 1) return s[(n + 1) / 2]
      return (s[n / 2] + s[n / 2 + 1]) / 2
    }
    function lowest(arr, n,   i, x) { x = arr[1]; for (i = 2; i <= n; i++) if (arr[i] < x) x = arr[i]; return x }
    function highest(arr, n,   i, x) { x = arr[1]; for (i = 2; i <= n; i++) if (arr[i] > x) x = arr[i]; return x }
    BEGIN { FS = "\t"; declared = 0; rounds = 0; nm = 0 }
    $1 == "#rounds" { declared = $2 + 0; next }
    /^#/ { next }
    NF == 5 {
      m = $4
      if (!(m in known)) { known[m] = 1; metrics[++nm] = m }
      key = m SUBSEP $1 SUBSEP $3
      count[key]++
      value[key] = $5 + 0
      if ($3 == "before") beforePos[m SUBSEP $1] = $2
      if ($1 + 0 > rounds) rounds = $1 + 0
    }
    END {
      if (declared > rounds) rounds = declared
      if (nm == 0) { print "VERDICT: UNMEASURED: no probe reading was recorded"; exit 2 }
      slower = ""; unmeasured = 0; within = 0; faster = 0
      for (i = 1; i <= nm; i++) {
        m = metrics[i]
        split("", B); split("", A)
        nb = 0; na = 0; ab = 0; ba = 0; sab = 0; sba = 0; twice = 0; complete = 0; byRound = ""
        for (r = 1; r <= rounds; r++) {
          kb = m SUBSEP r SUBSEP "before"; ka = m SUBSEP r SUBSEP "after"
          cb = (kb in count) ? count[kb] : 0; ca = (ka in count) ? count[ka] : 0
          if (cb > 1 || ca > 1) { twice++; continue }
          if (cb != 1 || ca != 1) continue
          complete++
          b = value[kb]; a = value[ka]; d = a - b
          B[++nb] = b; A[++na] = a
          if (beforePos[m SUBSEP r] == "first") { ab++; sab += d; how = "after second" }
          else { ba++; sba += d; how = "after first" }
          byRound = byRound (byRound == "" ? "" : ", ") sprintf("%+.1f (%s)", d, how)
        }
        if (twice > 0) {
          printf "%s: UNMEASURED: read more than once in one run in %d round(s), so which reading is that run is unknown\n", m, twice
          unmeasured++
          continue
        }
        if (ab < 1 || ba < 1) {
          printf "%s: UNMEASURED: %d complete round(s), %d with before run first and %d with after run first. ", m, complete, ab, ba
          print "One order alone cannot tell the change from the order the runs went in."
          unmeasured++
          continue
        }
        mab = sab / ab; mba = sba / ba
        change = (mab + mba) / 2; order = (mab - mba) / 2
        pb = sorted_median(B, nb); pa = sorted_median(A, na)
        spreadB = highest(B, nb) - lowest(B, nb); spreadA = highest(A, na) - lowest(A, na)
        spread = spreadB > spreadA ? spreadB : spreadA
        if (change > spread) { verdict = "SLOWER"; slower = slower (slower == "" ? "" : ", ") m }
        else if (change < -spread) { verdict = "FASTER"; faster++ }
        else { verdict = "WITHIN NOISE"; within++ }
        printf "%s: %s\n", m, verdict
        printf "  before pooled median %.1f ms over %d runs (%.1f to %.1f)\n", pb, nb, lowest(B, nb), highest(B, nb)
        printf "  after pooled median %.1f ms over %d runs (%.1f to %.1f)\n", pa, na, lowest(A, na), highest(A, na)
        printf "  order effect: the side run second read %.1f ms %s\n", (order < 0 ? -order : order), (order < 0 ? "faster" : "slower")
        percent = pb > 0 ? sprintf(" (%+.1f%%)", change / pb * 100) : ""
        printf "  order balanced difference: %+.1f ms%s, against a spread of %.1f ms\n", change, percent, spread
        printf "  after minus before, round by round: %s\n", byRound
      }
      if (slower != "") { print "VERDICT: SLOWER: " slower; exit 1 }
      if (unmeasured > 0) { printf "VERDICT: UNMEASURED: %d metric(s) could not be compared in balanced order\n", unmeasured; exit 2 }
      printf "VERDICT: NO SLOWER: %d metric(s) within noise, %d faster\n", within, faster
      exit 0
    }' "$1"
}

BEFORE="" AFTER="" SCOPE="" ROUNDS=4 OUT="" ANALYSE=""
ENVS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --before) BEFORE="${2:-}"; shift 2 ;;
    --after) AFTER="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --env) ENVS+=("${2:-}"); shift 2 ;;
    --rounds) ROUNDS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --analyse) ANALYSE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; refuse "unknown argument: $1" ;;
  esac
done

if [[ -n "${ANALYSE}" ]]; then
  [[ -r "${ANALYSE}" ]] || refuse "cannot read ${ANALYSE}"
  analyse "${ANALYSE}"
  exit $?
fi

[[ -n "${SCOPE}" ]] || refuse "--scope is required, naming the probe suite by its type"
[[ -n "${BEFORE}" && -d "${BEFORE}" ]] || refuse "no checkout at ${BEFORE:-<none given>} for --before"
[[ -n "${AFTER}" && -d "${AFTER}" ]] || refuse "no checkout at ${AFTER:-<none given>} for --after"
if ! [[ "${ROUNDS}" =~ ^[0-9]+$ ]] || (( ROUNDS < 2 || ROUNDS % 2 == 1 )); then
  refuse "--rounds must be an even number of at least 2 (got ${ROUNDS}): one round, or an unpaired one, \
cannot tell a change from the order the runs went in"
fi

if [[ -z "${OUT}" ]]; then
  OUT="$(overture_scratch_dir compare-before-after)" || refuse "could not make a scratch directory"
fi
mkdir -p "${OUT}" || refuse "could not make ${OUT}"
READINGS="${OUT}/readings.tsv"
[[ -e "${READINGS}" ]] && refuse "${READINGS} already exists; give a fresh --out rather than mixing two comparisons"
printf '#rounds\t%s\n' "${ROUNDS}" > "${READINGS}" || refuse "could not write ${READINGS}"

side_dir() { if [[ "$1" == before ]]; then echo "${BEFORE}"; else echo "${AFTER}"; fi; }
side_sha() { git -C "$(side_dir "$1")" rev-parse --short HEAD 2>/dev/null || echo "not a git checkout"; }

echo "compare-before-after: ${ROUNDS} rounds in ABBA order (odd rounds run before first, even rounds after first)"
echo "  before: ${BEFORE} ($(side_sha before))"
echo "  after:  ${AFTER} ($(side_sha after))"
echo "  scope:  ${SCOPE} ${ENVS[*]+${ENVS[*]}}"

TOTAL=0
RUNS=0
for (( round = 1; round <= ROUNDS; round++ )); do
  if (( round % 2 == 1 )); then order=(before after); else order=(after before); fi
  for idx in 0 1; do
    side="${order[$idx]}"
    if (( idx == 0 )); then position=first; else position=second; fi
    log="${OUT}/round${round}-${side}.log"
    start="$(epoch_now)"
    if [[ -n "${OVERTURE_COMPARE_RUN:-}" ]]; then
      "${OVERTURE_COMPARE_RUN}" "$(side_dir "${side}")" "${SCOPE}" ${ENVS[@]+"${ENVS[@]}"} > "${log}" 2>&1
    else
      default_probe_run "$(side_dir "${side}")" "${SCOPE}" ${ENVS[@]+"${ENVS[@]}"} > "${log}" 2>&1
    fi
    code=$?
    end="$(epoch_now)"
    took=$(( end - start ))
    TOTAL=$(( TOTAL + took ))
    RUNS=$(( RUNS + 1 ))
    when="started $(eastern "${start}"), took ${took} s"
    label="round ${round}, ${side}, run ${position}"
    if (( code != 0 )); then
      echo "${label}: FAILED with exit ${code}, log ${log} (${when}); its readings are not used"
      continue
    fi
    rows="$(readings_from_log "${log}" "${round}" "${position}" "${side}")"
    if [[ -z "${rows}" ]]; then
      echo "${label}: NO PROBE READING in ${log} (exit 0, ${when}); was the opt in set and the live store there?"
      continue
    fi
    printf '%s\n' "${rows}" >> "${READINGS}"
    echo "${label}: ${when}, $(printf '%s\n' "${rows}" | wc -l | tr -d ' ') reading(s), log ${log}"
  done
done

echo "${RUNS} runs took ${TOTAL} s in all"
echo "readings: ${READINGS}"
analyse "${READINGS}"
