#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains, assert_equals,
# assert_eq, assert_empty (#2501). Haystack second, needle third.
# shellcheck source=lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #2762 (phase 6 of #2620): the measurement session, and the refusals that make it safe to run.
#
# This harness starts two real detached runs at once and counts what the machine actually does. Every
# assertion below is about a REFUSAL, because the refusals are the whole value: the run itself spends
# Dan's usage on real claudes, and the three ways to waste that spend are all silent.
#
#   Pointed at the live handoff directory it would drop two hand-built queues beside Dan's real data and
#   let the app ingest whatever came back.
#   Given overlapping shows it would reproduce the one domain conflict #2765 has not been built yet to
#   prevent, which is precisely the hazard Dan closed by hand rather than by hope (his call, 2026-08-18).
#   Given a small check queue it would measure three concurrent claudes and answer a question nobody
#   asked: `split_queue_into_chunks` makes min(items, MAX_PARALLEL) chunks, so a convenient three-show
#   run never reaches the case in question (L101).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/measure-concurrent-runs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

SUPPORT_DIR="${WORK}/scratch support/Overture"
mkdir -p "${SUPPORT_DIR}"

# A queue of N shows, one item each, with keys prefixed so two queues can be made to overlap or not.
queue_of() {
  prefix="$1"; count="$2"; out="$3"
  {
    printf '{"version":11,"items":['
    i=0
    while [ "${i}" -lt "${count}" ]; do
      [ "${i}" -eq 0 ] || printf ','
      printf '{"naturalKey":"%s-%s","title":"Show %s"}' "${prefix}" "${i}" "${i}"
      i=$((i + 1))
    done
    printf ']}\n'
  } > "${out}"
}

queue_of check 12 "${WORK}/check-queue.json"
queue_of prep 4 "${WORK}/prep-queue.json"
queue_of check 3 "${WORK}/small-check-queue.json"

# A runner that records that it was asked to run and exits, so every path below can be driven without
# launching claude or spending anything.
STUB="${WORK}/stub-runner.sh"
# #3005: the stub now writes the results file its slot really writes, because the harness refuses to
# report a measurement of the wrong CONFIGURATION and reads that answer out of these files. The two
# environment overrides are what let a fixture drive the wrong shapes without a real run.
cat > "${STUB}" <<'STUBEOF'
#!/usr/bin/env bash
slot="${OVERTURE_RUN_SLOT:-prep}"
echo "${slot}" >> "${OVERTURE_SUPPORT_DIR}/stub-launches.txt"
if [[ "${slot}" == "check" ]]; then
  model="${STUB_CHECK_MODEL:-sonnet}"
  streams="${STUB_CHECK_STREAMS:-8}"
else
  model="${STUB_PREP_MODEL:-opus}"
  streams="${STUB_PREP_STREAMS:-1}"
fi
# Production clears the previous results before it starts (`discard_previous_results` in prep-run.sh), so
# the stub does too. Without it, a case driving "this half wrote nothing" would silently read the file the
# PREVIOUS case left behind and be answered by a run that is not the one under test (L58).
rm -f "${OVERTURE_SUPPORT_DIR}/overture-${slot}-results.json"
if [[ "${STUB_WRITE_RESULTS:-1}" == "1" ]]; then
  printf '{"model":"%s","runCost":{"recorded":true,"durationMs":1000,"streams":%s}}\n' \
    "${model}" "${streams}" > "${OVERTURE_SUPPORT_DIR}/overture-${slot}-results.json"
fi
sleep 1
STUBEOF
chmod +x "${STUB}"

run_harness() {
  (
    export OVERTURE_MEASURE_RUNNER="${STUB}"
    export OVERTURE_MEASURE_PROCESS_PATTERN="stub-runner"
    # The fixture's stub is a bash script, so its process NAME is bash and only a command-line match can
    # find it. Production matches the exact name instead, for the reason asserted at the end of this file.
    export OVERTURE_MEASURE_PGREP_MODE="-f"
    "${SCRIPT}" "$@" 2>&1
  )
}

