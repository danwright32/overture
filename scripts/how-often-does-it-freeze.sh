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

python3 - "${LOG}" "${ARCHIVE}" <<'PY'
import json, os, statistics, sys

path, archive_path = sys.argv[1], sys.argv[2]
rows, unreadable, sources = [], 0, []


def plural(n, word):
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def load(p):
    global unreadable
    added = 0
    with open(p) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
                added += 1
            except ValueError:
                unreadable += 1
    return added


if os.path.exists(archive_path):
    sources.append(f"{os.path.basename(archive_path)} ({plural(load(archive_path), 'record')})")
sources.append(f"{os.path.basename(path)} ({plural(load(path), 'record')})")

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
print("  session   floor   watched   stalls   per hour   stalled   share")
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
    print(f"  {name[:8]}   {interval * 1000:3.0f}ms   {watched / 3600:6.2f}h   {len(group):6}   "
          f"{rate:8.1f}   {stalled:6.1f}s   {100 * stalled / watched:5.2f}%")
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

secs = [r.get("seconds", 0) for r in baseline]
print("  THE BAR is about baseline load at the 100 ms floor, so that is the only comparable set:")
print(f"    n={len(secs)}   p50 {statistics.median(secs):.3f}s   p90 {quantile(secs, 0.90):.3f}s   "
      f"p95 {quantile(secs, 0.95):.3f}s   p99 {quantile(secs, 0.99):.3f}s   max {max(secs):.3f}s")
print(f"    {len(modern)} stall(s) over {modern_watched / 3600:.2f}h watched, "
      f"{len(modern) / (modern_watched / 3600):.1f} per hour")
print()
print("  Read as a RATE, never as a proportion over the bar: the watchdog's storage floor IS the")
print("  bar, so 100 percent of these are over it by construction and that says nothing (L178).")
print("  Watched time is a LOWER bound, because a ping is not posted while one is outstanding, so")
print("  fewer are issued during a long freeze. The per hour figure is therefore an upper bound.")

# A session sitting exactly on the cap stopped writing rather than went quiet (#3812), and a reading
# that did not say so would be computed over the first N stalls of that session while looking like a
# reading of all of them.
CAP = 200
censored = [n for n, g in sessions.items() if len(g) == CAP]
if censored:
    print()
    print(f"  {plural(len(censored), 'session')} hold exactly {CAP} records, which is the write cap, not")
    print("  a coincidence: #3812 stops a session writing once its kept set is full. Every figure")
    print(f"  above counts only the first {CAP} stalls of those, so they are UNDERSTATED.")
    for name in censored:
        print(f"    {name[:8]}  last record {max(r.get('at', '') for r in sessions[name])[:19]}")

if unreadable:
    print()
    print(f"  {unreadable} line(s) could not be read.")
PY
