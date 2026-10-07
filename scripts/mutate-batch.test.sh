#!/usr/bin/env bash
set -uo pipefail

# #4295: coverage for `scripts/mutate.sh --batch`, several mutations proved under ONE hold of the shared
# test lock.
#
# Each single mutation runs its own mac/scripts/run-tests-locked.sh, so it queues for the machine wide
# lock once per mutation. Measured 2026-09-27: an agent proving five or six guards per PR spent most of
# four hours or more waiting in that queue, six deep and 10 to 30 minutes a wait, for a few minutes of
# builds. The batch enters the queue once for all of them.
#
# The runner is injected throughout, so no real xcodebuild ever starts here (L2). The lock is a
# throwaway directory, so this fixture never queues behind (or blocks) a real run on this Mac.
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
# shellcheck source=./lib/fixture-process-leak.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture-process-leak.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATE="${HERE}/mutate.sh"
WORK="$(fixture_scratch_dir)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
export OVERTURE_MUTATE_LOG_DIR="${WORK}/mutate-logs"
# An outer mutation that runs this fixture as its runner must not reach the runs in here (L439): its log,
# its runner, and its claim on the shared lock all belong to the outer run.
unset OVERTURE_MUTATE_LOG OVERTURE_MUTATE_RUNNER OVERTURE_MUTATE_DEFAULT_RUNNER OVERTURE_TEST_LOCK_HELD_BY
unset OVERTURE_MUTATE_PREFLIGHT_ONLY
export OVERTURE_DIR_LOCK="${WORK}/xcodebuild-tests.lock"
export OVERTURE_DIR_LOCK_POLL=0.1
export OVERTURE_DIR_LOCK_TIMEOUT=20

SUBJECT="${WORK}/Subject.swift"
write_subject() {
  chmod u+w "${SUBJECT}" 2>/dev/null
  printf 'struct Subject {\n    static let answer = "yes"\n    static let other = "keep"\n}\n' > "${SUBJECT}"
}
ORIGINAL='struct Subject {
    static let answer = "yes"
    static let other = "keep"
}'

X="$(printf '\xe2\x9c\x98')"
STUB_RECORD="${WORK}/stub-record"
STUB_STARTED="${WORK}/stub-started"
# A stand in for the Swift runner that decides what to report from what the mutation left in the file,
# so each entry of one batch can drive a different verdict through ONE runner. It also WITNESSES the lock
# on every call: whether the directory lock is held, who owns it, the claim this run was handed, and a
# marker left inside the lock directory by the first call. The marker surviving to a later call is what
# proves the lock was never released and taken again between entries, independently of anything the batch
# says about itself (L70).
STUB="${WORK}/stub-runner.sh"
cat > "${STUB}" <<STUB
#!/usr/bin/env bash
lock="\${OVERTURE_DIR_LOCK}"
if [ -d "\${lock}" ]; then held=held; else held=MISSING; fi
if [ -e "\${lock}/batch-marker" ]; then marker=same-lock; else marker=first-sight; : > "\${lock}/batch-marker" 2>/dev/null; fi
echo "\${held} \$(cat "\${lock}/owner" 2>/dev/null) claim=\${OVERTURE_TEST_LOCK_HELD_BY:-none} \${marker}" >> "${STUB_RECORD}"
subject="${SUBJECT}"
if grep -q '"hang"' "\${subject}"; then
  echo \$\$ > "${STUB_STARTED}"
  exec /bin/sleep 300
fi
if grep -q '"orphan"' "\${subject}"; then
  # Dies in a way that takes the single form with it before ITS restore can run, so only the batch's own
  # copy can put the file back.
  echo \$\$ > "${STUB_STARTED}"
  trap 'kill -KILL \$PPID; exit 143' TERM
  /bin/sleep 300 &
  wait \$!
  exit 143
fi
if grep -q '"readonly"' "\${subject}"; then
  chmod a-w "\${subject}"
fi
if grep -q '"stalled"' "\${subject}"; then
  echo "run-tests-locked.sh: STALLED AND ENDED. No test started or finished for 1200s."
  exit 1
fi
if grep -q '"caught"' "\${subject}"; then
  echo "${X} Test \"the answer guard\" failed after 0.01 seconds with 1 issue."
  echo "${X} Test run with 12 tests in 2 suites failed after 0.1 seconds with 1 issue."
  exit 1
fi
echo "Test run with 12 tests in 2 suites passed after 0.1 seconds."
exit 0
STUB
chmod +x "${STUB}"

BATCH="${WORK}/three.batch"
write_three_batch() {
  cat > "${BATCH}" <<BATCHFILE
# three proofs of the answer guard
label: the guard fires
file: ${SUBJECT}
at: static let answer
perl: s/"yes"/"caught"/

label: a guard that protects nothing
file: ${SUBJECT}
at: static let answer
perl: s/"yes"/"survived"/

label: the other constant
file: ${SUBJECT}
at: static let other
perl: s/"keep"/"stalled"/
BATCHFILE
}

