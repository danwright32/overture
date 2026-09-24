#!/usr/bin/env bash
# Ends a test run that has STOPPED while holding the shared xcodebuild lock (#3976).
#
# Measured twice on this Mac. On 2026-09-17 a run hung for 2 hours 50 minutes holding the lock, and every
# run behind it, in this project and in Downbeat, was starved. On 2026-09-19 it happened again for 38
# minutes, ended only because somebody was watching, and was read while it happened:
#
#   xcodebuild  pid 4483  0.0% cpu   0:01.33 cpu-time over 38 minutes elapsed
#   flock       pid 4480  holding /tmp/overture-mac-tests.lock
#
# test-progress-watch.sh already SAYS when a run stops moving, and deliberately does nothing else. Its
# header gives the reason, a wrong kill throws a whole suite away, and names the cost, that somebody still
# has to act. Both hangs were that cost: nothing that would have ended either existed, so each ran until a
# person noticed. And the obvious manual remedy made it worse: killing the runner left xcodebuild and its
# flock reparented to launchd, still holding the lock, while the runner looked handled.
#
# So this guard ENDS the run, and the evidence it ends on is two readings together, because neither is
# enough alone:
#
#   * no line reporting a test starting or finishing has arrived (test-progress-watch.sh's own count, so
#     the two can never disagree about what progress is), AND
#   * xcodebuild ITSELF has used less than a floor of CPU since it last moved.
#
# xcodebuild's OWN time, deliberately not the whole tree's. Sampled from a healthy full run on this Mac on
# 2026-09-24: xcodebuild had used 20.42s over 7m59s and gained about half a second every 15 seconds while
# testing, while `xctest` was ITS CHILD (ppid = xcodebuild) and had used 2m05s in 2m24s. On 2026-09-17 it
# was the test process that was busy, repeating a CoreData retry 5,260 times, so a reading of the tree
# could have called that hang working for as long as it spun. xcodebuild's own reading was 1.33s in 38
# minutes on 2026-09-19, which is the signature this ends on.
#
# A QUEUED run is never judged at all. flock takes the lock BEFORE it forks the command (measured
# 2026-09-24, flock 0.4.0: no child while queued, the child appears the moment the lock is free), so "the
# flock this runner started has a child" is proof the run holds the lock. That is evidence from the
# process table rather than inference from the log being empty, which is what test-progress-watch.sh has
# to use and which a run hung before printing a byte would pass forever.
#
# The accumulation and the limit are run-stall-guard.sh's `stall_tick`, the same one the three detached
# run scripts use, so there is one implementation of "stood still for the limit, stop" (L263). Elapsed
# time is counted from the guard's own ticks, never a clock, for that file's reason: a Mac that sleeps
# cannot mint a phantom stall (L82, #2220).
#
# The guard runs in a process group of its OWN, so ending the run's group never ends the guard, and it
# outlives the runner: if the runner is killed outright, the guard notices on its next tick and ends the
# run it left behind, which is exactly the orphan of 2026-09-19 (L71: a watchdog's liveness must not
# depend on what it watches).
#
# What stopping gets wrong, named (L93): a genuinely slow run in which xcodebuild uses less than the
# floor for the whole limit, with no test reporting, is ended and has to be run again. A cold build is not
# that: it prints no test line, but xcodebuild is driving it. The limit is twenty minutes against a full suite of about
# seven, and twice test-progress-watch.sh's warning, so that warning always comes first.

_TSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./run-stall-guard.sh
. "${_TSE_DIR}/run-stall-guard.sh"
# progress_count, humanize_seconds, start_own_group_job and stop_own_group_job.
# shellcheck source=./test-progress-watch.sh
declare -F progress_count >/dev/null 2>&1 || . "${_TSE_DIR}/test-progress-watch.sh"

