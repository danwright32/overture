#!/usr/bin/env bash
set -uo pipefail

# #3760: what a freeze was, read off the app's own record of it.
#
# WHY THIS EXISTS. On 2026-09-10 the queue froze for 16.73s at baseline load on a build carrying every fix
# in milestone 80, and nothing could say what it was. One store change costs 350.7 ms end to end, measured
# the same day, so that freeze is forty-eight of them or it is something else entirely, and those two call
# for opposite work. #3760 put the count of render passes onto the stall record; this is its reader, so
# the field has one in the toolchain rather than only in whoever remembers to open the file (L46).
#
# It REPORTS. It does not judge a stall against a cost figure, deliberately: a per-pass cost written into
# this script would be a dated number that rots silently and reads as more trustworthy the older it gets
# (L316, #3487). A long stall that spanned many passes is the render pass being run over and over.
#
# WHAT THE COUNT CANNOT SAY, which is #3783 and is the half this tool used to get wrong. The counter is
# bumped by the first line of `QueueView.makeRenderData()`, so it counts BODY EVALUATIONS of one view.
# Three kinds of main thread work sit outside it and every one of them reads as zero:
#
#   the `@Query` fetch that feeds that body, which is paid before the counting line runs and which #3750
#     prices as its own arm of a store change;
#   every other surface that runs its own derivation and bumps nothing (#3762);
#   main thread work that is not a render pass at all, a save, a scout write, the launch task.
#
# So a zero is UNATTRIBUTED, never "the surface did not rebuild". That second sentence is a claim about a
# quantity this counter never measured, and it was sending the next diagnosis away from the queue on the
# strength of it (L11, L144, L440). Until one of the three above is instrumented, zero narrows nothing.
#
# WHAT IT WILL SAY TODAY, stated so nobody reads it as a finding: every record written before #3760 is
# installed carries no pass count at all, so on a log that has not turned over it answers UNMEASURED. That
# is the honest answer and not a fault.

# Captured before anything else runs, so the shared reader below is found wherever this is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

LOG="${HOME}/Library/Application Support/Overture/freeze-log.ndjson"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--log <freeze-log.ndjson>]"
      echo "  0  every stall carrying a count is accounted for by the passes it spans"
      echo "  1  a stall over the floor counted NO render pass, so it is UNATTRIBUTED"
      echo "  2  UNMEASURED: no log, or no record in it carries a pass count"
      exit 0 ;;
    *) echo "what-froze-the-queue: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ ! -f "${LOG}" ]; then
  echo "what-froze-the-queue: UNMEASURED. No freeze log at ${LOG}."
  echo "  A missing log and a session with no freezes are different facts, and this is the first."
  exit 2
fi

# #3763: the archive beside the live log is part of the population. A compaction moves the oldest records
# out of the live file, and the archive is where the "before" half of milestone 80's comparison lives, so a
# reader that opened only the live file would report on the recent window while looking exactly like a
# reader of the whole history (L46, L98). Derived from the live log's own directory, the same way
# `FreezeLog.archiveURL(besideLogAt:)` derives it, rather than taken as a second argument nobody passes.
ARCHIVE="$(dirname "${LOG}")/freeze-log-archive.ndjson"

# #4188: loading the log and deciding which records are not freezes live in ONE module this and
# scripts/how-often-does-it-freeze.sh both import, so the two readers cannot disagree about the population
# they both describe (L216, L263). A missing module is refused by name: Python would otherwise die with
# exit 1, which this script's callers read as a finding (L488, L490).
if [ ! -f "${LIB_DIR}/freeze_records.py" ]; then
  echo "what-froze-the-queue: UNMEASURED. The shared reader ${LIB_DIR}/freeze_records.py is missing."
  exit 2
fi

python3 - "${LOG}" "${ARCHIVE}" "${LIB_DIR}" <<'PY'
import sys

path, archive_path = sys.argv[1], sys.argv[2]
# No bytecode cache: importing would otherwise leave a __pycache__ inside the checkout on every run.
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[3])
from freeze_records import (BLOCKED, COMPUTING, NOT_RUNNING_UNSPLIT, STARVED, load, main_thread_measured,
                            main_thread_share, main_thread_verdict, menu_idle, run_loop_measured,
                            sleep_measured, slept, tracking)