# --- it refuses to run anywhere near the live data ------------------------------------------------
OUT="$(OVERTURE_SUPPORT_DIR="" run_harness --prep-queue "${WORK}/prep-queue.json" \
  --check-queue "${WORK}/check-queue.json")"
assert_contains "an unset support directory is refused" "${OUT}" "OVERTURE_SUPPORT_DIR"

OUT="$(OVERTURE_SUPPORT_DIR="${HOME}/Library/Application Support/Overture" \
  run_harness --prep-queue "${WORK}/prep-queue.json" --check-queue "${WORK}/check-queue.json")"
assert_contains "the live handoff directory is refused by name" "${OUT}" "REFUSING"
assert_contains "and says why, rather than only that it will not" "${OUT}" "live"

# --- it refuses overlapping shows -----------------------------------------------------------------
# Dan's call, 2026-08-18: the measurement needs the two runs to be DISJOINT, because #2765 does not
# exist yet and this is the one window where two runs could take the same show with nothing stopping
# them. #2762 needs the check to carry enough shows, not any particular shows, so the constraint is free.
OUT="$(OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" run_harness \
  --prep-queue "${WORK}/check-queue.json" --check-queue "${WORK}/check-queue.json")"
assert_contains "two queues sharing a show are refused" "${OUT}" "REFUSING"
assert_contains "and the overlapping show is named" "${OUT}" "check-0"

# --- it refuses a check too small to answer the question ------------------------------------------
OUT="$(OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" run_harness \
  --prep-queue "${WORK}/prep-queue.json" --check-queue "${WORK}/small-check-queue.json")"
assert_contains "a check that would not fan out is refused" "${OUT}" "REFUSING"
assert_contains "and says how many shows it needed" "${OUT}" "10"

# --- a valid session plans, and launches nothing without --yes ------------------------------------
rm -f "${SUPPORT_DIR}/stub-launches.txt"
OUT="$(OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" run_harness \
  --prep-queue "${WORK}/prep-queue.json" --check-queue "${WORK}/check-queue.json")"
assert_contains "a valid session reports what it would do" "${OUT}" "would start"
assert_contains "and says this run spends real usage" "${OUT}" "--yes"
if [ -e "${SUPPORT_DIR}/stub-launches.txt" ]; then
  fail "nothing is launched without --yes" "the runner ran anyway"
else
  pass "nothing is launched without --yes"
fi

# --- and with --yes it starts both, counts, and reports -------------------------------------------
rm -f "${SUPPORT_DIR}/stub-launches.txt"
OUT="$(OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" run_harness --yes --sample-seconds 1 \
  --prep-queue "${WORK}/prep-queue.json" --check-queue "${WORK}/check-queue.json")"
assert_contains "both slots are started" "$(cat "${SUPPORT_DIR}/stub-launches.txt" 2>/dev/null)" "check"
assert_contains "including the prep slot" "$(cat "${SUPPORT_DIR}/stub-launches.txt" 2>/dev/null)" "prep"
assert_contains "the peak concurrency is reported" "${OUT}" "peak concurrent"
assert_contains "and the samples are kept as evidence rather than only summarised" "${OUT}" "samples:"

# The evidence is an observed COUNT of concurrent processes, not only a wall clock (L102): a wall clock
# measured while the expensive path never actually overlapped would read as reassurance about the case
# nobody tested.
SAMPLES="$(ls "${SUPPORT_DIR}"/concurrency-samples-*.csv 2>/dev/null | head -1)"
if [ -n "${SAMPLES}" ]; then
  pass "a samples file was written"
  assert_contains "the samples name what was counted" "$(head -1 "${SAMPLES}")" "processes"
