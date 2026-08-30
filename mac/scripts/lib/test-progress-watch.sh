#!/usr/bin/env bash
# Whether the test run is actually MOVING, reported while it runs (#2577).
#
# run-tests-locked.sh already refuses to call a run successful when it executed zero tests (#2317's
# NOTHING RAN). It had no equivalent for a run that STARTS fine and then stops progressing, so a hung
# run and a genuinely long one looked identical to anyone watching, including a Claude session
# reporting status.
#
# Measured 2026-08-12. A run hung inside a test's untimed wait loop (#2576) and was not noticed for
# over an hour, while a second run sat blocked on the shared lock for 50 minutes of that. Three
# consecutive status reports said "waiting on the suite" when the work had been dead the whole time.
# That is the L106 shape: a signal that keeps ticking while the work behind it is finished or frozen.
#
# Two things make this harder than a timeout, and both are why the file is this long.
#
# FIRST, the log GROWING is not progress. The hang produced 21MB of repeated CoreData errors, so
# every byte-based or mtime-based signal reported a busy, healthy run for the entire hour. The
# progress signal here is therefore a count of lines that REPORT A TEST starting or finishing, and
# nothing else. Repeated error output moves the byte count and leaves this one exactly where it was.
#
# SECOND, and the distinction the whole guard turns on: xcodebuild is serialised behind ONE lock
# across every worktree on this Mac, so a run that has not started yet is the common case, not the
# odd one. A guard that cannot tell a QUEUED run from a STALLED one would fire on the ordinary
# state and be ignored within a day (L36). It is told apart by evidence rather than by a guess:
# `flock` prints nothing and only execs xcodebuild once it holds the lock, so a queued run's log is
# EMPTY. Zero bytes IS the proof that the run has not begun. The stall clock never runs in that
# phase, and the queued phase gets its own message instead, because "waiting on the suite" being
# indistinguishable from "hung" is the same defect seen from the other side.
#
# What this deliberately does NOT do, named rather than left to be discovered (L93, L65):
#
#   It WARNS, it does not kill. A stalled run holds the shared lock, which is real damage, so
#   killing it has a genuine argument. Against that: this runs on a Mac where several agents contend
#   for that lock, the limit is a guess until it has been observed on real runs, and a wrong kill
#   throws away a full suite's work and reports as a failure nobody caused. Warning is the
#   reversible half, and what the incident actually cost was an hour of nobody KNOWING. What warning
#   gets wrong is that somebody still has to act on it, so the lock stays held until they do.
#
#   The BUILD phase is exempt. A cold build legitimately runs for minutes printing no test line at
#   all, and no run has ever been observed to hang there, so there is no measured number to set a
#   limit from and an invented one would only produce false alarms. The clock starts at the first
#   test line and covers the phase the observed hang was in.

# The cadences, all overridable, all read once here so the fixtures can drive the real loop in
# seconds instead of the ten minutes a real run would need (L2: a test must be structurally able to
# avoid waiting on real time, and the seam is the same one an operator would use to retune it).
TEST_STALL_LIMIT_SECONDS="${OVERTURE_TEST_STALL_LIMIT_SECONDS:-600}"
TEST_STALL_CHECK_SECONDS="${OVERTURE_TEST_STALL_CHECK_SECONDS:-30}"
TEST_LOCK_NOTICE_SECONDS="${OVERTURE_TEST_LOCK_NOTICE_SECONDS:-300}"

# Every message the watcher prints carries the script's own name, because it interleaves with
# xcodebuild's output and has to be attributable at a glance.
WATCH_PREFIX="run-tests-locked.sh:"

# What a line has to look like to prove the run MOVED. Read off a real run on this Mac rather than
# imagined (the xcresult of 2026-08-12 15:36, see the fixture, L52), and matched WITHOUT the pass,
# fail and started marks Swift Testing decorates these lines with: the marks are presentation, and a
# matcher that required them would silently match nothing the day they changed. A progress count
# that can never rise reports every healthy run as stalled, so failing that way would turn this from
# a guard into a permanent false alarm.
#
# It is deliberately narrow. A line mentioning a test is not a line reporting one, and the 21MB the
# hang wrote was all lines that mention things: the whole failure was a signal that could not tell
# the two apart.
#
# There is no companion "is this one line progress" predicate, on purpose. It would be a second
# implementation of this pattern in bash's regex engine rather than grep's, and a fixture written
# against it would prove that the twin agrees with itself while the shipping path used the other
# engine (L26, L52). Every assertion about what counts as progress goes through progress_count.
TEST_PROGRESS_PATTERN='(Test|Suite) .*started\.|(Test|Suite) .* (passed|failed) after [0-9.]+ second|Test Case .* (passed|failed) \(|Test Suite .* (started|passed|failed) at [0-9]'

