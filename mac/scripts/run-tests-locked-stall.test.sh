#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). This file uses the shared signatures as-is
# (assert_contains takes desc, haystack, needle).
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2577: a run that STOPS PROGRESSING says so, and a run that has not started yet does not.
#
# The pure halves of this live in mac/scripts/lib/test-progress-watch.test.sh. What can only be
# tested here is the seam: that the real script actually starts a watcher, that it watches the log
# the run is really writing, and above all that the two silences are told apart.
#
# They have to be, because on this Mac they are both ordinary. xcodebuild is serialised behind one
# lock across every worktree, so at the time this was written three agents plus the coordinating
# session were contending for it and a run could sit queued for many minutes before starting. A
# guard that called that a stall would fire on the normal case, and would be switched off within a
# day (L36). So there are two runs below, identical except for WHERE the silence happens.
#
# Both drive the real script with the cadences turned down to seconds through the same environment
# seam an operator would use to retune them (L2), so the fixture waits seconds rather than the ten
# minutes a real limit would need.
#
# A separate file from run-tests-locked.test.sh on purpose (#2601): these two scenarios spend real
# wall-clock seconds by design (the silences under test are silences in time), and the fixtures run
# concurrently, so carrying them in their own file lets this waiting happen beside its sibling's work
# instead of after it.
#
# #3408: and the SECOND is now shorter than the second the watcher counts. The whole schedule under test
# is counted in the watcher's OWN TICKS: `progress_watch_loop` accumulates `stalled + interval` per pass
# rather than reading a clock, deliberately, so that a Mac that goes to sleep cannot mint a phantom
# stall. Nothing in it measures real time at all. The only real time anywhere here is the `sleep` the
# loop sits in between ticks, and the matching ones in the stubs, so scaling every `sleep` by one factor
# leaves every relationship the guard depends on exactly as it was and stops the fixture living through
# thirteen seconds to assert a thirteen-tick schedule (L290, L524).
#
# It is injected the way everything else here is injected: a `sleep` on the stub PATH, ahead of the real
# one. That reaches the watcher's sleep and both stubs' sleeps at once, which is what keeps them in step;
# a seam that reached only one of the two would change the schedule rather than the clock.
#
# Retunable here rather than hidden, because it is the one number that decides whether this fixture is
# quick or flaky: at 0.25 the fixture's slowest wait is one second of real time, and each tick still
# leaves the watcher an order of magnitude more time than the few milliseconds its own work takes.
TICK_SCALE="${OVERTURE_STALL_FIXTURE_TICK_SCALE:-0.25}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

# Runs the real script with a flock stub that WAITS <lock_wait> seconds before handing over (which is
# what contention looks like), and an xcodebuild stub that prints <before>, goes quiet for <quiet>
# seconds, prints <after>, stays alive a further <tail_quiet> seconds and exits 0.
#
# The tail matters and is not padding. The watcher is killed the instant the run ends, so without it
# the last thing the watcher can ever observe is the silence, and a run that recovered would be
# indistinguishable from one that never did.
run_wrapper_with_slow_xcodebuild() {
  local lock_wait="$1" before="$2" quiet="$3" after="$4" tail_quiet="$5"
  local stall_limit="$6" check_every="$7" lock_notice="$8"
  local bin_dir output

  bin_dir="$(fixture_scratch_dir)"

  # The real flock blocks until the lock is free and only THEN execs xcodebuild, writing nothing
  # itself. That silence is the whole signal, so the stub reproduces it exactly.
  cat > "${bin_dir}/flock" <<STUB
#!/usr/bin/env bash
sleep ${lock_wait}
shift
exec "\$@"
STUB

  cat > "${bin_dir}/ps" <<'STUB'
#!/usr/bin/env bash
echo "  501 /sbin/launchd"
STUB

  # Progress, then a silence long enough to trip the limit, then the rest. Nothing is printed during
  # the quiet stretch: the real hang printed 21MB of error noise there, which is covered by the
  # pure fixture's assertion that noise is not progress, and cannot be reproduced faithfully here.
  cat > "${bin_dir}/xcodebuild" <<STUB
#!/usr/bin/env bash
cat <<'BEFORE'
${before}
BEFORE
sleep ${quiet}
cat <<'AFTER'
${after}
AFTER
sleep ${tail_quiet}
exit 0
STUB

  cat > "${bin_dir}/log" <<'STUB'
#!/usr/bin/env bash
echo ""
STUB

  # Every `sleep` the run makes, scaled by one factor: the watcher's own tick, the flock stub's wait for
  # the lock and the xcodebuild stub's two silences. Calls the real one by absolute path, which is not
  # tidiness: found through PATH it would find itself.
  cat > "${bin_dir}/sleep" <<STUB
#!/usr/bin/env bash
exec /bin/sleep "\$(awk -v seconds="\$1" -v scale="${TICK_SCALE}" 'BEGIN { printf "%.3f", seconds * scale }')"
STUB

  chmod +x "${bin_dir}/flock" "${bin_dir}/ps" "${bin_dir}/xcodebuild" "${bin_dir}/log" "${bin_dir}/sleep"

  # #3166: EVERY record the wrapper writes is redirected into the throwaway bin dir, not just the ones
  # this fixture reads. It drives the REAL wrapper, so anything it does not override it writes into the
  # live tree (L2). Found by the sibling fixture's own guard: this one had no series override, and its
  # stub runs appended their fake sizes (2400 tests in 348 suites) to the repository's real series.
  output="$(PATH="${bin_dir}:${PATH}" \
    OVERTURE_TEST_BASELINE_FILE="${bin_dir}/baseline" \
    OVERTURE_TEST_DIAGNOSTICS_DIR="${bin_dir}/diagnostics" \
    OVERTURE_TEST_STALL_LIMIT_SECONDS="${stall_limit}" \
    OVERTURE_TEST_STALL_CHECK_SECONDS="${check_every}" \
    OVERTURE_TEST_LOCK_NOTICE_SECONDS="${lock_notice}" \
    OVERTURE_HOSTED_SUITE_RECORD="${bin_dir}/hosted-seen" \
    OVERTURE_SUITE_RUN_SERIES="${bin_dir}/suite-run-series" \
    "${SCRIPT_DIR}/run-tests-locked.sh" 2>&1)"
  rm -rf "${bin_dir}"
  printf '%s\n' "${output}"
}