# #4122: the compaction notes the live file carries come back apart from the stalls. A note is not a
# stall, and letting one into `rows` would add a record with no `seconds` and no `passes` to every
# population counted below. The archive is read first, so the combined list is roughly chronological.
rows, notes, unreadable, sources = load(path, archive_path)

# A record written before #3760 shipped has no `passes` key at all. That is not a zero: it is a record
# this tool cannot judge, and folding it into either verdict is the whole thing this exit code exists
# to prevent (L98, L11).
counted = [r for r in rows if isinstance(r.get("passes"), int)]
uncounted = [r for r in rows if "passes" not in r or r.get("passes") is None]

if not rows:
    print(f"what-froze-the-queue: UNMEASURED. {path} holds no records.")
    if unreadable:
        print(f"  {unreadable} line(s) could not be read.")
    sys.exit(2)

if not counted:
    print(f"what-froze-the-queue: UNMEASURED. {len(rows)} record(s), and no record carries a pass count.")
    print("  Every record written before #3760 is installed has none, so this is what a log that has")
    print("  not turned over says. Install a build carrying it and read again.")
    sys.exit(2)

counted.sort(key=lambda r: -r.get("seconds", 0))
print(f"what-froze-the-queue: {len(counted)} stall(s) with a pass count, of {len(rows)} record(s).")
# Named rather than assumed: a reading built from the live file alone and one built from the whole history
# are different populations, and without this line they print identically (L11).
print(f"  read from: {', '.join(sources)}")
# #4122: WHAT WINDOW this is, said before any figure derived from it. The live file keeps the newest 500
# records and promotes the single longest older stall back into them, so a reading over it is a truncated
# window with one out of band member in it. Dan's file on 2026-09-21 opened with a 1,047 second stall from
# three days earlier followed by that evening's records, and nothing said so.
if notes:
    for n in notes:
        _kept, _archived = n.get("kept", "?"), n.get("archived", "?")
        print(f"  window: a compaction on {str(n.get('at', ''))[:19].replace('T', ' ')} kept {_kept} "
              f"record(s) here and moved {_archived} to the archive.")
        if n.get("promotedAt"):
            print("    One of the {} is PROMOTED from the older half: the {:.2f}s stall of {}. It is not"
                  .format(_kept, n.get("promotedSeconds", 0),
                          str(n.get("promotedAt", ""))[:19].replace("T", " ")))
            print("    part of this window, and it is marked `promotedFromOlderWindow` on its own line.")
        else:
            print("    Nothing was promoted, so every record in the live file is inside that window.")
elif any(r.get("promotedFromOlderWindow") for r in rows):
    print("  window: a record marks itself as promoted from an older window, but no compaction note")
    print("    accompanies it. Treat the live file's oldest record as out of band.")
else:
    print("  window: no compaction note in this reading. Either nothing has ever been compacted, or the")
    print("    file predates #4122, and those are different facts this file cannot separate.")
# #3783: said on EVERY reading rather than only when there is a finding, because the clean reading is the
# one most likely to be quoted as "the render pass accounts for it" and the one where the terms outside
# the count are easiest to forget (L440, L629).
print("  the count covers one thing: it counts QueueView body evaluations. The @Query fetch that")
print("  feeds them (#3750), the surfaces that bump nothing (#3762) and every main thread job that")
print("  is not a render pass are all outside it, and all of them read as zero.")

# #3859: what a `queue` record MEANS depends on the build that wrote it, and the two are in the same file.
#
# Before #3859 seven of the twelve sheets had no StallSurface case and fell through to `queue`, so a
# `queue` record from such a build is the queue OR any of those seven. Records written after it are the
# queue alone. Said on every reading rather than only when both are present, because the mixed half is
# the larger one today and a distribution quoted without this line is two populations in one number
# (L216, L11). The stamp is the record's own `surfaceVocabulary`, absent on every older record.
_old_vocabulary = [r for r in rows if r.get("surfaceVocabulary") is None]
_new_vocabulary = [r for r in rows if r.get("surfaceVocabulary") is not None]
print()
print("  surface vocabulary: {} record(s) written before #3859, {} after.".format(
    len(_old_vocabulary), len(_new_vocabulary)))
