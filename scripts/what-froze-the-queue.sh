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
# (L316, #3487). The decisive reading needs no such number. A long stall that spanned many passes is the
# render pass being run over and over; a long stall that spanned NONE is something else, and which of the
# two it is can be read straight off the count.
#
# WHAT IT WILL SAY TODAY, stated so nobody reads it as a finding: every record written before #3760 is
# installed carries no pass count at all, so on a log that has not turned over it answers UNMEASURED. That
# is the honest answer and not a fault.

LOG="${HOME}/Library/Application Support/Overture/freeze-log.ndjson"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--log <freeze-log.ndjson>]"
      echo "  0  every stall carrying a count is accounted for by the passes it spans"
      echo "  1  a stall spanned NO render pass, so the freeze is something else"
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

python3 - "${LOG}" "${ARCHIVE}" <<'PY'
import json, os, sys

path, archive_path = sys.argv[1], sys.argv[2]
rows, unreadable = [], 0
sources = []


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


# The ARCHIVE first, so the combined list is roughly chronological: a compaction only ever moves records
# OLDER than everything the live file kept.
if os.path.exists(archive_path):
    sources.append(f"{os.path.basename(archive_path)} ({plural(load(archive_path), 'record')})")
sources.append(f"{os.path.basename(path)} ({plural(load(path), 'record')})")

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
print()
print("  when                  seconds  passes  surface        load")
for r in counted[:25]:
    when = str(r.get("at", ""))[:19].replace("T", " ")
    print("  {:<20}  {:>7.2f}  {:>6}  {:<13}  {}".format(
        when, r.get("seconds", 0), r["passes"], str(r.get("surface", "?")), str(r.get("load", "?"))))
if len(counted) > 25:
    print(f"  ... and {len(counted) - 25} more, shown longest first.")

# The finding. A stall is "something else" when the surface did not rebuild during it at all: the render
# pass cannot be what the main thread was doing, whatever the pass costs.
FLOOR = 1.0
silent = [r for r in counted if r["passes"] == 0 and r.get("seconds", 0) >= FLOOR]

print()
if uncounted:
    print(f"  {len(uncounted)} carry no pass count and are not judged either way.")
if unreadable:
    print(f"  {unreadable} line(s) could not be read.")

if silent:
    print()
    print(f"  {len(silent)} stall(s) over {FLOOR:.0f}s spanned NO render pass, so the surface")
    print("  did not rebuild during them. Whatever the main thread was doing, it was not the")
    print("  render pass, and the next diagnosis belongs somewhere else.")
    for r in silent[:10]:
        when = str(r.get("at", ""))[:19].replace("T", " ")
        print(f"    {when}  {r.get('seconds', 0):.2f}s on {r.get('surface', '?')}")
    sys.exit(1)

longest = counted[0]
print(f"  Longest counted stall: {longest.get('seconds', 0):.2f}s spanning {longest['passes']} pass(es).")
sys.exit(0)
PY
