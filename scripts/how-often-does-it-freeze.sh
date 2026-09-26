#!/usr/bin/env bash
set -uo pipefail

# #3660: the milestone's own bar, read off the app's own record of it, as a COMMAND rather than a number
# somebody typed into a comment.
#
# WHY A RATE AND NOT A COUNT. The bar is "a day of Dan's ordinary use produces no baseline load main
# thread stall over 100 ms". A bare count of records cannot answer that, because a day when Overture sat
# closed and a day of heavy use produce different counts for reasons that have nothing to do with the
# code. The denominator is already in the file and nothing read it: `MainThreadWatchdog.nextSequence()`
# is called on EVERY ping, not on every stall, so the highest sequence in a session times the ping
# interval is how long that session watched (L323).
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not say whether the bar is met. The watchdog's storage floor
# IS the bar, so every stored record is over it by construction and the proportion carries no
# information; what carries information is the rate and the tail. A script that printed PASS or FAIL here
# would be reporting a tautology as a verdict (L98, L178).
#
#   0  a reading was taken and printed
#   2  UNMEASURED: no log, nothing readable in it, or nothing this reader can size

# Captured before anything else runs, so the shared reader below is found wherever this is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

LOG="${HOME}/Library/Application Support/Overture/freeze-log.ndjson"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--log <freeze-log.ndjson>]"
      echo "  Prints the stall distribution and the rate per hour WATCHED, per session and combined."
      echo "  0  a reading was taken"
      echo "  2  UNMEASURED: no log, or nothing in it this reader can size"
      exit 0 ;;
    *) echo "how-often-does-it-freeze: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ ! -f "${LOG}" ]; then
  echo "how-often-does-it-freeze: UNMEASURED. No freeze log at ${LOG}."
  echo "  A missing log and a run of clean sessions are different facts, and this is the first."
  exit 2
fi

# The archive is part of the population, on the same reasoning as scripts/what-froze-the-queue.sh: a
# compaction moves the oldest records out of the live file, and a reader that opened only that file would
# report on the recent window while looking exactly like a reader of the whole history (L46, L98).
ARCHIVE="$(dirname "${LOG}")/freeze-log-archive.ndjson"

# #4188: which records are not freezes is decided in ONE place both freeze log readers import. A missing
# module is refused by name here: Python would otherwise die with a traceback and an exit code the caller
# reads as a result (L488, L490).
if [ ! -f "${LIB_DIR}/freeze_records.py" ]; then
  echo "how-often-does-it-freeze: UNMEASURED. The shared reader ${LIB_DIR}/freeze_records.py is missing."
  exit 2
fi

python3 - "${LOG}" "${ARCHIVE}" "${LIB_DIR}" <<'PY'
import statistics, sys

path, archive_path = sys.argv[1], sys.argv[2]
# No bytecode cache: importing would otherwise leave a __pycache__ inside the checkout on every run.
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[3])
from freeze_records import (BLOCKED, COMPUTING, FREEZE, NOT_A_FREEZE, NOT_RUNNING_UNSPLIT, STARVED, UNMEASURED,
                            freeze_verdict, load, main_thread_verdict, menu_idle, plural, run_loop_measured,
                            sleep_measured, slept)

# #4122: a compaction note is not a stall. Before #4188 this reader counted it as one, in a session of
# its own named "?", so every total here was one higher than the stalls it described.
rows, _notes, unreadable, sources = load(path, archive_path)

if not rows:
    print(f"how-often-does-it-freeze: UNMEASURED. {path} holds no records.")
    if unreadable:
        print(f"  {unreadable} line(s) could not be read.")
    sys.exit(2)

sessions = {}
for r in rows:
    sessions.setdefault(r.get("session", "?"), []).append(r)


def quantile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * p))]


# WHICH FLOOR A SESSION WAS WATCHING AT. #3752 took the ping interval from 0.25s to 0.1s and the storage
# floor is DERIVED from it, so the two are different populations and pooling them would compare a period
# that could not see a 150 ms stall with one that could (L216).
#
# THE RECORD DOES NOT SAY, so this is INFERRED, and the inference only works in one direction. A stored
# stall under 0.25s could only have been stored by the finer floor, so it PROVES 100 ms. A session whose
# smallest stall is above 0.25s proves nothing at all: it is either an old session or a recent one that
# happened to have no small stalls, and those are not the same thing. It is reported as UNKNOWN rather
# than assumed old, because assuming would silently drop a comparable session out of the reading and the
# count would still look complete (L11, L98). The real repair is for the record to CARRY the interval,
# which is #3815's neighbourhood; until it does, this reader says what it cannot tell.
def interval_of(group):
    return 0.1 if min(r.get("seconds", 0) for r in group) < 0.25 else None


