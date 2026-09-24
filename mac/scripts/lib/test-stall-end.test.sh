#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary (#2501): pass, fail, assert_contains (desc, haystack, needle),
# assert_not_contains, assert_eq, assert_empty, assert_pids_gone.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #3976: a test run that has STOPPED holding the shared lock is ENDED, by the runner, by the pids it
# started, and the lock is released.
#
# Measured twice on this Mac. 2026-09-17: a run hung for 2h50m holding the lock and starved every run
# queued behind it, in two projects. 2026-09-19: 38 minutes, ended only because somebody was watching,
# with the signature that decides the design here:
#
#   xcodebuild  pid 4483  0.0% cpu   0:01.33 cpu-time over 38 minutes elapsed
#
# So "no progress" is two readings together, neither of which is enough alone: no test line started or
# finished, AND xcodebuild itself has barely used the CPU. Its OWN time rather than its tree's: xctest
# is its child, and on 2026-09-17 xctest was the busy one, repeating a CoreData retry thousands of times.
#
# Every clock here is injectable. The guard counts its OWN ticks rather than reading a clock (the
# run-stall-guard.sh reasoning, L82), so a `sleep` on PATH that scales every sleep by one factor leaves
# every relationship the guard depends on intact and makes a twenty minute limit cost a fraction of a
# second (L290, L524).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

# shellcheck source=./test-stall-end.sh
source "${SCRIPT_DIR}/test-stall-end.sh"

TMP_DIR="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Reading CPU time the way ps prints it
# ---------------------------------------------------------------------------
# macOS `ps -o time=` prints minutes that run past 59 ("32:54.80" for launchd on this Mac, measured
# 2026-09-24), and a day prefix is possible on a long lived process. Hundredths, so no float arithmetic.
assert_eq "the measured hang's own reading" "133" "$(cpu_time_centis "0:01.33")"
assert_eq "minutes past an hour, as macOS prints them" "197480" "$(cpu_time_centis "32:54.80")"
assert_eq "an hours field" "372345" "$(cpu_time_centis "1:02:03.45")"
assert_eq "a day prefix" "8640000" "$(cpu_time_centis "1-00:00:00")"
assert_eq "whole seconds with no fraction" "500" "$(cpu_time_centis "0:05")"
assert_eq "anything else is no reading, never zero (L50)" "" "$(cpu_time_centis "garbage")"
assert_eq "and an empty one is no reading either" "" "$(cpu_time_centis "")"

assert_eq "a short time reads in seconds" "1.33s" "$(centis_readable 133)"
assert_eq "a long one in minutes" "12m 3s" "$(centis_readable 72300)"

# ---------------------------------------------------------------------------
# Which processes are the run's, from one snapshot of the process table
# ---------------------------------------------------------------------------
# 100 is the flock the runner started, leading its own group. 101 is xcodebuild, its child. 102 is a
# grandchild. 103 was reparented to launchd but is still in the run's group. 200 is somebody else.
TABLE="    1     0     1  32:54.80
  100    50   100   0:00.01
  101   100   100   0:01.33
  102   101   100   0:10.00
  103     1   100   0:00.50
  200     1   200   5:00.00"
assert_eq "the holder is flock's child, found by parent pid rather than by any command text (L1011)" \
  "101" "$(process_children "${TABLE}" 100)"
assert_eq "the run's CPU is its descendants and its group, and nobody else's" \
  "1184" "$(run_tree_cpu_centis "${TABLE}" 100)"
assert_eq "one process's own CPU" "133" "$(process_cpu_centis "${TABLE}" 101)"
assert_eq "a process that is not in the table has no reading, which is how a dead one reads" \
  "" "$(run_tree_cpu_centis "${TABLE}" 999)"
assert_eq "a group is read from the table" "100" "$(process_group_of "${TABLE}" 102)"