if _old_vocabulary and _new_vocabulary:
    print("  A `queue` in the first group is the queue OR any of seven sheets that had no case of their")
    print("  own. A `queue` in the second is the queue. Do not add the two counts together.")
elif _old_vocabulary:
    print("  Every record here predates #3859, so every `queue` is the queue OR any of seven sheets over")
    print("  it. Nothing in this file can say which.")
print()
print("  when                  seconds  passes  root  in passes   asleep     cpu  surface        load")
for r in counted[:25]:
    when = str(r.get("at", ""))[:19].replace("T", " ")
    cost = r.get("passSeconds")
    shown = "{:>9.2f}".format(cost) if isinstance(cost, (int, float)) else "        ?"
    # #3813: a record with no root count prints "?" rather than 0, because absent and none are different
    # answers and a 0 there would read as "the window did not rebuild" (L98, L11).
    root = r.get("rootDraws")
    root_shown = "{:>4}".format(root) if isinstance(root, int) else "   ?"
    # #4153: how much of `seconds` the Mac was ASLEEP for. "?" rather than 0 on a record written before
    # the field shipped, for the same reason `rootDraws` prints "?": absent and none are different
    # answers, and a 0 here would read as "the machine stayed awake" (L98, L11).
    asleep = r.get("asleepSeconds")
    asleep_shown = "{:>7.2f}".format(asleep) if isinstance(asleep, (int, float)) else "      ?"
    # #4154: the share of the stall's awake time the main thread spent on the CPU. "?" where the record
    # carries no reading, for the reason the two columns before it do.
    cpu_share = main_thread_share(r)
    cpu_shown = "{:>6.0f}%".format(100 * cpu_share) if cpu_share is not None else "      ?"
    print("  {:<20}  {:>7.2f}  {:>6}  {}  {}  {}  {}  {:<13}  {}".format(
        when, r.get("seconds", 0), r["passes"], root_shown, shown, asleep_shown, cpu_shown,
        str(r.get("surface", "?")), str(r.get("load", "?"))))
if len(counted) > 25:
    print(f"  ... and {len(counted) - 25} more, shown longest first.")

# #3815: what the count alone could never say, which is whether those passes ACCOUNT for the freeze.
#
# A 16.73s stall spanning one pass has two incompatible explanations and the count chooses neither: one
# pass that ran for 16 seconds, so the pass IS the freeze, or one ordinary pass and 16 seconds spent
# somewhere else. The duration beside it is what separates them. Converting the count with a cost figure
# from a test would be arithmetic on somebody else's measurement, taken on a quiet machine on a healthy
# pass, which is not the pass that faulted a relationship storm (L107).
#
# WHAT THE DURATION CANNOT SAY. It is added when a pass RETURNS and the count is bumped when it STARTS, so
# a pass that never returned is in the count and not in the seconds. A record with a count and no duration
# is therefore NOT a pass that took no time, and is not judged either way here: every record on Dan's Mac
# today is one of those (L98, L11).
ACCOUNTED = 0.5     # a stall whose passes are at least half of it is one the passes explain

timed = [r for r in counted if isinstance(r.get("passSeconds"), (int, float))]
untimed_count = len(counted) - len(timed)

if timed:
    print()
    shares = [(r, r["passSeconds"] / r["seconds"]) for r in timed if r.get("seconds", 0) > 0]
    explained = [r for r, share in shares if share >= ACCOUNTED]
    unexplained = [(r, share) for r, share in shares if share < ACCOUNTED]
    print(f"  {len(timed)} stall(s) carry how long their passes took.")
    if explained:
        longest = max(explained, key=lambda r: r["seconds"])
        share = longest["passSeconds"] / longest["seconds"]
        print(f"    {len(explained)} of them their passes account for, worst {longest['seconds']:.2f}s "
              f"with {longest['passSeconds']:.2f}s in passes ({100 * share:.0f}%).")
    if unexplained:
        worst, share = max(unexplained, key=lambda pair: pair[0]["seconds"])
        print(f"    {len(unexplained)} of them their passes do not account for, worst "
              f"{worst['seconds']:.2f}s with {worst['passSeconds']:.2f}s in passes "
              f"({100 * share:.0f}%). Whatever that time was, it was not a counted render pass.")
