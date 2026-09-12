#!/usr/bin/env bash
set -uo pipefail

# #3789: what one of this app's rotating logs still holds, and what it no longer does.
#
# WHY THIS EXISTS. `LogRotation.cap` keeps exactly ONE previous generation: it copies the live file to
# a `.1` beside it and empties the live file, so the `.1` written by the rotation before that is
# deleted. Until #3789 nothing anywhere read a `.1`, which made the preserved copy a write-only file
# (L46), and nothing said a rotation had happened at all, so a log that had lost half its history and
# a log that had never rotated read identically (L98, L11).
#
# The app now writes a note into the live file as the first thing after a rotation. This is that note's
# reader, and the `.1` file's reader, shipped in the same change for the same reason #3763's archive
# shipped alongside `what-froze-the-queue.sh` rather than after it.
#
# DEFAULTS TO THE STORE BACKUP LOG, because that is the one whose loss costs something: it is the
# record of whether Dan's live store was copied on each launch, it already tells a clean success apart
# from a partial or a refused one, and both of the incidents it covers (AGENTS.md, "Restoring Overture
# from a backup") were read days afterwards. Point it at any of the others with --log:
#
#   ~/Library/Logs/Overture/overture-agent.out.log        the agent's stdout
#   ~/Library/Logs/Overture/overture-agent.err.log        the agent's stderr
#   ~/Library/Logs/Overture/overture-agent.problems.log   the problem ledger
#   ~/Library/Logs/Overture/gmail-connect-debug.log       the Gmail connect trace
#   ~/Library/Logs/Overture/feed-movement.log             the feed movement log
#   <Application Support>/Overture/queue-derivations.log  the card divergence log
#   <the run archives>/archive.log                        the prep run log
#
# It REPORTS. It does not rotate, delete or repair anything.

LOG="${HOME}/Library/Application Support/Overture/overture-store-backups/backup.log"
PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:-}"; shift 2 ;;
    --print) PRINT=1; shift ;;
    -h|--help)
      echo "usage: $(basename "$0") [--log <path to a log>] [--print]"
      echo "  --log    which log to read (default: the store backup log)"
      echo "  --print  also print the whole retained history, oldest first"
      echo "  0  nothing lost: it has never rotated, or every rotation kept what it moved"
      echo "  1  content is GONE, or a rotation was refused and the log is over its cap"
      echo "  2  UNMEASURED: there is no log at that path"
      exit 0 ;;
    *) echo "what-the-log-lost: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

BACKUP="${LOG}.1"

describe() {
  local path="$1"
  if [ ! -f "${path}" ]; then
    echo "    ${path}  (not there)"
    return
  fi
  local bytes modified
  bytes="$(wc -c < "${path}" | tr -d ' ')"
  modified="$(date -r "${path}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
  echo "    ${path}  ${bytes} bytes, last written ${modified}"
}

if [ ! -f "${LOG}" ] && [ ! -f "${BACKUP}" ]; then
  echo "what-the-log-lost: UNMEASURED. There is no log at ${LOG}."
  echo "  A log that has never been written and a log that was deleted are different facts, and this"
  echo "  reads neither. It reports only on a log that is there."
  exit 2
fi

echo "what-the-log-lost: $(basename "${LOG}")"
echo "  read from, oldest first:"
describe "${BACKUP}"
describe "${LOG}"

# Both files. The `.1` carries the notes from the rotations BEFORE the one that made it, so a reader
# that opened only the live file would report on the most recent rotation while looking exactly like a
# reader of the whole history (L46, L98). `grep -a` because a log holding one stray byte the tool reads
# as binary otherwise answers "Binary file matches" and every line in it goes unread (L329).
RETAINED="$( { [ -f "${BACKUP}" ] && cat "${BACKUP}"; [ -f "${LOG}" ] && cat "${LOG}"; } 2>/dev/null )"
NOTES="$(printf '%s\n' "${RETAINED}" | grep -a 'log rotation:' || true)"

if [ -z "${NOTES}" ]; then
  echo "  No rotation is recorded in what is still here."
  if [ -f "${BACKUP}" ]; then
    echo "  There IS a $(basename "${BACKUP}") beside it, so a rotation happened before the app began"
    echo "  saying so. What that one cost cannot be recovered: it is the state #3789 was filed about."
    exit 1
  fi
  echo "  Nothing has been lost."
  exit 0
fi

echo "  rotations recorded:"
printf '%s\n' "${NOTES}" | sed 's/^/    /'

LOST=0
if grep -a -q 'That older content is gone' <<< "${NOTES}"; then
  echo "  CONTENT IS GONE. A rotation deleted the generation before it, and those bytes are held"
  echo "  nowhere: only two generations ever exist, this file and $(basename "${BACKUP}")."
  LOST=1
fi
if grep -a -q 'could not be' <<< "${NOTES}"; then
  echo "  A rotation was REFUSED, so this log is over its cap and still growing. Nothing was destroyed;"
  echo "  what needs looking at is why the copy beside it could not be written."
  LOST=1
fi
if [ "${LOST}" -eq 0 ]; then
  echo "  Every rotation moved its content into the file beside it and deleted nothing. Nothing lost."
fi

if [ "${PRINT}" -eq 1 ]; then
  echo
  echo "  the whole retained history, oldest first:"
  printf '%s\n' "${RETAINED}" | sed 's/^/    /'
fi

exit "${LOST}"