# Movement is CPU crossing the floor since the last movement, or CPU going DOWN, which is a child
# finishing and taking its time with it: activity, never a stall.
cpu_moved 100 700 500 && pass "CPU past the floor is movement" || fail "CPU past the floor is movement"
cpu_moved 100 400 500 && fail "a trickle under the floor is not movement" \
  || pass "a trickle under the floor is not movement"
cpu_moved 900 400 500 && pass "CPU going down is a child finishing, which is movement" \
  || fail "CPU going down is a child finishing, which is movement"

# ---------------------------------------------------------------------------
# The lock give-up: a dead holder and a live but stalled one are different, and say so
# ---------------------------------------------------------------------------
# On 2026-09-17 the give-up said "a run that died holding it" while xcodebuild, its flock and an xctest
# child were all alive, so the reader went looking for a corpse. The holder here is the runner shell
# (overture:<pid>), whose own CPU is always near zero, so the reading is its whole tree.
HOLDER_START="  500    40   500   0:00.02
  501   500   501   0:00.01
  502   501   501   1:00.00"
HOLDER_STILL="  500    40   500   0:00.02
  501   500   501   0:00.01
  502   501   501   1:00.40"
HOLDER_BUSY="  500    40   500   0:00.02 bash
  501   500   501   0:00.01 flock
  502   501   501   3:00.00 xctest"
STALLED_REPORT="$(lock_holder_report "overture:500" "${HOLDER_START}" "${HOLDER_STILL}" 1800 /tmp/x.lock)"
assert_contains "a live holder that did nothing over the wait is called stalled, not dead" \
  "${STALLED_REPORT}" "ALIVE but STALLED"
assert_contains "naming its PID" "${STALLED_REPORT}" "PID 500"
assert_contains "and the CPU it used over the wait, which is the whole diagnosis" \
  "${STALLED_REPORT}" "0.40s of CPU over the 1800s"
assert_contains "and its CPU in total" "${STALLED_REPORT}" "1m 0s in total"
assert_contains "with the remedy that works: the group, not the pid (L321)" \
  "${STALLED_REPORT}" "kill -TERM -500"
assert_not_contains "and it never tells a live holder's reader to look for a corpse" \
  "${STALLED_REPORT}" "a run that died holding it"

BUSY_REPORT="$(lock_holder_report "overture:500" "${HOLDER_START}" "${HOLDER_BUSY}" 1800 /tmp/x.lock)"
assert_contains "a live holder that used real CPU is working, just long" \
  "${BUSY_REPORT}" "ALIVE and WORKING"
assert_not_contains "and is not called stalled" "${BUSY_REPORT}" "STALLED"
assert_contains "and names what used the CPU, so a spinning test process beside a still xcodebuild shows" \
  "${BUSY_REPORT}" "most of it PID 502 (xctest, 2m 0s)"

DEAD_REPORT="$(lock_holder_report "downbeat:777" "${HOLDER_START}" "${HOLDER_STILL}" 1800 /tmp/x.lock)"
assert_contains "a holder that is gone is called dead" "${DEAD_REPORT}" "PID 777"
assert_contains "in those words" "${DEAD_REPORT}" "is NOT running"

NO_OWNER_REPORT="$(lock_holder_report "" "${HOLDER_START}" "${HOLDER_STILL}" 1800 /tmp/x.lock)"
assert_contains "an unreadable owner is said to be unreadable, rather than guessed at" \
  "${NO_OWNER_REPORT}" "cannot be named"

LATE_REPORT="$(lock_holder_report "overture:502" "  1 0 1 0:00.00" "${HOLDER_STILL}" 1800 /tmp/x.lock)"
assert_contains "a holder that arrived during the wait has no over the wait reading, and says so" \
  "${LATE_REPORT}" "not measured"

