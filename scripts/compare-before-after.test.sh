#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #4615: the before and after comparison of an opt in cost probe. What it must never do is give a verdict
# from runs whose ORDER decided the answer: measured by #4371 (PR #4614, 2026-10-08), whichever side ran
# second under the shared test lock read about 32 ms slower at 4x, so one before then after round reads a
# change as a regression or hides one. Driven against a stub runner and a stub clock, never the real test
# lock, and nothing here sleeps (L2, L524).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${SCRIPT_DIR}/compare-before-after.sh"

FAILURES=0
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/before" "${WORK}/after"

# The sampling seam: one probe run. It records which side it was asked for, in order, and prints the probe's
# reading lines with a value set per side, plus a penalty on whichever run of a round goes SECOND, which is
# the order effect #4614 measured. Call N of a round is second when N is even, because every round is two runs.
STUB_RUN="${WORK}/stub-run.sh"
cat > "${STUB_RUN}" <<'STUB'
#!/usr/bin/env bash
side="$(basename "$1")"
echo "${side} $2 ${*:3}" >> "${STUB_CALLS}"
n="$(wc -l < "${STUB_CALLS}" | tr -d ' ')"
if [[ "${STUB_FAIL_CALL:-0}" == "${n}" ]]; then echo "** TEST FAILED **"; exit 65; fi
if [[ "${STUB_SILENT_CALL:-0}" == "${n}" ]]; then echo "e4a memo derivation: not measured."; exit 0; fi
if [[ -n "${STUB_ECHO_FILE:-}" ]]; then cat "${STUB_ECHO_FILE}"; exit 0; fi
penalty=0
(( n % 2 == 0 )) && penalty="${STUB_SECOND_PENALTY:-0}"
# Run to run noise, one whole number per call, so a case can stand for a real machine rather than a clean one.
jitters=( ${STUB_JITTER:-} )
jitter="${jitters[$(( n - 1 ))]:-0}"
if [[ "${side}" == before ]]; then base="${STUB_BEFORE}"; else base="${STUB_AFTER}"; fi
echo "Test measureTheMemoPathDerivation() started."
echo "e4a memo derivation, 4x: 1792 show(s), median of 7 ..."
echo "probe reading: first-draw-4x $(( base + penalty + jitter )).0"
if [[ "${STUB_ONE_SIDED_METRIC:-}" == "${side}" ]]; then echo "probe reading: only-${side} 5.0"; fi
echo "** TEST SUCCEEDED **"
STUB
chmod +x "${STUB_RUN}"

# The clock seam: whole seconds, 300 later on every read, so each run reads as taking 300 seconds.
STUB_EPOCH="${WORK}/stub-epoch.sh"
cat > "${STUB_EPOCH}" <<'STUB'
#!/usr/bin/env bash
t="$(cat "${STUB_CLOCK}")"
echo "${t}"
echo $(( t + 300 )) > "${STUB_CLOCK}"
STUB
chmod +x "${STUB_EPOCH}"