# --- a batch of three records three verdicts, each with a kept log of its own ---------------------------
write_subject
write_three_batch
: > "${STUB_RECORD}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
STATUS=$?
assert_contains "the first entry is judged CAUGHT" "${OUT}" "1  CAUGHT"
assert_contains "the second is judged SURVIVED" "${OUT}" "2  SURVIVED"
assert_contains "the third is judged STALLED, the single form's own word for it" "${OUT}" "3  STALLED"
assert_contains "the summary names each entry by its label" "${OUT}" "a guard that protects nothing"
LOGS="$(sed -n 's/^.*  log: //p' <<< "${OUT}" | sort -u)"
assert_equals "every entry names a log of its own" "3" "$(grep -c . <<< "${LOGS}")"
assert_contains "in the directory the fixture pointed them at" "${LOGS}" "${WORK}/mutate-logs/"
assert_equals "a batch holding a SURVIVED and a refusal exits 2, never 0" "2" "${STATUS}"
assert_equals "and the subject is exactly as it was" "${ORIGINAL}" "$(cat "${SUBJECT}")"

# --- the lock is taken ONCE, held across every entry, and released at the end ------------------------
RECORD="$(cat "${STUB_RECORD}")"
assert_equals "the runner ran once per entry" "3" "$(grep -c . <<< "${RECORD}")"
assert_not_contains "every run found the shared lock already held" "${RECORD}" "MISSING"
assert_equals "the first run found a fresh lock" "first-sight" "$(head -n 1 <<< "${RECORD}" | awk '{print $NF}')"
assert_equals "and every later run found that SAME lock, never one released and taken again" "2" \
  "$(tail -n +2 <<< "${RECORD}" | grep -c 'same-lock$')"
OWNERS="$(awk '{print $2}' <<< "${RECORD}" | sort -u)"
CLAIMS="$(awk '{print $3}' <<< "${RECORD}" | sort -u)"
assert_equals "one owner for the whole batch" "1" "$(grep -c . <<< "${OWNERS}")"
assert_equals "and every run was told the owner holds it for them" "claim=${OWNERS#overture:}" "${CLAIMS}"
assert_equals "the lock is gone once the batch ends" "no" "$([ -d "${OVERTURE_DIR_LOCK}" ] && echo yes || echo no)"

# --- a custom runner is not the Swift suite, so the batch takes no machine wide lock for it ---------------
# Holding Downbeat's lock while the shell fixtures run would block its tests for nothing.
write_subject
: > "${STUB_RECORD}"
OUT="$(OVERTURE_MUTATE_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
assert_contains "a custom runner still gets every verdict" "${OUT}" "2  SURVIVED"
assert_equals "the runner ran for every entry" "3" "$(grep -c . "${STUB_RECORD}")"
assert_equals "and never found the shared lock held" "0" "$(grep -c '^held ' "${STUB_RECORD}")"
assert_contains "and says it did not" "${OUT}" "takes no shared test lock"

# --- an entry that lands elsewhere is refused on its own and does not stop the others --------------------
write_subject
cat > "${BATCH}" <<BATCHFILE
file: ${SUBJECT}
at: static let answer
perl: s/"yes"/"caught"/

label: aimed at one line, lands on another
file: ${SUBJECT}
at: static let answer
perl: s/"keep"/"moved"/

file: ${SUBJECT}
perl: s/"yes"/"survived"/
BATCHFILE
: > "${STUB_RECORD}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
assert_contains "the misaimed entry is refused as LANDED ELSEWHERE" "${OUT}" "2  LANDED ELSEWHERE"
assert_contains "the entry before it still has its verdict" "${OUT}" "1  CAUGHT"
assert_contains "and so does the entry after it" "${OUT}" "3  SURVIVED"
assert_equals "the misaimed entry never reached the runner, since it was refused before the lock" "2" \
  "$(grep -c . "${STUB_RECORD}")"
assert_equals "and the subject is exactly as it was" "${ORIGINAL}" "$(cat "${SUBJECT}")"

# --- a batch in which every entry is refused never queues for the lock at all ---------------------------
write_subject
printf 'file: %s\nperl: s/nothing-matches-this/x/\n' "${SUBJECT}" > "${BATCH}"
: > "${STUB_RECORD}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
STATUS=$?
assert_contains "an entry that changes nothing is NOT APPLIED" "${OUT}" "1  NOT APPLIED"
assert_contains "and a batch with nothing left to run says it took no lock" "${OUT}" "nothing to run"
assert_equals "the runner never started" "0" "$(grep -c . "${STUB_RECORD}")"
assert_equals "and it exits 2" "2" "${STATUS}"

