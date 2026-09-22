#!/usr/bin/env bash
set -uo pipefail

# #4147: what a show's title WAS before the scout replaced it, and which arm of the upsert did it.
#
# WHY THIS EXISTS. #4068 asked which mechanism had renamed four dismissed rows onto unrelated shows and
# could not be answered at all: the store holds only the NEW title, `scoutGroupName` holds the new title
# too, and every other instrument that might have said (the launch backups, the frozen pre-move archive,
# `NaturalKeyRemap`'s 7 day ledger) had already aged out. The app now writes `title-renames.json` beside
# its other handoff files as each rename lands. This is that file's reader, shipped in the same change
# for the reason `what-the-log-lost.sh` was: a record nothing reads is a record nobody will read (L46).
#
# It REPORTS. It never writes, prunes or repairs anything; `TitleRenameLedger` owns retention.
#
# THREE OUTCOMES, kept apart, because an empty answer here means three different things (L11, L98).
#
# EXIT CODES. 0 the ledger was read (with or without matching entries). 3 there is no ledger on this
# machine, which is the ordinary state on a fresh install, in CI and in an agent worktree. 2 UNMEASURED:
# a ledger is there and could not be read.

LEDGER="${HOME}/Library/Application Support/Overture/title-renames.json"
MATCH=""
LIMIT=40

while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="${2:-}"; shift 2 ;;
    --match) MATCH="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-40}"; shift 2 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--ledger <title-renames.json>] [--match <text>] [--limit <n>]"
      echo "  --match  only entries whose key, old title or new title contains this text"
      echo "  0  the ledger was read"
      echo "  2  a ledger is there and could not be read (UNMEASURED)"
      echo "  3  there is no ledger on this machine"
      exit 0 ;;
    *) echo "$(basename "$0"): unknown argument '$1'" >&2; exit 64 ;;
  esac
done

if [ ! -f "${LEDGER}" ]; then
  echo "NO LEDGER at ${LEDGER}."
  echo "  Nothing is known either way: the app writes this file only when a scout run replaces a stored"
  echo "  title, so an absent file is also what a machine that has never renamed one looks like."
  exit 3
fi

# The whole file through one python read, because the entries are a JSON array and a line oriented
# tool would have to reconstruct it (L434: a pattern that reads differently under two seds is not a
# parser). Its exit code is this script's verdict, so an unreadable ledger can never read as an empty
# one (L215).
python3 - "${LEDGER}" "${MATCH}" "${LIMIT}" <<'PY'
import json, sys

path, match, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(path) as f:
        data = json.load(f)
    entries = data["entries"]
except Exception as exc:                      # noqa: BLE001 - the reason is what is being reported
    print(f"UNMEASURED: {path} is there and could not be read: {exc}")
    sys.exit(2)

if match:
    entries = [e for e in entries
               if match.lower() in (e.get("key", "") + e.get("from", "") + e.get("to", "")).lower()]

if not entries:
    scope = f" matching {match!r}" if match else ""
    print(f"NO RENAMES{scope} in {path}.")
    print("  The ledger is there and holds none in range, which is a measurement of zero rather than")
    print("  an absence of one.")
    sys.exit(0)

shown = entries[-limit:]
print(f"{len(entries)} rename(s) recorded, newest last, showing {len(shown)}:")
for e in shown:
    print(f"  {e.get('at', '?')}  [{e.get('arm', '?')}]")
    print(f"      was: {e.get('from', '?')}")
    print(f"      now: {e.get('to', '?')}")
    print(f"      key: {e.get('key', '?')}")
sys.exit(0)
PY
exit $?