# Every number is injectable, so the fixtures drive the real loop in fractions of a second (L524), and
# the same seam is how an operator retunes it. A limit of 0 switches the ending off.
TEST_STALL_END_SECONDS="${OVERTURE_TEST_STALL_END_SECONDS:-1200}"
TEST_STALL_END_CHECK_SECONDS="${OVERTURE_TEST_STALL_END_CHECK_SECONDS:-30}"
TEST_STALL_END_CPU_SECONDS="${OVERTURE_TEST_STALL_END_CPU_SECONDS:-5}"
TEST_STALL_END_GRACE_SECONDS="${OVERTURE_TEST_STALL_END_GRACE_SECONDS:-10}"
# The real ps BY PATH: the runner's fixtures put a stub `ps` on PATH for the stale host sweep, and read
# through it every process here would vanish (scratch_defaults_left_behind found that the hard way).
TEST_STALL_END_PS="${OVERTURE_TEST_STALL_END_PS:-/bin/ps}"

# The CPU floor in hundredths. A floor that is not a whole number falls back to the default rather than
# to zero, since a zero floor would count every tick as movement and switch the guard off silently.
stall_end_floor_centis() {
  local seconds="${TEST_STALL_END_CPU_SECONDS}"
  [[ "${seconds}" =~ ^[0-9]+$ ]] || seconds=5
  echo $(( seconds * 100 ))
}