if untimed_count:
    print(f"  {untimed_count} carry no pass duration, so whether their passes account for them is")
    print("  unknown. A pass that never RETURNED is one of these, and so is every record written")
    print("  before the duration shipped.")

# #4153: which of these records are not freezes at all, because the Mac was asleep through them.
#
# The longest record in Dan's log on 2026-09-22 was 1057.90s and `pmset -g log` puts a 1074 second sleep
# ending at that instant exactly. At 49 times the next longest it sets every maximum and percentile taken
# from this file, and this milestone's bar is judged against this file. The record is MARKED rather than
# dropped, here as in the app, because an exclusion would also hide a real freeze that overlapped a sleep
# (L116), so this names them and says what the reading looks like without them.
#
# Reported only where the field is PRESENT. Every record written before #4153 shipped has none, and
# absent is not zero: a reader told "0 slept" about a record nobody measured would draw exactly the wrong
# conclusion from it (L98).
_sleep_measured = [r for r in rows if sleep_measured(r)]
_slept_through = [r for r in _sleep_measured if slept(r)]
print()
if not _sleep_measured:
    print(f"  sleep: UNMEASURED. None of the {len(rows)} record(s) says whether the Mac was asleep, so")
    print("  every one of them predates #4153 and the longest figure below may be a sleep rather than a")
    print("  freeze. Install a build carrying it and read again.")
elif not _slept_through:
    print(f"  sleep: {len(_sleep_measured)} record(s) carry a sleep reading and none of them spanned any")
    print("  sleep, so every duration here is time the main thread was running and late.")
else:
    _worst = max(_slept_through, key=lambda r: r["asleepSeconds"])
    print(f"  sleep: {len(_slept_through)} of {len(_sleep_measured)} record(s) carrying a reading spanned")
    print("  a sleep, so their duration is mostly the Mac not being scheduled rather than the main")
    print("  thread being blocked. They are NOT freezes and must be left out of any maximum or")
    print("  percentile taken from this file.")
    _when = str(_worst.get("at", ""))[:19].replace("T", " ")
    print("    worst: {}  {:.2f}s recorded, {:.2f}s of it asleep".format(
        _when, _worst.get("seconds", 0), _worst["asleepSeconds"]))
    _awake = [r for r in _sleep_measured if r["asleepSeconds"] == 0]
    if _awake:
        _longest_awake = max(_awake, key=lambda r: r.get("seconds", 0))
        print("    the longest record that spanned no sleep at all is {:.2f}s, and that is the figure a"
              .format(_longest_awake.get("seconds", 0)))
        print("    maximum should quote.")
    else:
        print("    every record carrying a reading spanned a sleep, so this file states no measured")
        print("    maximum for a real freeze at all.")

# #4114: which of these records were taken while the main run loop was TRACKING a menu.
#
# While a menu tracks, the main thread sits in a nested event loop, and the watchdog's ping can wait
# there while the app is doing nothing wrong. Measured 2026-09-21: Dan opened a card's genre dropdown and
# clicked away without choosing anything, and the log recorded 1.62s and 1.17s stalls whose stack sample
# has the main thread idle 95.5% with no Overture code running at all.
#
# ONLY `tracking` IS COUNTED AS THAT, and the reason is a measurement rather than caution. A probe of a
# sheet-presented NSAlert on 2026-09-23, which is what SwiftUI's `.alert` becomes here, saw the main run
# loop pass through `_NSMoveTimerRunLoopMode` on the way in and out with nothing wrong. Counting every
# mode this build cannot name as menu time would therefore accuse ordinary window work (L93, L11). Those
# records get their own line below, saying what they are, which is unknown.
#
# MARKED, NEVER DROPPED, here as in the app, because an exclusion would also hide a real freeze that
# happened to occur while a menu was open (L116). So this names them and says what the reading looks like
# without them, and it does not decide for the reader: a tracking record carrying real render time is a
# genuine freeze that overlapped a menu, and one carrying none is the contaminated shape. The two are
# separated here by `passes` and `passSeconds`, which is the judgement #4114 asked to be made explicit.
_activity_measured = [r for r in rows if run_loop_measured(r)]
_tracking = [r for r in _activity_measured if tracking(r)]
print()
if not _activity_measured:
    print(f"  run loop: UNMEASURED. None of the {len(rows)} record(s) says what the main run loop was")
    print("  doing, so every one of them predates #4114 and any of them may be menu-open time rather")
    print("  than a freeze. Install a build carrying it and read again.")
