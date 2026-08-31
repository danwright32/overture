#!/usr/bin/env bash
set -uo pipefail

# #3256: job control must not take the terminal away from a nested background run.
#
# #3248 gives three background jobs a process group of their own with `set -m`, so they can be stopped
# whole. That is only safe because a NON-INTERACTIVE bash enables job control without taking control of
# the terminal. If it did take it, a background process group reaching for the terminal would be STOPPED
# by SIGTTOU rather than told about it, and the symptom would be a run that hangs rather than one that
# fails, which is worse: a hang is indistinguishable from slowness (L110).
#
# That was measured once, by hand, on 2026-08-29, under a real pty and nested exactly the way
# `scripts/test-all.sh` nests it: the Swift lane is started as a background job under `set -m`, and the
# runner inside it starts its own progress watcher under `set -m` again. Nothing repeated it, and the
# existing fixtures assert that the process GROUP forms, which is a different question.
#
# So this reproduces the nesting under a real pty (`script -q /dev/null`) and asserts the inner script is
# still RUNNING after it starts its watcher rather than stopped.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "${REPO_ROOT}/scripts/lib/shell-assertions.sh"
# fixture_end_process_group, so a stopped or stray group is ENDED rather than left in the process table
# for the runner's own leak check to attribute to this fixture (#3254).
# shellcheck source=../../../scripts/lib/fixture-process-leak.sh
source "${REPO_ROOT}/scripts/lib/fixture-process-leak.sh"

FAILURES=0

TMP_DIR="$(fixture_scratch_dir)"
# Removed here rather than on the library's sweep, because the runner's leak check looks at the temp
# directory the moment this fixture ends. No other EXIT trap is installed in this file, which is the
# thing to check before adding one: a shell keeps exactly one and the later trap silently wins.
trap 'rm -rf "${TMP_DIR}"' EXIT

INNER="${TMP_DIR}/inner.sh"
OUTER="${TMP_DIR}/outer.sh"
WATCH_LOG="${TMP_DIR}/watch.log"
PHASE_LOG="${TMP_DIR}/phase.log"

# The inner script is the SHAPE of `run-tests-locked.sh`: it starts a progress watcher under `set -m`
# while it is itself a background job in a group of its own. It records a mark BEFORE and AFTER starting
# the watcher, because those two marks are the whole measurement: a SIGTTOU stop lands between them.
cat > "${INNER}" <<INNER_EOF
#!/usr/bin/env bash
set -uo pipefail
source "${REPO_ROOT}/mac/scripts/lib/test-progress-watch.sh"
echo "before" > "${TMP_DIR}/before"
start_progress_watch "${WATCH_LOG}"
echo "\${PROGRESS_WATCH_PID}" > "${TMP_DIR}/watcher-pid"
# The watcher's own process group, read from the OS rather than assumed. A group id is the pid of its
# leader, so a watcher that leads its own group reports its own pid here. This is what tells "still
# running because set -m did nothing" from "still running and grouped", which is the state #3248 needs.
ps -o pgid= -p "\${PROGRESS_WATCH_PID}" 2>/dev/null | tr -d ' ' > "${TMP_DIR}/watcher-pgid"
echo "after" > "${TMP_DIR}/after"
stop_progress_watch "\${PROGRESS_WATCH_PID}"
echo "done" > "${TMP_DIR}/done"
INNER_EOF
chmod +x "${INNER}"

# The outer script is the shape of `scripts/test-all.sh`: it starts the inner one as a background phase,
# which is itself `set -m`, and waits for it.
cat > "${OUTER}" <<OUTER_EOF
#!/usr/bin/env bash
set -uo pipefail
source "${REPO_ROOT}/scripts/lib/test-all-phases.sh"
start_background_phase "${PHASE_LOG}" bash "${INNER}"
echo "\${BACKGROUND_PHASE_PID}" > "${TMP_DIR}/phase-pid"
wait "\${BACKGROUND_PHASE_PID}" 2>/dev/null
echo "\$?" > "${TMP_DIR}/phase-status"
# The status file is the CALLER's to remove: start_background_phase mints it and sets the variable,
# and scripts/test-all.sh removes it in its own trap. A fixture that skipped this would leave one per
# run in the temp directory, which the runner's leak check reports (#3065).
rm -f "\${BACKGROUND_PHASE_STATUS_FILE:-}"
OUTER_EOF
chmod +x "${OUTER}"

# Under a REAL pty, which is the whole point: a pipe has no controlling terminal, so SIGTTOU cannot
# arise and a run without one would prove nothing about the case this exists for.
#
# The watcher's own intervals are turned right down so nothing here waits on its default 30 second
# sleep; the measurement is about whether the process is STOPPED, not about what it prints.
#
# It runs in the BACKGROUND with a deadline, because the failure this guards against is a HANG: if the
# inner script were stopped by SIGTTOU the `wait` in the outer one would never return, and a fixture that
# waited for it would hang the whole sweep rather than fail (L110). Waited on by CONDITION, never by a
# fixed sleep.
set -m
OVERTURE_TEST_STALL_CHECK_SECONDS=1 \
  script -q /dev/null bash "${OUTER}" > "${TMP_DIR}/pty.log" 2>&1 &
PTY_PID=$!
set +m

DEADLINE=$(( SECONDS + 30 ))
while [[ ! -f "${TMP_DIR}/phase-status" && "${SECONDS}" -lt "${DEADLINE}" ]]; do
  sleep 0.2
done

# Whatever happened, nothing is left running: a stopped process group would otherwise sit in the process
# table for the rest of the session and the runner's own leak check would attribute it to this fixture.
fixture_end_process_group "${PTY_PID}"
wait "${PTY_PID}" 2>/dev/null || true

assert_equals "the inner run reached the point before starting its watcher" \
  "before" "$(cat "${TMP_DIR}/before" 2>/dev/null || echo MISSING)"

# THE assertion. A background process group stopped by SIGTTOU never reaches this line, and the mark is
# the only thing that can tell that apart from a run that is merely slow.
assert_equals "and kept running after starting it, rather than being stopped by SIGTTOU" \
  "after" "$(cat "${TMP_DIR}/after" 2>/dev/null || echo "STOPPED OR NEVER GOT THERE")"

assert_equals "and ran to the end" \
  "done" "$(cat "${TMP_DIR}/done" 2>/dev/null || echo MISSING)"

assert_equals "and the outer phase saw it exit cleanly" \
  "0" "$(cat "${TMP_DIR}/phase-status" 2>/dev/null || echo "NEVER RETURNED")"

# And the group really formed, so the assertion above cannot be answered by a `set -m` that did nothing.
# A group id is the pid of its leader, so a watcher leading its own group reports its own pid.
# Two DIFFERENT sentinels, so a run in which neither file was written cannot answer this by comparing
# nothing with nothing. Found by mutating the fixture: with the inner run stopped, both reads came back
# empty and this assertion passed while everything around it failed (L98).
WATCHER_PID="$(cat "${TMP_DIR}/watcher-pid" 2>/dev/null || echo "NO WATCHER PID WAS RECORDED")"
WATCHER_PGID="$(cat "${TMP_DIR}/watcher-pgid" 2>/dev/null || echo "NO PROCESS GROUP WAS RECORDED")"
assert_equals "the watcher led a process group of its own, so job control really was on" \
  "${WATCHER_PID}" "${WATCHER_PGID}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All job-control nesting fixtures passed."
  exit 0
fi
echo "${FAILURES} job-control nesting fixture(s) failed."
exit 1