# Which of the run's three phases the evidence says it is in.
#
#   queued   nothing has been written at all, so flock has not handed over yet and no xcodebuild
#            has run. This is a WAIT, and it is the common case on this Mac.
#   building bytes but no test has reported, so it is compiling. Exempt from the stall clock.
#   testing  at least one test has reported. From here a long silence means something.
#
# Note the order: the test count is asked first, so a run that is testing is never reported as
# building on the strength of its size. Size never decides anything here (L63).
watch_phase() {
  local bytes="$1" progress="$2"
  if [[ "${progress}" =~ ^[0-9]+$ ]] && [[ "${progress}" -gt 0 ]]; then
    echo "testing"
  elif [[ "${bytes}" =~ ^[0-9]+$ ]] && [[ "${bytes}" -gt 0 ]]; then
    echo "building"
  else
    echo "queued"
  fi
}

# Is the next repeat of a message due yet? True once <elapsed> has reached the (<given> + 1)th whole
# multiple of <every>.
#
# One predicate for both repeating messages, the stall warning and the still-waiting notice, rather
# than two that drift (L16). It also fixes the repeat cadence at the limit itself: a warning that
# repeated on every check would be noise at 30 second intervals, and one that never repeated would
# scroll away behind whatever the run prints next.
#
# An unset, empty, non-numeric or zero cadence is NO cadence and never fires. That is the fail-safe
# direction HERE, the opposite way round from the stall verdict itself: a mistyped limit that warned
# on every run would train the reader to ignore the one that matters, which is exactly the outcome
# this exists to prevent. Zero is also how a caller switches a message off on purpose.
notice_due() {
  local elapsed="$1" every="$2" given="$3"
  [[ "${elapsed}" =~ ^[0-9]+$ ]] || return 1
  [[ "${every}" =~ ^[0-9]+$ ]] || return 1
  [[ "${given}" =~ ^[0-9]+$ ]] || given=0
  [[ "${every}" -gt 0 ]] || return 1
  [[ "${elapsed}" -ge $(( every * (given + 1) )) ]]
}

# A duration a person can read at a glance. Minutes round DOWN, so the figure never overstates how
# long something has been wrong: this number is quoted in a warning that asks somebody to act, and a
# warning that rounds up is a warning that fires slightly early every time.
humanize_seconds() {
  local seconds="$1"
  [[ "${seconds}" =~ ^[0-9]+$ ]] || seconds=0
  if [[ "${seconds}" -lt 60 ]]; then
    echo "${seconds}s"
  elif [[ "${seconds}" -lt 3600 ]]; then
    echo "$(( seconds / 60 ))m"
  else
    echo "$(( seconds / 3600 ))h $(( (seconds % 3600) / 60 ))m"
  fi
}