# --- a malformed batch is refused before anything is touched -------------------------------------------
write_subject
printf 'file: %s\nperl: s/"yes"/"caught"/\nscope: -only-testing:X\n' "${SUBJECT}" > "${BATCH}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
STATUS=$?
assert_contains "an unknown key is refused naming its line" "${OUT}" "MALFORMED BATCH - line 3"
assert_equals "and exits 2" "2" "${STATUS}"
printf 'label: no file here\nperl: s/a/b/\n' > "${BATCH}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
assert_contains "an entry with no file is refused" "${OUT}" "MALFORMED BATCH"
assert_contains "saying what it lacks" "${OUT}" "no file:"
printf '# only a comment\n\n' > "${BATCH}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
assert_contains "a batch holding no entry is refused, never an empty pass (L98)" "${OUT}" "EMPTY BATCH"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${WORK}/missing.batch" 2>&1)"
assert_contains "a batch file that is not there is refused" "${OUT}" "no batch file at"
# A named log would be shared by every entry, so each would overwrite the one before.
write_three_batch
OUT="$(OVERTURE_MUTATE_LOG="${WORK}/one.log" OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
assert_contains "OVERTURE_MUTATE_LOG is refused for a batch" "${OUT}" "OVERTURE_MUTATE_LOG"
unset OVERTURE_MUTATE_LOG

# --- a restore that fails stops the batch and leaves the tree for a person ------------------------------
write_subject
cat > "${BATCH}" <<BATCHFILE
file: ${SUBJECT}
perl: s/"yes"/"caught"/

label: the run takes write permission away
file: ${SUBJECT}
perl: s/"yes"/"readonly"/

label: must never run after that
file: ${SUBJECT}
perl: s/"keep"/"caught"/
BATCHFILE
: > "${STUB_RECORD}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" 2>&1)"
STATUS=$?
assert_contains "a file left changed after an entry is reported loudly" "${OUT}" "RESTORE FAILED"
assert_contains "the entries after it are not run" "${OUT}" "3  NOT RUN"
assert_equals "the runner ran for the first two entries only" "2" "$(grep -c . "${STUB_RECORD}")"
assert_contains "the file is LEFT as it is, for a person" "$(cat "${SUBJECT}")" '"readonly"'
assert_contains "and the untouched copy is kept and named" "${OUT}" "untouched copy:"
KEPT="$(sed -n 's/^.*untouched copy: //p' <<< "${OUT}" | head -n 1)"
assert_equals "the named copy is the file as it was" "${ORIGINAL}" "$(cat "${KEPT}" 2>/dev/null)"
assert_equals "it exits 3, a batch that stopped" "3" "${STATUS}"
assert_equals "and the lock is still released" "no" "$([ -d "${OVERTURE_DIR_LOCK}" ] && echo yes || echo no)"
rm -f "${KEPT}"

# --- Ctrl-C mid batch ends the run in flight, restores the file and releases the lock -------------------
write_subject
cat > "${BATCH}" <<BATCHFILE
file: ${SUBJECT}
perl: s/"yes"/"caught"/

label: hangs until interrupted
file: ${SUBJECT}
perl: s/"yes"/"hang"/

file: ${SUBJECT}
perl: s/"keep"/"caught"/
BATCHFILE
: > "${STUB_RECORD}"
rm -f "${STUB_STARTED}"
# Job control ON, so the batch is started with an ordinary SIGINT disposition: a background job of a shell
# without it starts with SIGINT IGNORED, and a signal ignored on entry cannot be trapped at all.
set -m
OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" > "${WORK}/interrupted.out" 2>&1 &
BATCH_PID=$!
set +m
waited=0
while [[ ! -s "${STUB_STARTED}" && "${waited}" -lt 200 ]]; do sleep 0.1; waited=$((waited + 1)); done
HUNG_PID="$(cat "${STUB_STARTED}" 2>/dev/null)"
assert_contains "the hanging entry is holding the shared lock when it is interrupted" \
  "$([ -d "${OVERTURE_DIR_LOCK}" ] && echo held || echo missing)" "held"
assert_contains "and the subject is mutated at that moment" "$(cat "${SUBJECT}")" '"hang"'
kill -INT "${BATCH_PID}"
waited=0
while kill -0 "${BATCH_PID}" 2>/dev/null && [[ "${waited}" -lt 200 ]]; do sleep 0.1; waited=$((waited + 1)); done
wait "${BATCH_PID}"
STATUS=$?
OUT="$(cat "${WORK}/interrupted.out")"
assert_equals "an interrupted batch exits 130" "130" "${STATUS}"
assert_equals "the subject is restored" "${ORIGINAL}" "$(cat "${SUBJECT}")"
assert_equals "the lock is released" "no" "$([ -d "${OVERTURE_DIR_LOCK}" ] && echo yes || echo no)"
assert_contains "the entry in flight is recorded as interrupted" "${OUT}" "2  INTERRUPTED"
assert_contains "and the one after it as never run" "${OUT}" "3  NOT RUN"
assert_pids_gone "and the run it had started is ended" "${HUNG_PID}"
assert_not_contains "by the entry's own restore, since its whole process group was signalled" \
  "${OUT}" "put it back from its own copy"