print(f"how-often-does-it-freeze: {len(rows)} record(s) over {plural(len(sessions), 'session')}.")
print(f"  read from: {', '.join(sources)}")
print()
# #4188: `not freezes` is how many of a session's stalls say of themselves that they are not one, and
# `unjudged` how many carry no reading to say either way. Both stay IN the row's figures: the columns name
# them so a session whose stalled time is one long sleep cannot pass for a session that froze (L116).
print("  session    floor   watched   stalls   per hour   stalled    share   not freezes   unjudged")
modern, modern_watched, unknown_floor = [], 0.0, 0
for name, group in sorted(sessions.items(), key=lambda kv: kv[1][0].get("at", "")):
    interval = interval_of(group)
    if interval is None:
        unknown_floor += 1
        print(f"  {name[:8]}      ?    UNKNOWN floor, so not comparable ({len(group)} record(s), "
              f"smallest {min(r.get('seconds', 0) for r in group):.3f}s)")
        continue
    # The sequence counts PINGS, not stalls, so this is watching time rather than a count of anything.
    watched = max(r.get("sequence", 0) for r in group) * interval
    stalled = sum(r.get("seconds", 0) for r in group)
    if watched <= 0:
        print(f"  {name[:8]}   {interval * 1000:3.0f}ms   UNMEASURED (no sequence to size it by)")
        continue
    rate = len(group) / (watched / 3600)
    not_freezes = sum(1 for r in group if freeze_verdict(r) == NOT_A_FREEZE)
    unjudged = sum(1 for r in group if freeze_verdict(r) == UNMEASURED)
    print(f"  {name[:8]}   {interval * 1000:3.0f}ms   {watched / 3600:6.2f}h   {len(group):6}   "
          f"{rate:8.1f}   {stalled:6.1f}s   {100 * stalled / watched:5.2f}%   {not_freezes:11}   {unjudged:8}")
    modern.extend(group)
    modern_watched += watched

print()
if unknown_floor:
    print()
    print(f"  {plural(unknown_floor, 'session')} could not be placed at either floor and are left out")
    print("  of everything below. Nothing in a record says which interval was watching; a stall under")
    print("  0.25s proves the finer one, and nothing proves the coarser one.")

if not modern:
    print()
    print("  UNMEASURED at the current floor: no session here can be SHOWN to have been watching at")
    print("  100 ms, so nothing is comparable with a reading taken after #3752. A count from a")
    print("  coarser floor is not a smaller number of stalls, it is a number of LARGER stalls.")
    sys.exit(2)

baseline = [r for r in modern if r.get("load") == "baseline"]
if not baseline:
    print("  UNMEASURED at baseline load: every record at the current floor was taken while the")
    print("  machine was busy, and the bar is about a quiet one.")
    sys.exit(2)

def distribution(label, group):
    secs = [r.get("seconds", 0) for r in group]
    print(f"    {label}  n={len(secs)}   p50 {statistics.median(secs):.3f}s   p90 {quantile(secs, 0.90):.3f}s   "
          f"p95 {quantile(secs, 0.95):.3f}s   p99 {quantile(secs, 0.99):.3f}s   max {max(secs):.3f}s")


print()
print("  THE BAR is about baseline load at the 100 ms floor, so that is the only comparable set.")
distribution("every record:", baseline)

# #4188: the same set WITHOUT the records that say of themselves they are not freezes, stated beside it
# rather than instead of it (L116). #3660 reads this block, so each line names what it counts and the
# three states are counted apart: a record with no reading is neither excluded nor called a freeze (L98).
_verdicts = [freeze_verdict(r) for r in baseline]
_not = [r for r, v in zip(baseline, _verdicts) if v == NOT_A_FREEZE]
_unjudged = [r for r, v in zip(baseline, _verdicts) if v == UNMEASURED]
_kept = [r for r, v in zip(baseline, _verdicts) if v != NOT_A_FREEZE]
if _not:
    label = f"without the {len(_not)} that are not freezes:" if len(_not) != 1 else \
        "without the 1 that is not a freeze:"
    if _kept:
        distribution(label, _kept)
    else:
        print(f"    {label}  n=0. Every record here says of itself that it is not a freeze, so this set")
        print("      states no measured freeze at all.")
    _slept = sum(1 for r in _not if slept(r))
    _menu = sum(1 for r in _not if menu_idle(r) and not slept(r))
    reasons = []
    if _slept:
        reasons.append(f"{_slept} spanned a sleep (#4153)")
    if _menu:
        verb = "was" if _menu == 1 else "were"
        reasons.append(f"{_menu} {verb} taken while a menu tracked and ran no render pass (#4114)")
    print(f"    not freezes: {', '.join(reasons)}.")
    print("      Marked rather than dropped: the first line keeps them.")