# The warning itself.
#
# Its second job, and the reason it is four sentences rather than one, is to RULE OUT the lock by
# name. "Waiting on the suite" was a believable thing to say three times in a row precisely because
# waiting really is what usually happens here, so a message that only said "no progress" would be
# read as the queue again. It also states how many tests DID finish, which is the fact that proves
# the run got past the queue and the build.
stall_warning() {
  local stalled="$1" progress="$2"
  echo "NO TEST HAS FINISHED FOR $(humanize_seconds "${stalled}"). ${progress} progress lines came before that, and none since.
This run is not waiting for the shared lock: it HOLDS the lock and its tests are already running,
so a silence this long is a stall, not a queue. A test that hangs inside a wait cannot fail by
itself (#2576), and the log growing is not progress: the hang on 2026-08-12 wrote 21MB standing
still. Look at the run, or kill it and give the lock back."
}

# Said when the run has produced NOTHING at all, which on this Mac is the ordinary state rather than
# a fault. Without it a queued run is silent, and silence is what the stall warning is also about,
# so the two states would still be indistinguishable to whoever is watching.
lock_wait_notice() {
  local queued="$1"
  echo "STILL WAITING for the shared xcodebuild lock after $(humanize_seconds "${queued}"). Another run
on this Mac holds it, so this run is queued and not stalled. It has produced no output whatsoever,
which is exactly what queued looks like: flock prints nothing until it hands the lock over."
}

# Said once, when the wait ends. It is what makes a run's own elapsed time readable afterwards: a
# figure quoted for how long the suite took means nothing without knowing how much of it was queue
# (L102).
lock_acquired_notice() {
  local queued="$1"
  echo "Got the shared xcodebuild lock after $(humanize_seconds "${queued}") of waiting. Everything from
here is this run's own time."
}

# A warning that turns out to be wrong is withdrawn in the same place it was made. Otherwise a run
# that finished perfectly well still ends under a stall warning, and the next reader has to work out
# which of the two to believe (L11).
progress_resumed_notice() {
  local stalled="$1"
  echo "Progress resumed after $(humanize_seconds "${stalled}") of none.
The warning above it was a false alarm. If that keeps happening, raise the limit it fired at
(OVERTURE_TEST_STALL_LIMIT_SECONDS) rather than learn to ignore the warning."
}

# ---------------------------------------------------------------------------
# Below this line the functions READ A FILE and run a loop. Everything above is pure.
# ---------------------------------------------------------------------------

# How big the log is, or 0 when there is nothing to read. Only ever used to tell "not started" from
# "started", never as a measure of progress.
log_bytes() {
  local file="$1" bytes
  [[ -r "${file}" ]] || { echo 0; return 0; }
  bytes="$(wc -c < "${file}" 2>/dev/null | tr -d ' ')"
  [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
  echo "${bytes}"
}

# How many progress lines the log holds so far.
#
# `grep -c` prints 0 AND exits nonzero when it matches nothing, so the usual `|| echo 0` fallback
# would answer with the two lines "0" and "0". Every comparison downstream then silently stops being
# arithmetic. The status is swallowed and the answer validated instead.
#
# `-a` is there because xcodebuild's stream carries the app's own output, which can hold bytes grep
# treats as binary, and the same flag is on the grep at the bottom of run-tests-locked.sh. What it
# buys HERE was measured rather than assumed (2026-08-12, /usr/bin/grep on macOS 15): with `-c` the
# count comes back as a number either way, because the "Binary file ... matches" substitution only
# replaces printed LINES. So `-a` is redundant for this exact call and is kept for the form this
# would take if it ever counted by printing, where dropping it silently turns thousands of progress
# lines into the single line "Binary file ... matches". Stated plainly because a comment claiming a
# flag is load bearing, when the suite cannot show it failing without it, is the kind of reassurance
# that outlives the fact (L103).
progress_count() {
  local file="$1" count
  [[ -r "${file}" ]] || { echo 0; return 0; }
  count="$(grep -acE "${TEST_PROGRESS_PATTERN}" "${file}" 2>/dev/null)" || true
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  echo "${count}"
}

# The watcher. Runs beside the run it is watching, reading only the log the run is already writing.
#
# Elapsed time is accumulated from its OWN ticks rather than read off a clock, the same choice
# run-stall-guard.sh made for the same reason (L82, #2220): a machine that sleeps or whose clock
# jumps then cannot produce a phantom stall. It undercounts across a sleeping Mac, which is the safe
# direction, because the failure it produces is a warning arriving late rather than one arriving
# wrongly.
#
# It never exits on its own and never touches the run. The caller kills it. That is deliberate: a
# watchdog that can take down the work it watches is a second way to lose a good run (L71), and this
# one has no ability to do anything but print.
progress_watch_loop() {
  local log_file="$1" limit="$2" interval="$3" lock_every="$4"
  local queued=0 stalled=0 warnings=0 lock_notices=0 last_count=0 announced=0
  local bytes count phase

  # No interval means no watcher at all, rather than a loop spinning as fast as the machine allows.
  [[ "${interval}" =~ ^[0-9]+$ ]] && [[ "${interval}" -gt 0 ]] || return 0

  while true; do
    # The sleep is given NO handle on this script's stdout or stderr, and that is load bearing rather
    # than tidiness. It was measured on 2026-08-12: a caller that captures the run's output waits for
    # every writer of that pipe to close, and killing the watcher does not take its sleep with it, so
    # one orphaned `sleep 30` reparented to launchd held the capture open for a further 30 seconds
    # after the run was over. The fixture that found it hung for two minutes. stop_progress_watch
    # kills the sleep too; this makes an escaped one harmless rather than merely unlikely.
    sleep "${interval}" >/dev/null 2>&1
    bytes="$(log_bytes "${log_file}")"
    count="$(progress_count "${log_file}")"
    phase="$(watch_phase "${bytes}" "${count}")"

    if [[ "${phase}" == "queued" ]]; then
      queued=$(( queued + interval ))
      if notice_due "${queued}" "${lock_every}" "${lock_notices}"; then
        lock_notices=$(( lock_notices + 1 ))
        printf '\n%s %s\n' "${WATCH_PREFIX}" "$(lock_wait_notice "${queued}")" >&2
      fi
      continue
    fi

    if [[ "${queued}" -gt 0 && "${announced}" -eq 0 ]]; then
      announced=1
      printf '\n%s %s\n' "${WATCH_PREFIX}" "$(lock_acquired_notice "${queued}")" >&2
    fi

    # The build is exempt, so the stall clock only ever runs once a test has reported.
    [[ "${phase}" == "testing" ]] || continue

    if [[ "${count}" -gt "${last_count}" ]]; then
      if [[ "${warnings}" -gt 0 ]]; then
        printf '\n%s %s\n' "${WATCH_PREFIX}" "$(progress_resumed_notice "${stalled}")" >&2
      fi
      last_count="${count}"
      stalled=0
      warnings=0
      continue
    fi

    stalled=$(( stalled + interval ))
    if notice_due "${stalled}" "${limit}" "${warnings}"; then
      warnings=$(( warnings + 1 ))
      printf '\n%s %s\n' "${WATCH_PREFIX}" "$(stall_warning "${stalled}" "${count}")" >&2
    fi
  done
}

# Starts a watcher on <log_file> and records its PID in PROGRESS_WATCH_PID.
#
# Not written as `PID="$(start...)"`, because a command substitution runs in a subshell and the
# background job would be that subshell's child rather than this script's. It would still be
# killable, but never reapable, so the script would end holding a zombie it could not wait on.
#
# Started under `set -m` so the watcher gets a process group OF ITS OWN (#3248). Without job control a
# background job shares the shell's group, so there is nothing to address that is not also the run
# itself. The group is what lets stop_progress_watch end the loop and the `sleep` it is sitting in as
# one act, instead of reading the children first and hoping none is forked in the gap. Job control is
# turned back off immediately, and only if it was off to begin with, since it is a property of the
# whole shell rather than of this call.
#
# Enabling job control does NOT make this script fight for the terminal, which is the thing that would
# have made it unusable here: run-tests-locked.sh is itself started as a background job by
# scripts/test-all.sh, and a background process group that tries to take the terminal is stopped by
# SIGTTOU rather than told about it. Measured 2026-08-29 on this Mac, under a real pty and nested
# exactly that way (bash 3.2, non-interactive): the inner script kept running and its watcher got its
# own group. A non-interactive bash sets job control without taking terminal control.
PROGRESS_WATCH_PID=""
start_progress_watch() {
  local log_file="$1"
  local restore_job_control=0
  case "$-" in *m*) ;; *) restore_job_control=1 ;; esac
  set -m
  progress_watch_loop "${log_file}" \
    "${TEST_STALL_LIMIT_SECONDS}" "${TEST_STALL_CHECK_SECONDS}" "${TEST_LOCK_NOTICE_SECONDS}" &
  PROGRESS_WATCH_PID=$!
  [[ "${restore_job_control}" -eq 1 ]] && set +m
  return 0
}