else
  fail "a samples file was written" "no concurrency-samples-*.csv in ${SUPPORT_DIR}"
fi

# --- the count is of claude processes, not of anything mentioning claude ------------------------------
# Measured on this Mac 2026-08-18 before the first real session: `pgrep -f claude` returned 4, of which
# THREE were a bash hook and an fswatch whose command lines merely contain a ~/.claude path, and one was a
# real claude. A peak inflated by whatever else happens to name the directory is not evidence, and it
# inflates in the reassuring direction (L102).
assert_contains "production matches the exact process name" \
  "$(cat "${SCRIPT}")" 'OVERTURE_MEASURE_PGREP_MODE:--x}'

# --- and the baseline is recorded, because the machine is never empty ---------------------------------
# The interactive Claude Code session driving this is itself a claude process, so a peak of 11 with one
# already running is ten new ones. Reported rather than silently subtracted: the raw count and what was
# already there are two facts, and folding them would leave nobody able to check the arithmetic.
rm -f "${SUPPORT_DIR}"/concurrency-samples-*.csv
OUT="$(OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" run_harness --yes --sample-seconds 1 \
  --prep-queue "${WORK}/prep-queue.json" --check-queue "${WORK}/check-queue.json")"
assert_contains "the baseline is reported beside the peak" "${OUT}" "already running before it started"
SAMPLES="$(ls "${SUPPORT_DIR}"/concurrency-samples-*.csv 2>/dev/null | head -1)"
assert_contains "and the baseline is in the samples as its own row" \
  "$(cat "${SAMPLES}" 2>/dev/null)" "baseline"

# --- #2981: a stall is judged from the run's own report, not from a phrase in the log -----------------
#
# A run log is not only a record of what happened. Killing the heartbeat subshell made the shell print a
# termination notice rendering the job's whole body, so every log held the runner's own
# `echo "prep: STOPPING. ..."` statement whether or not the guard ever fired. On 2026-08-18 this script's
# bare `grep -q STOPPING` matched that in BOTH logs and reported two healthy runs as stalled, into the
# measurement whose entire purpose is deciding whether to change the stall limit. Neither had stalled:
# both exited 0 with a complete runCost and the longest took 320s against a 1200s limit.
#
# #2981 fixed the cause too (the notice is gone), so this asserts the reading is sound EVEN IF a log ever
# carries the source again, which is the half that survives somebody reintroducing it.
ECHOED_SOURCE='            echo "prep: STOPPING. Nothing new has landed for $(stall_stalled_seconds) s, so this run is not progressing."; exit;'
REAL_REPORT='prep: STOPPING. Nothing new has landed for 1260s (limit 1200s), so this run is not progressing however fresh its marker is.'

STALL_LOG="${WORK}/stall-probe.log"
STALL_PATTERN="$(grep -oE '\^prep: STOPPING[^"]*' "${SCRIPT}" | head -1)"
assert_equals "the stall reading is anchored to the start of a line" "1" \
  "$([ -n "${STALL_PATTERN}" ] && echo 1 || echo 0)"

printf '%s\n' "${ECHOED_SOURCE}" > "${STALL_LOG}"
if grep -q "${STALL_PATTERN}" "${STALL_LOG}"; then MATCHED=1; else MATCHED=0; fi
assert_equals "the runner's own echoed source is NOT read as a stall" "0" "${MATCHED}"

# The positive control, in the same fixture: a log carrying the real report is still read as a stall, so
# the anchoring narrowed the reading rather than switching it off (L159).
printf '%s\n' "${REAL_REPORT}" > "${STALL_LOG}"
if grep -q "${STALL_PATTERN}" "${STALL_LOG}"; then MATCHED=1; else MATCHED=0; fi
assert_equals "a run that really reported a stall is still read as one" "1" "${MATCHED}"