if _unjudged:
    _no_sleep = sum(1 for r in _unjudged if not sleep_measured(r))
    _no_loop = sum(1 for r in _unjudged if not run_loop_measured(r))
    print(f"    {len(_unjudged)} of the {len(baseline)} cannot be judged: {_no_sleep} carry no sleep reading, "
          f"{_no_loop} no run loop reading.")
    print("      Absent is not zero, so they are in EVERY line above, neither excluded nor shown to be")
    print("      freezes. Any of them may be a sleep or an open menu. Install a build carrying #4153 and")
    print("      #4114 and read again.")
if not _not and not _unjudged:
    print(f"    none of the {len(baseline)} is shown not to be a freeze: each carries a sleep and a run loop")
    print("      reading, and neither says it was a sleep or an idle open menu.")
_other = [r for r, v in zip(baseline, _verdicts) if v == FREEZE and r.get("runLoopActivity") == "otherMode"]
if _other:
    print(f"    {len(_other)} of those counted were taken in a run loop mode this build does not name, so")
    print("      what they are is UNKNOWN rather than shown to be a freeze. They stay in every line.")

# THE RATE is over EVERY load, never baseline alone, because watched time cannot be split by load: a
# record carries its load, a ping does not. A baseline count over all watched time would mix two
# populations in one fraction and understate the rate by however much busy time was watched (L711).
_modern_not = sum(1 for r in modern if freeze_verdict(r) == NOT_A_FREEZE)
print(f"    rate, every load (watched time cannot be split by load): {len(modern)} stall(s) over "
      f"{modern_watched / 3600:.2f}h watched, {len(modern) / (modern_watched / 3600):.1f} per hour")
if _modern_not:
    _left = len(modern) - _modern_not
    print(f"      without the {_modern_not} not freezes at every load: {_left} stall(s), "
          f"{_left / (modern_watched / 3600):.1f} per hour")
# #4154: what the main thread was doing across those stalls, at EVERY load, because starvation is a
# property of a contended machine and a baseline-only count would hide the population it describes. A day
# of stalls the main thread spent runnable and unscheduled is not a day the code got slower, and before
# this field nothing in the file could tell the two apart. Absent is its own count (L98).
_threads = [main_thread_verdict(r) for r in modern]
print(f"    main thread, every load: {_threads.count(COMPUTING)} computing, {_threads.count(STARVED)} starved, "
      f"{_threads.count(BLOCKED)} blocked, {_threads.count(NOT_RUNNING_UNSPLIT)} not running unsplit, "
      f"{_threads.count(UNMEASURED)} unmeasured")
if _threads.count(STARVED):
    print("      starved is runnable and not scheduled: another process had the CPU (#4154).")
print()
print("  Read as a RATE, never as a proportion over the bar: the watchdog's storage floor IS the")
print("  bar, so 100 percent of these are over it by construction and that says nothing (L178).")
print("  Watched time is a LOWER bound, because a ping is not posted while one is outstanding, so")
print("  fewer are issued during a long freeze. The per hour figure is therefore an upper bound.")

# A session sitting exactly on the cap is AMBIGUOUS, and the two readings call for different treatment
# of every figure above.
#
# Before #3812's fix the watchdog wrote a record only when its in-memory kept set GREW, so a session
# stopped writing at its 200th stall and said nothing. A session written by such a build holds the FIRST
# 200 stalls of that session and no more. Measured on Dan's own log 2026-09-12, three of ten sessions sat
# on exactly 200, which is the cap rather than the app.
#
# A build carrying the fix writes every stall at or above the floor whatever the kept set does, so there
# exactly 200 is an ordinary count and nothing is missing. NOTHING IN A RECORD SAYS WHICH BUILD WROTE IT,
# so this reader cannot tell the two apart and says so rather than choosing (L11, L440). The mirror of
# `StallLog.cap` below is held against the app's own constant by `TheCapThisReaderNamesTests`.
CAP = 200
at_the_cap = [n for n, g in sessions.items() if len(g) == CAP]
if at_the_cap:
    print()
    verb = "holds" if len(at_the_cap) == 1 else "hold"
    print(f"  {plural(len(at_the_cap), 'session')} {verb} exactly {CAP} records, the in-memory cap.")
    print(f"  Written before #3812 that means the session STOPPED recording at its {CAP}th stall, and")
    print(f"  every figure above for it is UNDERSTATED. Written after it, {CAP} is an ordinary count")
    print("  and nothing is missing. No record says which build wrote it, so the two cannot be told")
    print("  apart from this file.")
    for name in at_the_cap:
        print(f"    {name[:8]}  last record {max(r.get('at', '') for r in sessions[name])[:19]}")

if unreadable:
    print()
    print(f"  {unreadable} line(s) could not be read.")
PY
