#!/usr/bin/env bash
set -uo pipefail

# #3888: the judging half of scripts/watch-freezes.sh, driven against a stub sampler and built freeze
# logs, so every outcome can be produced rather than waited for.
#
# The tool itself watches a LIVE app for minutes at a time, which is exactly the shape nothing ever
# tests: the scratch version that found #3884 was run by hand, reported what it found, and was deleted
# with its session. So the seams are the point. `--chunks` bounds the run by chunk count instead of by
# minutes, the sampler is a command the caller names, and the process check is a stand-in for `pgrep`,
# which means the refusals, the app-went-away path and the sample-failed path can each be produced here
# rather than waited for on a Mac that happens to be freezing (L1, L151).
#
# The outcome worth guarding hardest is the QUIET one. A watch that ran for an hour and kept nothing is
# the commonest result and the one that reads as a clean bill of health, so it says in its own words
# that it watched and found no qualifying stall, which is a different fact from having measured nothing
# (L98, L11).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="${SCRIPT_DIR}/watch-freezes.sh"
FAILURES=0

WORK="$(fixture_scratch_dir)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

# --- stand-ins ---------------------------------------------------------------------------------
# A pgrep that answers with whatever is in its file, so "no copy", "one copy" and "two copies" are
# each producible.
cat > "${WORK}/pgrep-stub.sh" <<'STUB'
#!/usr/bin/env bash
cat "${STUB_PIDS_FILE}"
STUB
chmod +x "${WORK}/pgrep-stub.sh"

# A `sample` that writes a call graph shaped like the real tool's, and records the arguments it was
# given so the depth argument can be checked at the point it reaches the sampler rather than at the
# point it was parsed (L442).
cat > "${WORK}/sample-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_SAMPLE_ARGS}"
if [ -n "${STUB_SAMPLE_FAILS:-}" ]; then exit 1; fi
out=""
prev=""
for arg in "$@"; do
  if [ "${prev}" = "-file" ]; then out="${arg}"; fi
  prev="${arg}"
done
cat > "${out}" <<'GRAPH'
Analysis of sampling Overture (pid 4242) every 2 milliseconds
Call graph:
    1000 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
      1000 start  (in dyld) + 1
        900 OvertureApp.body  (in Overture) + 12
          880 QueueView.makeRenderData()  (in Overture) + 44
            120 ProducerGate.VenueBrands.init  (in Overture) + 8
        100 idle  (in libsystem_kernel.dylib) + 2
    17 Thread_2
      17 some_worker  (in libdispatch.dylib) + 3
GRAPH
STUB
chmod +x "${WORK}/sample-stub.sh"

export STUB_PIDS_FILE="${WORK}/pids.txt"
export STUB_SAMPLE_ARGS="${WORK}/sample-args.txt"