else:
    if not _tracking:
        print(f"  run loop: {len(_activity_measured)} record(s) carry a reading and none was taken while a")
        print("  menu was tracking, so none of them is menu-open time.")
    else:
        # The contaminated shape is a tracking record that ran NO render pass and spent NO time in one. A
        # record that spanned real render time is a freeze whatever mode it was in, so it is counted
        # apart rather than swept in with the others (L11).
        _idle = [r for r in _tracking if menu_idle(r)]
        _busy = [r for r in _tracking if not menu_idle(r)]
        _idle_seconds = sum(r.get("seconds", 0) for r in _idle)
        _all_seconds = sum(r.get("seconds", 0) for r in rows)
        print(f"  run loop: {len(_tracking)} of {len(_activity_measured)} record(s) carrying a reading")
        print("  were taken while a menu was tracking.")
        if _idle:
            _worst = max(_idle, key=lambda r: r.get("seconds", 0))
            _when = str(_worst.get("at", ""))[:19].replace("T", " ")
            _share = (100 * _idle_seconds / _all_seconds) if _all_seconds else 0
            print("    {} of them ran no render pass and spent no time in one, together {:.1f}s of a"
                  .format(len(_idle), _idle_seconds))
            print("    claimed {:.1f}s ({:.1f}%). Those are menu-open time rather than freezes, and a"
                  .format(_all_seconds, _share))
            print("    maximum or a percentile answering #3660's bar must be taken without them.")
            print("      worst: {}  {:.2f}s".format(_when, _worst.get("seconds", 0)))
        if _busy:
            _worst_busy = max(_busy, key=lambda r: r.get("seconds", 0))
            print("    {} of them DID run render passes, so they are real freezes that happened to"
                  .format(len(_busy)))
            print("    overlap a menu and they stay in every population. Worst {:.2f}s.".format(
                _worst_busy.get("seconds", 0)))
    # The other two readings, each said in its own words rather than folded into the accusation above.
    _off = [r for r in _activity_measured if r["runLoopActivity"] == "offTheRunLoop"]
    if _off:
        print("    {} record(s) were taken with the main thread OFF the run loop entirely, which is the"
              .format(len(_off)))
        print("    main thread in code and is the opposite reading: those are freezes.")
    _other = [r for r in _activity_measured if r["runLoopActivity"] == "otherMode"]
    if _other:
        _worst_other = max(_other, key=lambda r: r.get("seconds", 0))
        print("    {} record(s) were taken in a run loop mode this build does not name. Whether those"
              .format(len(_other)))
        print("    are freezes is UNKNOWN: an unnamed mode is not evidence either way, and ordinary")
        print("    window work passes through one. Worst {:.2f}s, and it is worth looking at.".format(
            _worst_other.get("seconds", 0)))

# #4154: whether the MAIN THREAD was running while each stall lasted, which is what a stall's duration and
# its pass time cannot say: both are wall clock. Reproduced 2026-09-25 against a clone of the live store,
# a pass under CPU contention took 5.45s with the main thread's own CPU clock at 23% of it and the kernel
# reporting it runnable. Named per state, and never folded: absent is not computing (L98, L11).
_thread = [r for r in rows if main_thread_measured(r)]
print()
if not _thread:
    print(f"  main thread: UNMEASURED. None of the {len(rows)} record(s) carries the main thread's own CPU")
    print("  reading, so none of them can say whether its time was work, waiting for a core, or waiting on")
    print("  a lock or a read. Install a build carrying #4154 and read again.")