assert_equals "the runner never started for the entry after the interrupt" "2" "$(grep -c . "${STUB_RECORD}")"

# --- and when the interrupted entry dies without restoring, the batch puts the file back itself ------------
write_subject
printf 'label: dies before its own restore\nfile: %s\nperl: s/"yes"/"orphan"/\n' "${SUBJECT}" > "${BATCH}"
rm -f "${STUB_STARTED}"
# A TMPDIR of its own inside the work folder: the single form is killed outright here, by design, so its own
# backup scratch file can never be cleaned up by it, and the runner's leak check would rightly name it.
mkdir -p "${WORK}/orphan-tmp"
set -m
TMPDIR="${WORK}/orphan-tmp" OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" > "${WORK}/orphaned.out" 2>&1 &
BATCH_PID=$!
set +m
waited=0
while [[ ! -s "${STUB_STARTED}" && "${waited}" -lt 200 ]]; do sleep 0.1; waited=$((waited + 1)); done
assert_contains "the entry is mutated when it is interrupted" "$(cat "${SUBJECT}")" '"orphan"'
kill -INT "${BATCH_PID}"
waited=0
while kill -0 "${BATCH_PID}" 2>/dev/null && [[ "${waited}" -lt 200 ]]; do sleep 0.1; waited=$((waited + 1)); done
wait "${BATCH_PID}"
STATUS=$?
OUT="$(cat "${WORK}/orphaned.out")"
assert_equals "it still exits 130" "130" "${STATUS}"
assert_contains "the batch says it put the file back from its own copy" "${OUT}" "put it back from its own copy"
assert_equals "and the subject is restored" "${ORIGINAL}" "$(cat "${SUBJECT}")"
assert_equals "and the lock is released" "no" "$([ -d "${OVERTURE_DIR_LOCK}" ] && echo yes || echo no)"

# --- #4568: a scope written WITHOUT -only-testing: refuses the whole batch, once, before anything ------
#
# Measured 2026-10-07: the #4589 agent passed `OvertureTests/SomeSuite` bare to `--batch`, and the runner ran
# the whole pure suite for 16 minutes on the shared lock before it was stopped. The scope is shared by every
# entry, so it is refused ONCE for the batch, before an entry is checked or the lock is queued for.
write_subject
write_three_batch
: > "${STUB_RECORD}"
rm -rf "${OVERTURE_DIR_LOCK}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" OvertureTests/SubjectTests 2>&1)"
STATUS=$?
assert_contains "a bare scope refuses the batch by its own name" "${OUT}" \
  "BARE SCOPE - OvertureTests/SubjectTests was passed as a test scope without its -only-testing: prefix."
assert_contains "naming the exact argument to write instead" "${OUT}" "  -only-testing:OvertureTests/SubjectTests"
assert_equals "said once for the batch, not once per entry" "1" "$(grep -c '^BARE SCOPE - ' <<< "${OUT}")"
assert_not_contains "before any entry is checked" "${OUT}" "batch: checking"
assert_equals "the runner never started" "0" "$(grep -c . "${STUB_RECORD}")"
assert_equals "the shared lock was never taken" "absent" "$([[ -e "${OVERTURE_DIR_LOCK}" ]] && echo present || echo absent)"
assert_equals "it exits 2" "2" "${STATUS}"
assert_equals "and the subject is exactly as it was" "${ORIGINAL}" "$(cat "${SUBJECT}")"

# The same batch WITH the prefix runs, so the refusal above is about the shape and nothing else (L159).
write_subject
: > "${STUB_RECORD}"
OUT="$(OVERTURE_MUTATE_DEFAULT_RUNNER="${STUB}" "${MUTATE}" --batch "${BATCH}" -only-testing:OvertureTests/SubjectTests 2>&1)"
assert_not_contains "a prefixed scope is not refused" "${OUT}" "BARE SCOPE"
assert_contains "and its entries are judged" "${OUT}" "1  CAUGHT"

# --- the single form is untouched by any of this ----------------------------------------------------------
write_subject
OUT="$(OVERTURE_MUTATE_RUNNER="${STUB}" "${MUTATE}" --at 'static let answer' "${SUBJECT}" 's/"yes"/"caught"/' 2>&1)"
assert_contains "one mutation on its own still reads CAUGHT" "${OUT}" "CAUGHT - the suite went red"
assert_not_contains "and prints no batch summary" "${OUT}" "batch summary"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all mutate.sh --batch checks passed"