# ---------------------------------------------------------------------------
# The guard, driven for real against processes this fixture starts
# ---------------------------------------------------------------------------
BIN_DIR="${TMP_DIR}/bin"
mkdir -p "${BIN_DIR}"
# Every sleep the guard makes, at a tenth of its length. By absolute path, or it would find itself.
cat > "${BIN_DIR}/sleep" <<'STUB'
#!/usr/bin/env bash
exec /bin/sleep "$(awk -v seconds="$1" 'BEGIN { printf "%.3f", seconds * 0.1 }')"
STUB
chmod +x "${BIN_DIR}/sleep"
PATH="${BIN_DIR}:${PATH}"

# A stand in for flock that behaves as the real one was measured to (2026-09-24, flock 0.4.0): it WAITS
# with no child at all while queued, then FORKS the command and waits for it. The first half is what
# lets the guard tell a queued run from a stalled one without reading the log. Perl, so the wait is in
# process rather than a child `sleep` that would look exactly like a holder.
FAKE_FLOCK="${TMP_DIR}/fake-flock"
cat > "${FAKE_FLOCK}" <<'STUB'
#!/usr/bin/perl
my $queued = shift @ARGV;
select(undef, undef, undef, $queued);
my $child = fork();
if ($child == 0) { exec @ARGV or exit 127; }
my $fh;
if (open($fh, '>', $ENV{FAKE_FLOCK_PIDS})) { print $fh "$$ $child\n"; close($fh); }
waitpid($child, 0);
exit($? >> 8);
STUB
chmod +x "${FAKE_FLOCK}"

TEST_STALL_END_CHECK_SECONDS=1
TEST_STALL_END_SECONDS=3
TEST_STALL_END_CPU_SECONDS=5
TEST_STALL_END_GRACE_SECONDS=2

# THE case: the holder is alive and does nothing. It must be ENDED, both pids, and recorded.
LOG="${TMP_DIR}/hung.log"
printf 'Test alpha() started.\nTest alpha() passed after 0.001 seconds.\n' > "${LOG}"
RECORD="${TMP_DIR}/hung.record"
export FAKE_FLOCK_PIDS="${TMP_DIR}/hung.pids"
start_own_group_job "${FAKE_FLOCK}" 0 /bin/sleep 60
RUN_PID="${OWN_GROUP_JOB_PID}"
HUNG_STARTED="${SECONDS}"
RECORD_FOR_STOP="${RECORD}"
start_run_stall_end "${RUN_PID}" "$$" "${LOG}" "${RECORD}" 2>"${TMP_DIR}/hung.stderr"
GUARD_PID="${RUN_STALL_END_PID}"
wait "${RUN_PID}" 2>/dev/null
HUNG_CODE=$?
HUNG_TOOK=$(( SECONDS - HUNG_STARTED ))
stop_run_stall_end "${GUARD_PID}" "${RECORD_FOR_STOP}"
read -r HUNG_FLOCK HUNG_HOLDER < "${FAKE_FLOCK_PIDS}"

assert_contains "a hung holder is recorded as stalled" "$(cat "${RECORD}" 2>/dev/null)" "reason=stalled"
assert_contains "naming the holder by the pid the run started" \
  "$(cat "${RECORD}" 2>/dev/null)" "holder=${HUNG_HOLDER}"
assert_contains "and that it was ended" "$(cat "${RECORD}" 2>/dev/null)" "ended=ended"
assert_pids_gone "the holder and its flock are both gone" "${HUNG_FLOCK}" "${HUNG_HOLDER}"
assert_eq "the run exits nonzero, never as a pass" "nonzero" \
  "$(if [[ "${HUNG_CODE}" -ne 0 ]]; then echo nonzero; else echo zero; fi)"
assert_eq "and it ended in seconds, not the 60 the holder would have taken" "prompt" \
  "$(if [[ "${HUNG_TOOK}" -le 10 ]]; then echo prompt; else echo "took ${HUNG_TOOK}s"; fi)"
assert_contains "it says so out loud at the moment it happens" \
  "$(cat "${TMP_DIR}/hung.stderr")" "ENDING THIS RUN"

