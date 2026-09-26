# #4188: the ONE place that reads the freeze log and decides what a record says about itself.
#
# Two readers open `freeze-log.ndjson`: scripts/what-froze-the-queue.sh, which says what a stall was, and
# scripts/how-often-does-it-freeze.sh, which counts them for #3660's bar. Until #4188 only the first had
# been taught that some records are not freezes, so the two disagreed about the population they both
# describe, which is the mixed population problem one level up (L216, L46). Both now import this, so a
# third distinction taught here reaches both at once rather than one of them (L263, L370).
#
# THREE STATES, never two. A record whose field SAYS it is not a freeze, a record whose fields say
# nothing of the kind, and a record carrying no reading at all. The third is every record written before
# #4153 or #4114 shipped, and absent is not zero: folding it into either of the others would claim a
# measurement nobody took (L98, L11).
#
# MARKED, NEVER DROPPED. Nothing here removes a record. It says what each one is, and the readers state a
# figure with and without the records that are not freezes, because an exclusion would also hide a real
# freeze that overlapped a sleep or a menu (L116).

import json
import math
import os

# The three answers `freeze_verdict` gives. Spelled once, here, so a reader cannot compare against a typo.
NOT_A_FREEZE = "not a freeze"
FREEZE = "freeze"
UNMEASURED = "unmeasured"


def load(path, archive_path):
    """Read the archive (if present) then the live file.

    Returns (rows, notes, unreadable, sources). The ARCHIVE first, so the combined list is roughly
    chronological: a compaction only ever moves records OLDER than everything the live file kept (#3763).
    A compaction note (#4122) carries the `note` key no stall record has, and is kept apart: letting one
    into `rows` adds a record with no `seconds` to every population counted, which is the defect these
    tools exist to report arriving through the tool itself (L387)."""
    rows, notes, sources = [], [], []
    unreadable = 0

    def one(p):
        nonlocal unreadable
        added = 0
        with open(p) as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed = json.loads(line)
                except ValueError:
                    unreadable += 1
                    continue
                if isinstance(parsed, dict) and "note" in parsed:
                    notes.append(parsed)
                    continue
                rows.append(parsed)
                added += 1
        return added

    if os.path.exists(archive_path):
        sources.append(f"{os.path.basename(archive_path)} ({plural(one(archive_path), 'record')})")
    sources.append(f"{os.path.basename(path)} ({plural(one(path), 'record')})")
    return rows, notes, unreadable, sources


def plural(n, word):
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


# #4153: whether the Mac was asleep through the record. PRESENT means a number; anything else is a
# record written before the field shipped.
def sleep_measured(r):
    return isinstance(r.get("asleepSeconds"), (int, float)) and not isinstance(r.get("asleepSeconds"), bool)


def slept(r):
    return sleep_measured(r) and r["asleepSeconds"] > 0


# #4114: what the main run loop was doing. The app writes `notRecorded` where nothing was sampled, which
# is a spelling of absent rather than a reading, so it counts as unmeasured here exactly as a missing key.
def run_loop_measured(r):
    return isinstance(r.get("runLoopActivity"), str) and r["runLoopActivity"] != "notRecorded"


def tracking(r):
    return run_loop_measured(r) and r["runLoopActivity"] == "tracking"


def ran_nothing(r):
    """The contaminated shape: no render pass and no time in one. A tracking record that DID spend render
    time is a real freeze that overlapped a menu and stays in every population (L11)."""
    return r.get("passes") == 0 and r.get("passSeconds") in (0, 0.0)


def menu_idle(r):
    """Taken while a menu tracked and nothing ran: menu-open time rather than a freeze. ONLY `tracking`
    counts, because an unnamed mode was measured passing through ordinary window work (#4114)."""
    return tracking(r) and ran_nothing(r)


def freeze_verdict(r):
    """One of NOT_A_FREEZE, FREEZE, UNMEASURED.

    Either field saying not-a-freeze is enough on its own, whatever the other says or lacks. Otherwise a
    record is a FREEZE only when BOTH fields were read, because a record missing either could be the
    thing the missing one exists to catch. `otherMode` is a FREEZE by this rule, since nothing measured
    says otherwise; the readers name those separately as unknown in kind."""
    if slept(r) or menu_idle(r):
        return NOT_A_FREEZE
    if sleep_measured(r) and run_loop_measured(r):
        return FREEZE
    return UNMEASURED


# #4154: whether the MAIN THREAD was running while a stall lasted.
#
# A pass is timed on the wall clock, so `passSeconds` reads the same whether the code did the work or waited
# for a core. Reproduced 2026-09-25 against a clone of the live store: under CPU contention a pass took 5.45s
# with the main thread's own CPU clock at 23% of it and the kernel reporting it runnable. These readings are
# what let a record say so on its own.
#
# FIVE ANSWERS. The three states, one for a thread that was not running but carries no state sample to split
# it, and unmeasured. Never folded: an absent reading is not a computing thread (L98, L11).
COMPUTING = "computing"
STARVED = "starved"
BLOCKED = "blocked"
NOT_RUNNING_UNSPLIT = "not running unsplit"
MAIN_THREAD_STATES = (COMPUTING, STARVED, BLOCKED, NOT_RUNNING_UNSPLIT, UNMEASURED)

# The share of a stall's awake time the main thread must have spent on the CPU to count as COMPUTING. Chosen
# between the two readings #4154 measured on the same pass: 0.92 on a quiet Mac and 0.23 to 0.41 under
# contention, so a line at one half is far from both rather than tuned to either (L172).
RUNNING_SHARE = 0.5


def _number(r, key):
    """A finite number, or None. A bool is an int to Python and NaN compares false against every line, so
    both would land a record silently on one side of a verdict (L50)."""
    v = r.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v if math.isfinite(v) else None


def _count(r, key):
    """A whole count, or None, on `_number`'s rule: `true` is not one sample."""
    v = r.get(key)
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def main_thread_measured(r):
    return _number(r, "mainThreadCPUSeconds") is not None


def main_thread_share(r):
    """CPU seconds over the stall's AWAKE seconds, or None. A sleep is taken out of the denominator, because a
    thread cannot run while the Mac does not, and #4153 already names those."""
    cpu = _number(r, "mainThreadCPUSeconds")
    seconds = _number(r, "seconds")
    if cpu is None or seconds is None:
        return None
    asleep = _number(r, "asleepSeconds") or 0
    awake = seconds - asleep
    return cpu / awake if awake > 0 else None


def main_thread_verdict(r):
    """One of MAIN_THREAD_STATES."""
    share = main_thread_share(r)
    if share is None:
        return UNMEASURED
    if share >= RUNNING_SHARE:
        return COMPUTING
    runnable = _count(r, "mainThreadRunnableSamples")
    waiting = _count(r, "mainThreadWaitingSamples")
    if runnable is None or waiting is None or runnable + waiting == 0:
        return NOT_RUNNING_UNSPLIT
    return STARVED if runnable >= waiting else BLOCKED