# cpu_time_centis <ps time>: hundredths of a second, or nothing for anything unreadable (L50: a value
# that does not parse must never reach a comparison as zero). macOS prints minutes past 59 ("32:54.80"),
# and a day prefix is possible.
cpu_time_centis() {
  local text="$1"
  [[ "${text}" =~ ^(([0-9]+)-)?(([0-9]+):)?(([0-9]+):)?([0-9]+)(\.([0-9]{1,2}))?$ ]] || return 0
  local days="${BASH_REMATCH[2]:-0}" first="${BASH_REMATCH[4]:-}" second="${BASH_REMATCH[6]:-}"
  local seconds="${BASH_REMATCH[7]}" fraction="${BASH_REMATCH[9]:-0}"
  local hours=0 minutes=0
  if [[ -n "${second}" ]]; then
    hours="${first}"; minutes="${second}"
  elif [[ -n "${first}" ]]; then
    minutes="${first}"
  fi
  [[ "${#fraction}" -eq 1 ]] && fraction="${fraction}0"
  echo $(( ((10#${days} * 24 + 10#${hours}) * 3600 + 10#${minutes} * 60 + 10#${seconds}) * 100 + 10#${fraction} ))
}

# centis_readable <centis>: "1.33s" under a minute, "12m 3s" above it.
centis_readable() {
  local centis="$1"
  [[ "${centis}" =~ ^[0-9]+$ ]] || { echo "an unreadable amount"; return 0; }
  if [[ "${centis}" -lt 6000 ]]; then
    printf '%d.%02ds\n' $(( centis / 100 )) $(( centis % 100 ))
  else
    echo "$(( centis / 6000 ))m $(( (centis % 6000) / 100 ))s"
  fi
}

# One snapshot of the whole table, so every question asked about one tick is answered from one reading.
# The short name comes last and is only ever DISPLAYED: nothing here selects a process by its name.
process_table() {
  "${TEST_STALL_END_PS}" -axo pid=,ppid=,pgid=,time=,ucomm= 2>/dev/null || true
}

# process_children <table> <pid>: the direct children of <pid>, by PARENT PID. Never by command text: a
# match on text finds whatever else happens to carry the words, and finding nothing reads as success
# (L1011).
process_children() {
  awk -v parent="$2" '$2 == parent { print $1 }' <<< "$1"
}

process_group_of() {
  awk -v pid="$2" '$1 == pid { print $3; exit }' <<< "$1"
}

process_cpu_centis() {
  local time
  time="$(awk -v pid="$2" '$1 == pid { print $4; exit }' <<< "$1")"
  [[ -n "${time}" ]] || return 0
  cpu_time_centis "${time}"
}

# run_tree_cpu_centis <table> <root>: the CPU of <root>, everything descended from it, and everything
# still in its process group (a child reparented to launchd keeps its group). Nothing at all when <root>
# is not in the table, which is how a dead process reads.
run_tree_cpu_centis() {
  local table="$1" root="$2" line time total=0 centis
  awk -v root="${root}" '$1 == root { found = 1 } END { exit !found }' <<< "${table}" || return 0
  while IFS= read -r line; do
    time="$(awk '{ print $2 }' <<< "${line}")"
    [[ -n "${time}" ]] || continue
    centis="$(cpu_time_centis "${time}")"
    [[ -n "${centis}" ]] && total=$(( total + centis ))
  done <<< "$(run_tree_members "${table}" "${root}")"
  echo "${total}"
}

# run_tree_members <table> <root>: "pid time name" for <root> and every process that is its descendant or
# still in its group.
run_tree_members() {
  awk -v root="$2" '
    { pid[NR] = $1; ppid[NR] = $2; pgid[NR] = $3; time[NR] = $4
      name = ""; for (f = 5; f <= NF; f++) name = name (f > 5 ? " " : "") $f; label[NR] = name; n = NR }
    END {
      mine[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
          if (!(pid[i] in mine) && ((ppid[i] in mine) || pgid[i] == root)) { mine[pid[i]] = 1; changed = 1 }
        }
      }
      for (i = 1; i <= n; i++) if (pid[i] in mine) print pid[i], time[i], label[i]
    }' <<< "$1"
}

# busiest_across <table before> <table after> <root>: "pid centis name" for the member of the tree that
# used the most CPU between the two readings, or nothing when none can be measured across them.
busiest_across() {
  local before="$1" after="$2" root="$3" pid time name earlier now best_pid="" best=-1 best_name=""
  while read -r pid time name; do
    [[ -n "${pid}" ]] || continue
    now="$(cpu_time_centis "${time}")"
    earlier="$(process_cpu_centis "${before}" "${pid}")"
    [[ -n "${now}" && -n "${earlier}" && "${now}" -ge "${earlier}" ]] || continue
    if [[ $(( now - earlier )) -gt "${best}" ]]; then
      best=$(( now - earlier )); best_pid="${pid}"; best_name="${name}"
    fi
  done <<< "$(run_tree_members "${after}" "${root}")"
  [[ -n "${best_pid}" ]] && echo "${best_pid} ${best} ${best_name}"
  return 0
}

# cpu_moved <baseline centis> <now centis> <floor centis>: true when the run has used at least the floor
# since the baseline, or when the sum went DOWN (a child finished, which is activity).
cpu_moved() {
  local baseline="$1" now="$2" floor="$3"
  [[ "${baseline}" =~ ^[0-9]+$ && "${now}" =~ ^[0-9]+$ && "${floor}" =~ ^[0-9]+$ ]] || return 1
  [[ "${now}" -lt "${baseline}" ]] && return 0
  [[ $(( now - baseline )) -ge "${floor}" ]]
}

# end_run_group <run pid> <holder pid> <grace seconds>: ends the run by the pids this runner started and
# prints how it went: "ended", "ended-by-kill", or "survived <pids>".
#
# TERM first to the run's GROUP, which is flock's own (start_own_group_job made it the leader), then to
# the two pids by name, because a group kill reaches nothing if the group was never made. KILL for
# whatever is left after the grace period. The group kill is conditional on the run pid still LEADING its
# group, read from the table independently of the pid we hold (L70), because `kill -- -<pid>` on a pid
# that leads nothing is at best a no op.
end_run_group() {
  local run_pid="$1" holder="${2:-}" grace="${3:-${TEST_STALL_END_GRACE_SECONDS}}"
  local pids="" pid leads="" waited=0 alive
  for pid in "${run_pid}" "${holder}"; do
    [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] && pids="${pids} ${pid}"
  done
  [[ -n "${pids// /}" ]] || { echo "survived (no pid to end)"; return 0; }
  [[ "${grace}" =~ ^[0-9]+$ ]] || grace=10

  if [[ "${run_pid}" =~ ^[0-9]+$ && "${run_pid}" -gt 1 ]] \
     && [[ "$(process_group_of "$(process_table)" "${run_pid}")" == "${run_pid}" ]]; then
    leads=1
    kill -TERM -- "-${run_pid}" 2>/dev/null || true
  fi
  # shellcheck disable=SC2086
  kill -TERM ${pids} 2>/dev/null || true

  while :; do
    alive=""
    for pid in ${pids}; do
      kill -0 "${pid}" 2>/dev/null && alive="${alive} ${pid}"
    done
    [[ -n "${alive// /}" ]] || { echo "ended"; return 0; }
    [[ "${waited}" -lt "${grace}" ]] || break
    sleep 1 >/dev/null 2>&1
    waited=$(( waited + 1 ))
  done

  if [[ -n "${leads}" ]]; then kill -KILL -- "-${run_pid}" 2>/dev/null || true; fi
  # shellcheck disable=SC2086
  kill -KILL ${alive} 2>/dev/null || true
  sleep 1 >/dev/null 2>&1
  local survivors=""
  for pid in ${alive}; do
    kill -0 "${pid}" 2>/dev/null && survivors="${survivors} ${pid}"
  done
  if [[ -n "${survivors// /}" ]]; then
    echo "survived${survivors}"
  else
    echo "ended-by-kill"
  fi
}

# The guard. Runs beside the run, in a group of its own, and returns once the run is over or ended.
#
# <record> is written ONLY when it ends the run, so its presence is the verdict main reads. Two siblings,
# <record>.sig and <record>.tick, carry stall_tick's signature and state between ticks.
run_stall_end_loop() {
  local run_pid="$1" runner_pid="$2" log_file="$3" record="$4"
  local interval="${TEST_STALL_END_CHECK_SECONDS}" limit="${TEST_STALL_END_SECONDS}"
  local floor_centis
  floor_centis="$(stall_end_floor_centis)"
  local table holder cpu count baseline="" baseline_at_move="" epoch=0 stalled holder_cpu outcome
  local sig="${record}.sig" tick="${record}.tick"
  # The caller's traps are not this job's: a signal that stops the guard must never run the runner's own
  # cleanup, which releases the shared lock, from inside the guard.
  trap - EXIT INT TERM

  if ! [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -gt 0 ]]; then
    echo "run-tests-locked.sh: the stall ending is OFF for this run: OVERTURE_TEST_STALL_END_CHECK_SECONDS is '${interval}', not a whole number of seconds above zero." >&2
    return 0
  fi
  # A limit of 0 is the documented off switch. `stall_tick` already never trips on it, so this changes no
  # outcome; it makes the off state say so, as the interval's does, rather than looping in silence (L65).
  if ! [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]]; then
    echo "run-tests-locked.sh: the stall ending is OFF for this run: OVERTURE_TEST_STALL_END_SECONDS is '${limit}'." >&2
    return 0
  fi
  rm -f "${record}" "${sig}" "${tick}"

  while :; do
    # No handle on the run's output, for test-progress-watch.sh's measured reason: an escaped sleep
    # holding a captured stdout makes every capture wait it out.
    sleep "${interval}" >/dev/null 2>&1
    kill -0 "${run_pid}" 2>/dev/null || return 0
    table="$(process_table)"
    # The first child, without `| head -1`: under pipefail a consumer that exits early can fail the
    # producer, and under the runner's `set -e` that would end this guard silently (L183).
    holder="$(process_children "${table}" "${run_pid}")"
    holder="${holder%%$'\n'*}"

    if ! kill -0 "${runner_pid}" 2>/dev/null; then
      printf 'reason=orphaned\nrunner=%s\nholder=%s\nrun=%s\n' "${runner_pid}" "${holder}" "${run_pid}" > "${record}"
      echo "run-tests-locked.sh: the runner that started this run (PID ${runner_pid}) is gone, so nothing would ever release the lock it holds. Stopping xcodebuild (PID ${holder:-none}) and its flock wrapper (PID ${run_pid}) (#3976)." >&2
      outcome="$(end_run_group "${run_pid}" "${holder}")"
      printf 'ended=%s\n' "${outcome}" >> "${record}"
      return 0
    fi

    # Queued: flock has not forked, so it does not hold the lock. Never counted, and the clock restarts.
    if [[ -z "${holder}" ]]; then
      rm -f "${tick}"
      baseline=""
      continue
    fi

    cpu="$(process_cpu_centis "${table}" "${holder}")"
    # Gone between the two readings of this tick: nothing to judge, so no tick is counted either way.
    [[ -n "${cpu}" ]] || continue
    count="$(progress_count "${log_file}")"
    if [[ -z "${baseline}" ]] || cpu_moved "${baseline}" "${cpu}" "${floor_centis}"; then
      baseline="${cpu}"
      epoch=$(( epoch + 1 ))
    fi
    printf '%s %s\n' "${count}" "${epoch}" > "${sig}"
    stall_tick "${sig}" "${tick}" "${interval}" "${limit}" && continue

    stalled="$(stall_stalled_seconds "${tick}")"
    printf 'reason=stalled\nstalled_seconds=%s\nholder=%s\nholder_cpu=%s\nstall_cpu=%s\nrun=%s\n' \
      "${stalled}" "${holder}" "${cpu}" "$(( cpu >= baseline ? cpu - baseline : 0 ))" "${run_pid}" > "${record}"
    echo >&2
    echo "run-tests-locked.sh: ENDING THIS RUN. It has held the shared test lock and made no progress for $(humanize_seconds "${stalled}"): no test started or finished, and xcodebuild used $(centis_readable "$(( cpu >= baseline ? cpu - baseline : 0 ))") of CPU in that time. Stopping xcodebuild (PID ${holder}) and its flock wrapper (PID ${run_pid}) so the lock is released (#3976)." >&2
    outcome="$(end_run_group "${run_pid}" "${holder}")"
    printf 'ended=%s\n' "${outcome}" >> "${record}"
    return 0
  done
}

RUN_STALL_END_PID=""
start_run_stall_end() {
  start_own_group_job run_stall_end_loop "$@"
  RUN_STALL_END_PID="${OWN_GROUP_JOB_PID}"
  return 0
}

# stop_run_stall_end <guard pid> [record]: stops the guard once the run is over.
#
# When the guard has begun ENDING the run (its record exists), the run's exit is what woke the caller,
# and the guard is still inside end_run_group writing how it went. Killing it there loses the one line
# saying whether anything survived, so it is waited for instead, with a deadline: the guard's own work
# is bounded by the grace period, and a wait with no deadline is a hang (L110).
stop_run_stall_end() {
  local pid="${1:-}" record="${2:-}" waited=0 deadline
  deadline=$(( ${TEST_STALL_END_GRACE_SECONDS//[^0-9]/} + 5 ))
  if [[ -n "${record}" && -e "${record}" && "${pid}" =~ ^[0-9]+$ ]]; then
    while kill -0 "${pid}" 2>/dev/null && [[ "${waited}" -lt "${deadline}" ]]; do
      sleep 1 >/dev/null 2>&1
      waited=$(( waited + 1 ))
    done
  fi
  stop_own_group_job "${pid}"
  return 0
}

# record_field <record text> <key>
record_field() {
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' <<< "$1"
}

# stalled_run_report <record text>: the verdict main prints for a run this guard ended. Never "NOTHING
# RAN", which sends the reader to the -only-testing: scope they typed, and never a pass.
stalled_run_report() {
  local record="$1" reason stalled holder holder_cpu stall_cpu run ended
  reason="$(record_field "${record}" reason)"
  holder="$(record_field "${record}" holder)"
  run="$(record_field "${record}" run)"
  ended="$(record_field "${record}" ended)"
  if [[ "${reason}" == "orphaned" ]]; then
    echo "ORPHANED AND ENDED. The runner that started this run was gone, so this run was ended by its own guard: xcodebuild (PID ${holder:-none}) and its flock wrapper (PID ${run})."
  else
    stalled="$(record_field "${record}" stalled_seconds)"
    holder_cpu="$(record_field "${record}" holder_cpu)"
    stall_cpu="$(record_field "${record}" stall_cpu)"
    echo "STALLED AND ENDED. This run held the shared test lock and made no progress for $(humanize_seconds "${stalled}"): no test started or finished, and xcodebuild (PID ${holder}, $(centis_readable "${holder_cpu}") of CPU in total) used $(centis_readable "${stall_cpu}") in that time. That is what a HUNG run looks like, measured on this Mac twice (#3976), not a slow one."
    echo "This runner ended it: xcodebuild and its flock wrapper (PID ${run}) were stopped, so the shared lock is released rather than held until somebody notices."
    echo "This is NOT a pass and NOT a test failure: nothing after the stall was verified. Run the suite again. If it stalls again, the last test to START above is where to look, and the limit it ended at is OVERTURE_TEST_STALL_END_SECONDS."
  fi
  case "${ended}" in
    survived*)
      echo "These are STILL RUNNING after TERM and KILL, and may still hold the lock:${ended#survived}. End them with: kill -KILL${ended#survived}"
      ;;
  esac
}

# lock_holder_report <owner text> <table when the wait began> <table now> <seconds waited> <lock dir>
#
# Which of the causes a give up on the directory lock actually is. On 2026-09-17 the message offered only
# "a run that died holding it" while the holder was alive and hung, so the reader looked for a corpse. The
# owner is the RUNNER shell (overture:<pid>), whose own CPU is near zero even when healthy, so the reading
# is its whole tree, and it is taken across the wait rather than once, because a total says nothing about
# whether anything is moving now.
lock_holder_report() {
  local owner="$1" start_table="$2" now_table="$3" waited="$4" lock_dir="$5"
  local pid now_cpu start_cpu delta pgid floor_centis
  floor_centis="$(stall_end_floor_centis)"
  pid="${owner##*:}"
  if [[ -z "${owner}" || ! "${pid}" =~ ^[0-9]+$ ]]; then
    echo "Its holder cannot be named: the lock carries no readable owner (${lock_dir}/owner). A run that has only just taken it has not written one yet; one that stayed ownerless for the whole wait was left by a run that died before writing it. If no test run is going on this Mac, remove it with: rm -rf ${lock_dir}"
    return 0
  fi
  now_cpu="$(run_tree_cpu_centis "${now_table}" "${pid}")"
  if [[ -z "${now_cpu}" ]]; then
    echo "Its holder, PID ${pid} (${owner}), is NOT running: a run that died holding it. Remove it with: rm -rf ${lock_dir}"
    return 0
  fi
  pgid="$(process_group_of "${now_table}" "${pid}")"
  start_cpu="$(run_tree_cpu_centis "${start_table}" "${pid}")"
  if [[ -z "${start_cpu}" ]]; then
    echo "Its holder, PID ${pid} (${owner}), is ALIVE and has used $(centis_readable "${now_cpu}") of CPU in total. It was not running when this run began waiting, so how much of that came during the wait was not measured."
    return 0
  fi
  delta=$(( now_cpu >= start_cpu ? now_cpu - start_cpu : floor_centis ))
  if [[ "${delta}" -ge "${floor_centis}" ]]; then
    local busiest busy_pid busy_centis busy_name
    busiest="$(busiest_across "${start_table}" "${now_table}" "${pid}")"
    read -r busy_pid busy_centis busy_name <<< "${busiest}"
    echo "Its holder, PID ${pid} (${owner}), is ALIVE and WORKING: it and everything it started used $(centis_readable "${delta}") of CPU over the ${waited}s this run waited ($(centis_readable "${now_cpu}") in total), most of it PID ${busy_pid:-unknown} (${busy_name:-unnamed}, $(centis_readable "${busy_centis:-0}")). Usually a long run, not a dead or stalled one: wait for it, or raise OVERTURE_DIR_LOCK_TIMEOUT. The exception is a busy test process beside an xcodebuild that barely moved, which is how the 2026-09-17 hang looked (#3976)."
  else
    echo "Its holder, PID ${pid} (${owner}), is ALIVE but STALLED: it and everything it started used $(centis_readable "${delta}") of CPU over the ${waited}s this run waited ($(centis_readable "${now_cpu}") in total). That is a run standing still, not one that died, and it holds the lock until something ends it. End its whole process group with: kill -TERM -${pgid:-${pid}}"
  fi
}