# Stops it, and tolerates every way it might already be gone. Called on the normal path AND from an
# EXIT trap, so it has to be safe to call twice and safe to call on a PID that never existed: a
# watcher outliving the run that spawned it would sit printing about a log nobody is writing.
stop_progress_watch() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] || return 0
  # A pid that is not a plain number above 1 is refused rather than passed through, because
  # `kill -- -0` and `kill -- -1` mean this run's own group and every process on the machine.
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 0
  [[ "${pid}" -gt 1 ]] || return 0
  # The loop spends almost all of its life inside `sleep`, and killing the loop does NOT take that
  # child with it: it is reparented to launchd and runs out its full interval. Measured on
  # 2026-08-12, that left a `sleep 30` alive after the run had finished, holding the run's stdout
  # open, so anything capturing that output waited the whole interval out.
  #
  # #3248: the whole GROUP is signalled rather than the loop and a list of children read just before
  # it. Reading the list first leaves a gap the loop can fork into, and it is the wrong shape anyway,
  # since it only ever reaches one generation. `-"${pid}"` can only name the watcher's own group: a
  # group id is the pid of its leader, and this pid belongs to a process this script just started, so
  # either it leads a group (which `set -m` in start_progress_watch arranges) or no such group exists.
  kill -- -"${pid}" 2>/dev/null || true
  # And the pid itself, which is NOT redundant: it is what keeps a missing group a FAILURE rather than a
  # HANG. Measured 2026-08-29 by taking `set -m` away with only the group kill here: the group does not
  # exist, the kill reaches nothing, and the `wait` below then sits on a `while :` loop that never ends,
  # so the guard written to catch exactly that can never speak, because it can only speak once the run
  # is over (L110, and #2577's own lesson turned on its author). With this line the same mutation is
  # red in seconds instead. It cannot be shown to fail on its own, since the group kill covers it
  # whenever `set -m` worked, and that is the point of it.
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  PROGRESS_WATCH_PID=""
  return 0
}