# QUEUED is never a stall: flock with no child for longer than the limit, then a quick holder.
QUEUED_RECORD="${TMP_DIR}/queued.record"
export FAKE_FLOCK_PIDS="${TMP_DIR}/queued.pids"
start_own_group_job "${FAKE_FLOCK}" 1.2 /bin/sh -c 'exit 0'
RUN_PID="${OWN_GROUP_JOB_PID}"
RECORD_FOR_STOP="${QUEUED_RECORD}"
start_run_stall_end "${RUN_PID}" "$$" "${LOG}" "${QUEUED_RECORD}" 2>/dev/null
GUARD_PID="${RUN_STALL_END_PID}"
wait "${RUN_PID}" 2>/dev/null
QUEUED_CODE=$?
stop_run_stall_end "${GUARD_PID}" "${RECORD_FOR_STOP}"
assert_eq "a run queued for the lock past the limit is never ended" "no record" \
  "$(if [[ -s "${QUEUED_RECORD}" ]]; then echo "recorded: $(cat "${QUEUED_RECORD}")"; else echo "no record"; fi)"
assert_eq "and it finishes with its own exit code" "0" "${QUEUED_CODE}"

# WORKING is never a stall: no new test line, but the run's CPU keeps rising. Read through a stand in
# `ps` whose holder gains a second of CPU per reading, because a real busy loop would spend real CPU on
# this Mac to prove it.
CPU_COUNTER="${TMP_DIR}/cpu-counter"
echo 0 > "${CPU_COUNTER}"
cat > "${TMP_DIR}/rising-ps" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "${CPU_COUNTER}") + 7 ))
echo "\${n}" > "${CPU_COUNTER}"
/bin/ps -axo pid=,ppid=,pgid=,time= | awk -v n="\${n}" -v run="\${RISING_RUN_PID:-0}" '
  \$2 == run { printf "%s %s %s %d:%02d.00\n", \$1, \$2, \$3, n / 60, n % 60; next } { print }'
STUB
chmod +x "${TMP_DIR}/rising-ps"
BUSY_RECORD="${TMP_DIR}/busy.record"
export FAKE_FLOCK_PIDS="${TMP_DIR}/busy.pids"
# Long enough for many times the limit in ticks, whatever else this Mac is doing: at 1.5s it was only a
# few ticks under load, and a mutation that stopped CPU counting as movement survived it.
start_own_group_job "${FAKE_FLOCK}" 0 /bin/sleep 4
RUN_PID="${OWN_GROUP_JOB_PID}"
export RISING_RUN_PID="${RUN_PID}"
TEST_STALL_END_PS="${TMP_DIR}/rising-ps"
RECORD_FOR_STOP="${BUSY_RECORD}"
start_run_stall_end "${RUN_PID}" "$$" "${LOG}" "${BUSY_RECORD}" 2>/dev/null
GUARD_PID="${RUN_STALL_END_PID}"
wait "${RUN_PID}" 2>/dev/null
BUSY_CODE=$?
stop_run_stall_end "${GUARD_PID}" "${RECORD_FOR_STOP}"
TEST_STALL_END_PS="/bin/ps"
assert_eq "a run whose CPU keeps rising is never ended, however quiet its log" "no record" \
  "$(if [[ -s "${BUSY_RECORD}" ]]; then echo "recorded: $(cat "${BUSY_RECORD}")"; else echo "no record"; fi)"
assert_eq "and it finishes with its own exit code" "0" "${BUSY_CODE}"