# A freeze log whose one record lands inside the window this run is watching, so a chunk taken now
# overlaps it. Written in terms of the clock rather than a fixed date, because the overlap test is
# between a chunk's start and a record's timestamp and a dated fixture would stop overlapping the
# moment it aged (L130).
write_log() { # <path> <seconds> <minutes ago>
  local path="$1" seconds="$2" ago="${3:-0}"
  local at
  at="$(python3 -c "import time,datetime;print(datetime.datetime.fromtimestamp(time.time()-${ago}*60,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  printf '{"session":"s","sequence":1,"at":"%s","seconds":%s,"surface":"queue","passes":1,"loadAverage":3.7}\n' \
    "${at}" "${seconds}" > "${path}"
}

# Sets OUT and STATUS rather than printing, because a function whose output is captured runs in a
# subshell and its exit status would be the substitution's, not the tool's (L184).
run_watch() { # extra args...
  OUT="$("${WATCH}" --pgrep "${WORK}/pgrep-stub.sh" --sample-cmd "${WORK}/sample-stub.sh" \
    --chunk-seconds 1 --chunks 1 --since "1970-01-01T00:00:00Z" "$@" 2>&1)"
  STATUS=$?
}

# --- 1. it refuses when it cannot name exactly one Overture --------------------------------------
: > "${STUB_PIDS_FILE}"
run_watch --out "${WORK}/out1" --log "${WORK}/empty.ndjson"; out="${OUT}"
assert_equals "no running Overture is a refusal, not a quiet watch" "2" "${STATUS}"
assert_contains "and it says nothing was watched" "${out}" "REFUSED"

printf '111\n222\n' > "${STUB_PIDS_FILE}"
run_watch --out "${WORK}/out2" --log "${WORK}/empty.ndjson"; out="${OUT}"
assert_equals "two copies is a refusal rather than a guess at which" "2" "${STATUS}"
assert_contains "and it names both pids" "${out}" "111"
assert_contains "and it names both pids" "${out}" "222"

# --- 2. a watch that kept nothing SAYS it kept nothing ---------------------------------------------
printf '%s\n' "$$" > "${STUB_PIDS_FILE}"
: > "${WORK}/empty.ndjson"
run_watch --out "${WORK}/quiet" --log "${WORK}/empty.ndjson"; out="${OUT}"
assert_equals "a quiet watch finishes cleanly" "0" "${STATUS}"
assert_contains "and it states that it watched" "${out}" "WATCH FINISHED"
assert_contains "and that no stall qualified, rather than printing nothing" "${out}" "kept 0 sample"
assert_contains "and it says what kept 0 means, so it cannot be read as having measured nothing" \
  "${out}" "not the same as having measured nothing"
assert_equals "and it leaves no chunk behind" "" "$(ls "${WORK}/quiet"/chunk-* 2>/dev/null)"

# --- 3. a chunk overlapping a long stall is kept, with a one line reading ---------------------------
write_log "${WORK}/stall.ndjson" 6.2 0
run_watch --out "${WORK}/kept" --log "${WORK}/stall.ndjson"; out="${OUT}"
assert_equals "a watch that kept something still finishes cleanly" "0" "${STATUS}"
assert_contains "the stall is reported as it is read" "${out}" "STALL"
assert_contains "the overlapping chunk is kept" "${out}" "KEPT"
assert_contains "and the reading names the main thread total" "${out}" "1000"
assert_contains "and names the deepest frame carrying most of it" "${out}" "makeRenderData"
assert_equals "and exactly one sample file survives" "1" "$(ls "${WORK}/kept"/KEPT-* 2>/dev/null | grep -c . )"

# --- 4. a short stall keeps nothing, and the two thresholds are different quantities ----------------
write_log "${WORK}/short.ndjson" 0.4 0
run_watch --out "${WORK}/short" --log "${WORK}/short.ndjson"; out="${OUT}"
assert_equals "a sub-threshold stall keeps no sample" "0" "${STATUS}"
assert_contains "but it is still reported, because a stall under the keep threshold is still a stall" "${out}" "STALL"
assert_contains "and nothing was kept" "${out}" "kept 0"

# --- 5. the depth reaches the sampler ---------------------------------------------------------------
: > "${STUB_SAMPLE_ARGS}"
run_watch --out "${WORK}/depth" --log "${WORK}/empty.ndjson" --interval-ms 7; out="${OUT}"
assert_equals "an interval argument does not upset the run" "0" "${STATUS}"
assert_contains "and it is what the sampler is actually given" "$(cat "${STUB_SAMPLE_ARGS}")" " 1 7 "

# --- 6. a sampler that fails says so rather than going quiet ------------------------------------------
STUB_SAMPLE_FAILS=1 run_watch --out "${WORK}/failing" --log "${WORK}/empty.ndjson"; out="${OUT}"
assert_contains "a failed sample is announced" "${out}" "SAMPLE FAILED"

# --- 7. the app going away ends the watch and says which pid ------------------------------------------
printf '999999\n' > "${STUB_PIDS_FILE}"
run_watch --out "${WORK}/gone" --log "${WORK}/empty.ndjson" --chunks 3; out="${OUT}"
assert_equals "an app that is gone ends the watch with its own status" "3" "${STATUS}"
assert_contains "and it names the pid it lost" "${out}" "999999"

# --- 8. a sample whose main thread cannot be found is UNREADABLE, never a zero share --------------------
printf '%s\n' "$$" > "${STUB_PIDS_FILE}"
cat > "${WORK}/blank-sample.sh" <<'STUB'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  if [ "${prev}" = "-file" ]; then printf 'nothing useful here\n' > "${arg}"; fi
  prev="${arg}"
done
STUB
chmod +x "${WORK}/blank-sample.sh"
write_log "${WORK}/stall2.ndjson" 6.2 0
out="$("${WATCH}" --pgrep "${WORK}/pgrep-stub.sh" --sample-cmd "${WORK}/blank-sample.sh" \
  --chunk-seconds 1 --chunks 1 --since "1970-01-01T00:00:00Z" --out "${WORK}/unreadable" \
  --log "${WORK}/stall2.ndjson" 2>&1)"
assert_contains "a sample naming no main thread is unreadable, not 0%" "${out}" "UNREADABLE"
assert_not_contains "and it never prints a share it did not measure" "${out}" "0% of"

# --- 8b. by DEFAULT only records written from now on are judged, so a log full of history does not
#         print its history the moment the watch starts, and an old freeze never keeps a fresh chunk.
write_log "${WORK}/history.ndjson" 9.9 30
OUT="$("${WATCH}" --pgrep "${WORK}/pgrep-stub.sh" --sample-cmd "${WORK}/sample-stub.sh" \
  --chunk-seconds 1 --chunks 1 --out "${WORK}/history" --log "${WORK}/history.ndjson" 2>&1)"
STATUS=$?; out="${OUT}"
assert_equals "a watch over a log of old freezes finishes cleanly" "0" "${STATUS}"
assert_not_contains "and does not report a stall that predates it" "${out}" "STALL"
assert_contains "and keeps nothing for it" "${out}" "kept 0"

# --- 8c. a stall that qualifies on DURATION but happened half an hour ago keeps nothing. Without this
#         case, windows and overlap never disagree, and a tool that kept every chunk as soon as any
#         stall qualified would pass every other assertion here (L159).
write_log "${WORK}/old-long.ndjson" 9.9 30
run_watch --out "${WORK}/old-long" --log "${WORK}/old-long.ndjson"; out="${OUT}"
assert_equals "an old long stall still finishes cleanly" "0" "${STATUS}"
assert_contains "it is reported, because it is in the window being judged" "${out}" "STALL"
assert_contains "but the chunk taken now does not cover it, so nothing is kept" "${out}" "kept 0 sample"
assert_equals "and no sample file survives" "" "$(ls "${WORK}/old-long"/KEPT-* 2>/dev/null)"

# --- 9. an unknown argument is refused rather than ignored ----------------------------------------------
out="$("${WATCH}" --nonsense 2>&1)"; status=$?
assert_equals "an unknown argument is refused" "2" "${status}"
assert_contains "and it is named" "${out}" "--nonsense"

# --- 10. a missing freeze log is UNMEASURED, never a quiet watch -----------------------------------------
run_watch --out "${WORK}/nolog" --log "${WORK}/does-not-exist.ndjson"; out="${OUT}"
assert_contains "a missing freeze log is named as such" "${out}" "FREEZE LOG"

if [ "${FAILURES}" -eq 0 ]; then
  echo "All watch-freezes.sh fixtures passed."
else
  echo "${FAILURES} watch-freezes.sh fixture(s) failed."
  exit 1
fi