STALL_PROGRESS_LINES="Test run started.
Test alpha() passed after 0.001 seconds.
Test beta() passed after 0.002 seconds."
STALL_TAIL_LINES="Test run with 2400 tests in 348 suites passed after 19.462 seconds.
** TEST SUCCEEDED **"

# THE case. The lock is free, so the run starts at once, reports some tests, and then goes quiet for
# longer than the limit. That is a stall and it has to be said out loud while it is happening.
STALLED_RUN="$(run_wrapper_with_slow_xcodebuild 0 "${STALL_PROGRESS_LINES}" 4 "${STALL_TAIL_LINES}" 3 1 1 60)"

assert_contains "a run that stops progressing says so while it is still running" \
  "${STALLED_RUN}" "NO TEST HAS FINISHED FOR"

assert_contains "and rules out the lock, which is the reading that made three status reports wrong" \
  "${STALLED_RUN}" "not waiting for the shared lock"

# And it withdraws the warning itself once the run turns out to have been alive, so nobody is left
# reading a stall warning over a suite that passed (L11).
assert_contains "a run that recovers retracts its own warning" \
  "${STALLED_RUN}" "Progress resumed after"

# THE OTHER case, and the one that decides whether this guard survives contact with this Mac. The
# run is stuck behind another worktree's suite for FOUR seconds against a THREE second stall limit,
# having produced nothing at all. The silence is longer than the limit, and it must still never be
# called a stall, because it is a queue.
QUEUED_RUN="$(run_wrapper_with_slow_xcodebuild 4 "${STALL_PROGRESS_LINES}" 0 "${STALL_TAIL_LINES}" 2 3 1 2)"

assert_not_contains "waiting for the shared lock is NEVER reported as a stall" \
  "${QUEUED_RUN}" "NO TEST HAS FINISHED FOR"

assert_contains "the wait is reported as the queue it is, rather than left silent" \
  "${QUEUED_RUN}" "STILL WAITING for the shared xcodebuild lock"

assert_contains "and the run says what the queue cost it once it gets the lock" \
  "${QUEUED_RUN}" "Got the shared xcodebuild lock after"

# That the watcher does not OUTLIVE the run is asserted in the library's own fixture, where the PID
# is in hand. It cannot be asserted from here: the watcher is a shell function in a background
# subshell, so it carries the parent script's own command line, and the only way to count them would
# be to match `run-tests-locked.sh` across the whole process table. That would sweep in the runs the
# other worktrees on this Mac have going, which is both a false failure waiting to happen and a
# fixture reaching outside itself (L2).

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-tests-locked.sh stall fixtures passed."
  exit 0
else
  echo "${FAILURES} run-tests-locked.sh stall fixture(s) failed."
  exit 1
fi