run_compare() {
  local out code
  export STUB_CALLS="${WORK}/calls-$1" STUB_CLOCK="${WORK}/clock-$1"
  : > "${STUB_CALLS}"
  # 2026-10-08 02:13 ET.
  echo 1791440000 > "${STUB_CLOCK}"
  shift
  out="$(OVERTURE_COMPARE_RUN="${STUB_RUN}" OVERTURE_COMPARE_EPOCH="${STUB_EPOCH}" \
    "${SCRIPT}" --before "${WORK}/before" --after "${WORK}/after" \
    --scope '-only-testing:OvertureTests/MemoPathDerivationCostProbeTests' \
    --env TEST_RUNNER_MEASURE_4358_E4A=1 --out "${WORK}/out-${STUB_CALLS##*-}" "$@" 2>&1)"
  code=$?
  printf '%s\nexit=%s\n' "${out}" "${code}"
}

# --- the order: ABBA, and every run asked for the probe it was told to run -----------------------------------
NO_CHANGE="$(STUB_BEFORE=100 STUB_AFTER=100 STUB_SECOND_PENALTY=30 run_compare nochange --rounds 4)"
assert_equals "four rounds run in alternating order, before first on odd rounds and after first on even ones" \
  "before,after,after,before,before,after,after,before" "$(cut -d' ' -f1 "${WORK}/calls-nochange" | paste -sd, -)"
assert_contains "each run gets the scope and the opt in it was given" "$(head -1 "${WORK}/calls-nochange")" \
  "-only-testing:OvertureTests/MemoPathDerivationCostProbeTests TEST_RUNNER_MEASURE_4358_E4A=1"

# --- a change that is not there, behind an order effect, is not read as one ----------------------------------
assert_contains "the order effect is measured and named" "${NO_CHANGE}" \
  "order effect: the side run second read 30.0 ms slower"
assert_contains "pooled medians are reported per side" "${NO_CHANGE}" \
  "before pooled median 115.0 ms over 4 runs (100.0 to 130.0)"
assert_contains "the order balanced difference cancels it, pair by pair" "${NO_CHANGE}" \
  "order balanced difference: +0.0 ms (+0.0%), the mean of 2 pairs (+0.0, +0.0), whose range is 0.0 ms"
assert_contains "and the verdict is within noise" "${NO_CHANGE}" "first-draw-4x: WITHIN NOISE"
assert_contains "a verdict from 2 pairs says how often that many calls a change that is not there" "${NO_CHANGE}" \
  "with 2 pairs, under noise alone this rule calls a change about 1 time in 7"
assert_contains "the round by round differences show what one round alone would have said" "${NO_CHANGE}" \
  "after minus before, round by round: +30.0 (after second), -30.0 (after first), +30.0 (after second), -30.0 (after first)"
assert_contains "overall, no slower" "${NO_CHANGE}" "VERDICT: NO SLOWER"
assert_contains "and exits 0" "${NO_CHANGE}" "exit=0"
assert_contains "each run says when it started, in ET, and how long it took" "${NO_CHANGE}" \
  "round 1, before, run first: started 2026-10-08 02:13 ET, took 300 s"
assert_contains "and the whole comparison's time is stated" "${NO_CHANGE}" "8 runs took 2400 s in all"
assert_contains "the readings are kept where the report says" "${NO_CHANGE}" "readings: ${WORK}/out-nochange/readings.tsv"

# --- a real slowdown behind the same order effect is found -------------------------------------------------
SLOWER="$(STUB_BEFORE=100 STUB_AFTER=150 STUB_SECOND_PENALTY=30 run_compare slower --rounds 4)"
assert_contains "a change larger than the spread is called slower" "${SLOWER}" "first-draw-4x: SLOWER"
assert_contains "with its size" "${SLOWER}" "order balanced difference: +50.0 ms (+43.5%)"
assert_contains "overall, slower, naming the metric" "${SLOWER}" "VERDICT: SLOWER: first-draw-4x"
assert_contains "and exits 1" "${SLOWER}" "exit=1"

FASTER="$(STUB_BEFORE=150 STUB_AFTER=100 STUB_SECOND_PENALTY=30 run_compare faster --rounds 4)"
assert_contains "a change the other way is called faster" "${FASTER}" "first-draw-4x: FASTER"
assert_contains "faster is no slower and exits 0" "${FASTER}" "exit=0"

# --- a real change SMALLER than the order effect, on a noisy machine (the review of 4b36ad1e) ---------------
# The shape #4614 measured: about 32 ms of order effect at 4x, with a few ms of run to run noise. Judged against
# the raw range of each side's run medians, which still carries the order penalty (37 ms here), a real 15 ms
# slowdown read WITHIN NOISE and exited 0: the "hides one" failure this tool exists to stop (L172, L209).
NOISE="3 0 5 1 2 4 0 3 1 5 2 0"
HIDDEN="$(STUB_BEFORE=1350 STUB_AFTER=1365 STUB_SECOND_PENALTY=32 STUB_JITTER="${NOISE}" \
  run_compare hidden --rounds 6)"
assert_contains "a real 15 ms slowdown under a 32 ms order effect is called slower" "${HIDDEN}" "first-draw-4x: SLOWER"
assert_contains "every pair carries it, and their range is small" "${HIDDEN}" \
  "order balanced difference: +16.0 ms (+1.2%), the mean of 3 pairs (+15.5, +14.5, +18.0), whose range is 3.5 ms"
assert_contains "the order effect is still named beside it" "${HIDDEN}" "order effect: the side run second read 32.0 ms slower"
assert_contains "and the comparison exits 1" "${HIDDEN}" "exit=1"

# The same machine with no change at all: the order effect alone is never a change.
ORDER_ONLY="$(STUB_BEFORE=1350 STUB_AFTER=1350 STUB_SECOND_PENALTY=32 STUB_JITTER="${NOISE}" \
  run_compare orderonly --rounds 6)"
assert_contains "the order effect alone, under the same noise, is within noise" "${ORDER_ONLY}" "first-draw-4x: WITHIN NOISE"
assert_contains "because the pairs disagree in sign" "${ORDER_ONLY}" "the mean of 3 pairs (+0.5, -0.5, +3.0)"
assert_contains "and the comparison exits 0" "${ORDER_ONLY}" "exit=0"

# --- too few rounds, or an odd count, is refused before anything runs --------------------------------------
ONE="$(STUB_BEFORE=100 STUB_AFTER=100 run_compare one --rounds 1)"
assert_contains "one round is refused" "${ONE}" "UNMEASURED: --rounds must be an even number of at least 4"
assert_contains "and exits 2" "${ONE}" "exit=2"
assert_empty "and no probe ran" "$(cat "${WORK}/calls-one")"
TWO="$(STUB_BEFORE=100 STUB_AFTER=100 run_compare two --rounds 2)"
assert_contains "two rounds, one pair with no range to judge against, are refused" "${TWO}" \
  "UNMEASURED: --rounds must be an even number of at least 4"
assert_empty "and no probe ran" "$(cat "${WORK}/calls-two")"
ODD="$(STUB_BEFORE=100 STUB_AFTER=100 run_compare odd --rounds 5)"
assert_contains "an odd count is refused too" "${ODD}" "UNMEASURED: --rounds must be an even number of at least 4"
assert_empty "and no probe ran" "$(cat "${WORK}/calls-odd")"

# --- a run that failed or measured nothing leaves one pair: no verdict -------------------------------------
FAILED="$(STUB_BEFORE=100 STUB_AFTER=100 STUB_FAIL_CALL=4 run_compare failed --rounds 4)"
assert_contains "a failed run is named with its log" "${FAILED}" \
  "round 2, before, run second: FAILED with exit 65, log ${WORK}/out-failed/round2-before.log"
assert_contains "the metric left with one complete pair is unmeasured" "${FAILED}" \
  "first-draw-4x: UNMEASURED: 1 complete pair(s) of rounds, from 2 round(s) with before run first and 1 with after run first"
assert_contains "overall unmeasured" "${FAILED}" "VERDICT: UNMEASURED"
assert_contains "and exits 2" "${FAILED}" "exit=2"
assert_not_contains "never a verdict" "${FAILED}" "VERDICT: NO SLOWER"

SILENT="$(STUB_BEFORE=100 STUB_AFTER=100 STUB_SILENT_CALL=3 run_compare silent --rounds 4)"
assert_contains "a run that printed no reading is said as that, not as a pass" "${SILENT}" \
  "round 2, after, run first: NO PROBE READING in ${WORK}/out-silent/round2-after.log"
assert_contains "and leaves the comparison unmeasured" "${SILENT}" "VERDICT: UNMEASURED"

ONESIDED="$(STUB_BEFORE=100 STUB_AFTER=100 STUB_ONE_SIDED_METRIC=after run_compare onesided --rounds 4)"
assert_contains "a metric only one side printed is unmeasured" "${ONESIDED}" "only-after: UNMEASURED: 0 complete pair(s)"
assert_contains "while a metric both printed still gets its verdict" "${ONESIDED}" "first-draw-4x: WITHIN NOISE"
assert_contains "and the comparison as a whole is unmeasured" "${ONESIDED}" "exit=2"

# --- the reading line is the one the probe prints (one fixture both sides read, L26) ------------------------
ECHOED="$(STUB_BEFORE=0 STUB_AFTER=0 STUB_ECHO_FILE="${REPO_ROOT}/fixtures/probe-reading/lines.txt" \
  run_compare echoed --rounds 4)"
assert_contains "the shared fixture's lines are read as readings" "$(cat "${WORK}/out-echoed/readings.tsv")" \
  "$(printf '1\tfirst\tbefore\tfirst-draw-4x\t2.000')"
assert_contains "every line of it" "$(cat "${WORK}/out-echoed/readings.tsv")" \
  "$(printf '1\tfirst\tbefore\tmemo-derivation-1x\t314.750')"
# #4617: the fixture's order lines, written by Phase0.orderLine, reach the report through the real log parser.
assert_contains "an order line is kept beside the readings, with the side that said it" \
  "$(cat "${WORK}/out-echoed/readings.tsv")" "$(printf '#order\talternated\ttoday-1x,generic-value-1x\tbefore')"
assert_contains "an alternated group is reported once, as balanced" "${ECHOED}" \
  "ORDER INSIDE A RUN: alternated for today-1x, generic-value-1x (said by both sides): their samples were taken in rotating order"
assert_contains "a fixed group is reported as unbalanced, never left silent" "${ECHOED}" \
  "ORDER INSIDE A RUN: UNBALANCED for whole-live-clone, dry-run-live-clone (said by both sides): timed one after another in the same order"
assert_equals "each group is reported once however many runs said it" "2" \
  "$(grep -c '^ORDER INSIDE A RUN' <<< "${ECHOED}")"
assert_contains "and an order line is not counted as a reading" "${ECHOED}" "round 1, before, run first: started 2026-10-08 02:13 ET, took 300 s, 2 reading(s)"

# A probe whose order changed between the two checkouts says so per side, and a malformed line is dropped.
ORDERS="${WORK}/orders.tsv"
{
  printf '#rounds\t4\n'
  printf '%s\t%s\t%s\tarm-a\t%s\n' 1 first before 10 1 second after 10 2 first after 10 2 second before 10 \
    3 first before 10 3 second after 10 4 first after 10 4 second before 10
  printf '#order\tfixed\tarm-a,arm-b\tbefore\n#order\talternated\tarm-a,arm-b\tafter\n'
} > "${ORDERS}"
ORDERS_ANALYSED="$("${SCRIPT}" --analyse "${ORDERS}" 2>&1; echo "exit=$?")"
assert_contains "the before side's fixed order is named as the before side's" "${ORDERS_ANALYSED}" \
  "ORDER INSIDE A RUN: UNBALANCED for arm-a, arm-b (said by the before side only)"
assert_contains "and the after side's alternation as the after side's" "${ORDERS_ANALYSED}" \
  "ORDER INSIDE A RUN: alternated for arm-a, arm-b (said by the after side only)"
assert_contains "the order lines change no verdict" "${ORDERS_ANALYSED}" "exit=0"
MALFORMED="${WORK}/malformed.log"
printf 'probe reading: a 1.0\nprobe order: sideways a,b\nprobe order: fixed lonely\nprobe order: fixed a b\nprobe order: fixed a,b\n' \
  > "${MALFORMED}"
STUB_BEFORE=0 STUB_AFTER=0 STUB_ECHO_FILE="${MALFORMED}" run_compare malformed --rounds 4 > /dev/null
assert_equals "only a well formed order line is read, once per run" "8" \
  "$(grep -c '^#order' "${WORK}/out-malformed/readings.tsv")"
assert_equals "and it is the well formed one" "0" \
  "$(grep '^#order' "${WORK}/out-malformed/readings.tsv" | grep -vc "$(printf '^#order\tfixed\ta,b\t')")"

# --- the analysis on #4614's own six rounds, first draw at 4x (L48: measured, not shaped) ------------------
PR4614="${WORK}/pr4614.tsv"
{
  printf '#rounds\t6\n'
  printf '%s\t%s\t%s\tfirst-draw-4x\t%s\n' \
    1 first before 1347.8   1 second after 1406.0 \
    2 first before 1341.0   2 second after 1384.5 \
    3 first before 1346.8   3 second after 1386.7 \
    4 first after 1338.6    4 second before 1370.7 \
    5 first after 1365.6    5 second before 1368.2 \
    6 first after 1359.2    6 second before 1377.3
  printf '%s\t%s\t%s\tmemo-derivation-4x\t%s\n' \
    1 first before 1341.0   1 second after 1402.1 \
    2 first before 1339.7   2 second after 1385.5 \
    3 first before 1353.5   3 second after 1327.6 \
    4 first after 1345.9    4 second before 1366.1 \
    5 first after 1353.1    5 second before 1379.5 \
    6 first after 1346.5    6 second before 1360.2
} > "${PR4614}"
ANALYSED="$("${SCRIPT}" --analyse "${PR4614}" 2>&1; echo "exit=$?")"
assert_contains "the order effect #4614 worked out by hand" "${ANALYSED}" \
  "order effect: the side run second read 32.4 ms slower"
assert_contains "and its order balanced difference, from three pairs that all moved the same way" "${ANALYSED}" \
  "order balanced difference: +14.8 ms (+1.1%), the mean of 3 pairs (+13.0, +20.4, +10.9), whose range is 9.5 ms"
assert_contains "so #4614's first draw at 4x was a real slowdown, which its own table called noise" "${ANALYSED}" \
  "first-draw-4x: SLOWER"
assert_contains "the before side pools to #4614's figure" "${ANALYSED}" "before pooled median 1358.0 ms over 6 runs"
assert_contains "while its memo derivation, whose pairs disagree in sign, is within noise" "${ANALYSED}" \
  "memo-derivation-4x: WITHIN NOISE"
assert_contains "and the verdict names the one that moved" "${ANALYSED}" "VERDICT: SLOWER: first-draw-4x"
assert_contains "exiting 1" "${ANALYSED}" "exit=1"

# The same data's first round alone, which is what a single before then after pair would have quoted.
FIRST_ONLY="${WORK}/first-only.tsv"
{ printf '#rounds\t1\n'; grep -E '^1	' "${PR4614}"; } > "${FIRST_ONLY}"
FIRST_ANALYSED="$("${SCRIPT}" --analyse "${FIRST_ONLY}" 2>&1; echo "exit=$?")"
assert_contains "one round of real data gets no verdict" "${FIRST_ANALYSED}" \
  "first-draw-4x: UNMEASURED: 0 complete pair(s) of rounds, from 1 round(s) with before run first and 0 with after run first"
assert_not_contains "though on its face it reads 58.2 ms slower" "${FIRST_ANALYSED}" "SLOWER"
assert_contains "and exits 2" "${FIRST_ANALYSED}" "exit=2"

EMPTY="${WORK}/empty.tsv"
printf '#rounds\t4\n' > "${EMPTY}"
EMPTY_ANALYSED="$("${SCRIPT}" --analyse "${EMPTY}" 2>&1; echo "exit=$?")"
assert_contains "a comparison holding no reading at all is unmeasured, never no slower" "${EMPTY_ANALYSED}" \
  "VERDICT: UNMEASURED: no probe reading was recorded"
assert_contains "and exits 2" "${EMPTY_ANALYSED}" "exit=2"

# --- refusals on the arguments -----------------------------------------------------------------------------
MISSING="$(OVERTURE_COMPARE_RUN="${STUB_RUN}" "${SCRIPT}" --before "${WORK}/nowhere" --after "${WORK}/after" \
  --scope x 2>&1; echo "exit=$?")"
assert_contains "a checkout that is not there is refused by name" "${MISSING}" "no checkout at ${WORK}/nowhere"
assert_contains "and exits 2" "${MISSING}" "exit=2"
NOSCOPE="$(OVERTURE_COMPARE_RUN="${STUB_RUN}" "${SCRIPT}" --before "${WORK}/before" --after "${WORK}/after" 2>&1; \
  echo "exit=$?")"
assert_contains "a comparison with no scope is refused" "${NOSCOPE}" "--scope is required"

# An option given LAST with no value once left `shift 2` failing with one argument left, so the loop never
# ended and the script hung (L110). Each shape runs under a deadline, perl's alarm, so a regression fails
# here as killed instead of hanging the fixture; a correct refusal returns at once, so nothing waits.
for option in --before --after --scope --env --rounds --out --analyse; do
  BARE="$(OVERTURE_COMPARE_RUN="${STUB_RUN}" perl -e 'alarm shift; exec @ARGV' 10 "${SCRIPT}" "${option}" 2>&1; \
    echo "exit=$?")"
  assert_contains "${option} given last with no value is refused by name" "${BARE}" \
    "UNMEASURED: ${option} needs a value, and none was given"
  assert_contains "${option} given last with no value exits 2 rather than hanging" "${BARE}" "exit=2"
done

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All compare-before-after.sh fixtures passed."