# ORPHANED: the runner that started the run is gone, so nothing would ever release the lock. On
# 2026-09-19 exactly this left xcodebuild and flock reparented to launchd holding it.
ORPHAN_RECORD="${TMP_DIR}/orphan.record"
export FAKE_FLOCK_PIDS="${TMP_DIR}/orphan.pids"
start_own_group_job "${FAKE_FLOCK}" 0 /bin/sleep 60
RUN_PID="${OWN_GROUP_JOB_PID}"
# Started only once the holder exists, so this measures the orphan of a run that HELD the lock.
wait_for_file() {
  local waited=0
  while [[ ! -s "$1" && "${waited}" -lt 100 ]]; do /bin/sleep 0.05; waited=$(( waited + 1 )); done
}
wait_for_file "${FAKE_FLOCK_PIDS}"
# A runner pid that has certainly exited, made by letting a process finish rather than by killing it:
# a TERM that lands between the fork and the exec reaches a bash child still holding this fixture's
# EXIT trap, which then deleted the scratch directory out from under the assertions (seen 3 runs in 5).
/usr/bin/true & GONE_RUNNER=$!
wait "${GONE_RUNNER}" 2>/dev/null
RECORD_FOR_STOP="${ORPHAN_RECORD}"
start_run_stall_end "${RUN_PID}" "${GONE_RUNNER}" "${LOG}" "${ORPHAN_RECORD}" 2>/dev/null
GUARD_PID="${RUN_STALL_END_PID}"
wait "${RUN_PID}" 2>/dev/null
stop_run_stall_end "${GUARD_PID}" "${RECORD_FOR_STOP}"
read -r ORPHAN_FLOCK ORPHAN_HOLDER < "${FAKE_FLOCK_PIDS}"
assert_contains "a run whose runner has died is ended as an orphan" \
  "$(cat "${ORPHAN_RECORD}" 2>/dev/null)" "reason=orphaned"
assert_pids_gone "and its holder and flock are gone" "${ORPHAN_FLOCK}" "${ORPHAN_HOLDER}"

# A holder that IGNORES the polite signal is killed after the grace period, and the record says so.
STUBBORN_RECORD="${TMP_DIR}/stubborn.record"
export FAKE_FLOCK_PIDS="${TMP_DIR}/stubborn.pids"
start_own_group_job "${FAKE_FLOCK}" 0 /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; sleep 60'
RUN_PID="${OWN_GROUP_JOB_PID}"
RECORD_FOR_STOP="${STUBBORN_RECORD}"
start_run_stall_end "${RUN_PID}" "$$" "${LOG}" "${STUBBORN_RECORD}" 2>/dev/null
GUARD_PID="${RUN_STALL_END_PID}"
wait "${RUN_PID}" 2>/dev/null
stop_run_stall_end "${GUARD_PID}" "${RECORD_FOR_STOP}"
read -r STUBBORN_FLOCK STUBBORN_HOLDER < "${FAKE_FLOCK_PIDS}"
assert_contains "a holder that ignores TERM is killed once the grace period is up" \
  "$(cat "${STUBBORN_RECORD}" 2>/dev/null)" "ended=ended-by-kill"
assert_pids_gone "and it is gone" "${STUBBORN_FLOCK}" "${STUBBORN_HOLDER}"

# The verdict main prints, read from a record, so its words are asserted without a real run.
REPORT="$(stalled_run_report "reason=stalled
stalled_seconds=1200
holder=4483
holder_cpu=133
stall_cpu=40
run=4480
ended=ended")"
assert_contains "the verdict names the stall" "${REPORT}" "STALLED AND ENDED"
assert_contains "and how long nothing moved" "${REPORT}" "20m"
assert_contains "and the holder with its CPU time" "${REPORT}" "PID 4483, 1.33s of CPU in total"
assert_contains "and the flock wrapper" "${REPORT}" "PID 4480"
assert_contains "and that it is not a pass" "${REPORT}" "NOT a pass"
assert_not_contains "and never that nothing ran, which would send the reader to their scope" \
  "${REPORT}" "NOTHING RAN"

SURVIVED_REPORT="$(stalled_run_report "reason=stalled
stalled_seconds=1200
holder=4483
holder_cpu=133
stall_cpu=40
run=4480
ended=survived 4483")"
assert_contains "a holder that outlived both signals is named, with how to end it" \
  "${SURVIVED_REPORT}" "kill -KILL 4483"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All test-stall-end checks passed."
else
  echo "${FAILURES} test-stall-end check(s) failed."
  exit 1
fi