# And the bare pattern the old code used really would have matched the source, so the case above is a
# defect that existed rather than one invented for the test.
printf '%s\n' "${ECHOED_SOURCE}" > "${STALL_LOG}"
if grep -q "STOPPING" "${STALL_LOG}"; then MATCHED=1; else MATCHED=0; fi
assert_equals "the old unanchored pattern really did match the source" "1" "${MATCHED}"

# --- #3005: it refuses to REPORT a measurement of the wrong configuration ----------------------------
#
# On 2026-08-18 the peak, both wall clocks and both cost readings all looked healthy while half the
# session was running the wrong KIND of run entirely (#2980): 15 sonnet lookups rather than 10 lookups
# beside 1 opus drafting run. Nothing here said so, and a person found it by reading prep-run.log. That is
# an instrument that cannot tell you it measured the wrong thing, which is the L98 shape in the place it
# costs most: the reassuring output arrives exactly when the work was not what you asked for.
#
# Each case drives ONE wrong fact and asserts the refusal NAMES it, because a refusal that says only
# "something was wrong" sends the reader back to the logs this exists to save them reading.

measure_queues() {
  echo --prep-queue "${WORK}/prep-queue.json" --check-queue "${WORK}/check-queue.json"
}

# #2980 itself: the drafting half ran as a check, so it was on the lookup model.
# shellcheck disable=SC2046
OUT="$(STUB_PREP_MODEL=sonnet OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" \
  run_harness --yes --sample-seconds 1 $(measure_queues))"
STATUS=$?
assert_contains "a drafting half on the lookup model is refused" "${OUT}" "REFUSED to report"
assert_contains "and the refusal names which half" "${OUT}" "the prep half ran on sonnet"
assert_not_contains "and no peak is printed beside it" "${OUT}" "peak concurrent"
assert_equals "and it does not exit 0" "1" "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

# The other direction: a check half that never fanned out measures one lookup beside a draft, which is a
# different question from the one #2762 asks.
# shellcheck disable=SC2046
OUT="$(STUB_CHECK_STREAMS=1 OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" \
  run_harness --yes --sample-seconds 1 $(measure_queues))"
assert_contains "a check half that did not fan out is refused" "${OUT}" "REFUSED to report"
assert_contains "and says the check half must fan out" "${OUT}" "must FAN OUT"

# And the drafting half fanning out is equally wrong, in the direction the plan cares about: it must stay
# ONE opus stream or the pairing being measured is not the pairing that was asked for.
# shellcheck disable=SC2046
OUT="$(STUB_PREP_STREAMS=6 OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" \
  run_harness --yes --sample-seconds 1 $(measure_queues))"
assert_contains "a drafting half that fanned out is refused" "${OUT}" "REFUSED to report"
assert_contains "and says it must stay one" "${OUT}" "must stay ONE"

# A half that wrote nothing at all cannot be checked, and that is its own answer rather than a pass: an
# unexaminable run and a correct one must never read alike (L98, L11).
# shellcheck disable=SC2046
OUT="$(STUB_WRITE_RESULTS=0 OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" \
  run_harness --yes --sample-seconds 1 $(measure_queues))"
assert_contains "a half that wrote no results is refused" "${OUT}" "REFUSED to report"
assert_contains "and says nothing about it could be checked" "${OUT}" "wrote no results file"

# The positive control, and the one that matters most: the RIGHT configuration still reports. Without it
# every assertion above would pass on a harness that refuses everything, which is indistinguishable from
# one that works (L1, L159).
# shellcheck disable=SC2046
OUT="$(OVERTURE_SUPPORT_DIR="${SUPPORT_DIR}" run_harness --yes --sample-seconds 1 $(measure_queues))"
STATUS=$?
assert_not_contains "the configuration it was built for is NOT refused" "${OUT}" "REFUSED to report"
assert_contains "and its numbers are reported" "${OUT}" "peak concurrent"
assert_equals "and it exits 0" "0" "${STATUS}"

exit "${FAILURES:-0}"