else:
    _by = {}
    for r in _thread:
        _by.setdefault(main_thread_verdict(r), []).append(r)
    print(f"  main thread: {len(_thread)} record(s) carry its own CPU reading.")
    _said = {
        COMPUTING: "the main thread was on the CPU for at least half of it: the code was the time",
        STARVED: "runnable and not scheduled: other processes had the CPU, which no change here removes",
        BLOCKED: "waiting in the kernel: a lock, a read or a semaphore, which is worth a stack sample",
        NOT_RUNNING_UNSPLIT: "not running, and no run state sample to say whether starved or blocked",
    }
    for state in (STARVED, BLOCKED, COMPUTING, NOT_RUNNING_UNSPLIT):
        group = _by.get(state, [])
        if not group:
            continue
        worst = max(group, key=lambda r: r.get("seconds", 0))
        label = state.upper() if state != NOT_RUNNING_UNSPLIT else state
        print(f"    {len(group)} {label}: {_said[state]}.")
        print("      worst {:.2f}s with {:.2f}s on the CPU".format(
            worst.get("seconds", 0), worst["mainThreadCPUSeconds"]))
    _unmeasured = len(rows) - len(_thread)
    if _unmeasured:
        print(f"    {_unmeasured} record(s) carry no reading and are not judged either way.")

# The finding. A stall over the floor that counted no pass is UNATTRIBUTED: this tool cannot say what the
# main thread was doing, and #3783 is why it must not guess.
FLOOR = 1.0
silent = [r for r in counted if r["passes"] == 0 and r.get("seconds", 0) >= FLOOR]

print()
if uncounted:
    print(f"  {len(uncounted)} carry no pass count and are not judged either way.")
if unreadable:
    print(f"  {unreadable} line(s) could not be read.")

# #3783: printed on both exits, because "no stall ever spanned more than one pass" is the reading that
# refutes a burst of re-derivations, and nothing printed it. Measured on Dan's live log 2026-09-11 it was
# 1 across 576 records, a 29.35s stall among them.
most = max(r["passes"] for r in counted)

if silent:
    print()
    print(f"  {len(silent)} stall(s) over {FLOOR:.0f}s counted NO render pass. They are UNATTRIBUTED.")
    print("  Zero is not evidence that the surface stayed still. It says only that nothing bumped the")
    print("  counter, and the fetch before the body (#3750), the other surfaces (#3762) and every job")
    print("  on the main thread that is not a render pass all fail to bump it. Narrowing these needs")
    print("  one of those three instrumented, not a conclusion drawn from their shared silence.")
    # #3813: one of those three is instrumented now. A stall that counted no render pass but DID count
    # RootView draws is a window that was rebuilding while the surface inside it stood still, which is a
    # different thing from a main thread busy with something that draws nothing. Reported only where the
    # field is present: on every record written before #3813 it is absent, and absent is not zero (L98).
    _root_counted = [r for r in silent if isinstance(r.get("rootDraws"), int)]
    _root_drew = [r for r in _root_counted if r["rootDraws"] > 0]
    if not _root_counted:
        print("  None of them carries a RootView draw count, so they all predate #3813 and this tool")
        print("  cannot tell a rebuilding window from a busy main thread for any of them.")
    else:
        print("  Of the {} carrying a RootView draw count, {} drew the window anyway: for those the "
              "main".format(len(_root_counted), len(_root_drew)))
        print("  thread was rebuilding RootView while the surface inside it stood still, which is a")
        print("  different explanation from a main thread doing something that draws nothing at all.")
    for r in silent[:10]:
        when = str(r.get("at", ""))[:19].replace("T", " ")
        print(f"    {when}  {r.get('seconds', 0):.2f}s on {r.get('surface', '?')}")
    print()
    print(f"  Most passes spanned by any stall: {most}.")
    sys.exit(1)

longest = counted[0]
print(f"  Longest counted stall: {longest.get('seconds', 0):.2f}s spanning {longest['passes']} pass(es).")
print(f"  Most passes spanned by any stall: {most}.")
sys.exit(0)
PY
