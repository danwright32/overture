#!/usr/bin/env bash
set -uo pipefail

# #4338 (A10): how often a scout landing's ENTRY FLUSH had edits to save, read from the store over time.
#
# WHY IT EXISTS. Every landing saves whatever is pending in the main context before it applies anything
# (`ScoutService.flushBeforeLanding`, once in its read phase and once holding the store), so a failure path
# revert, which restores committed values, can never put back an edit of Dan's. After #4329 the ordinary case
# is that nothing is pending, which makes the flush a check that costs nothing. When something IS pending it
# is a save on the main thread inside a landing, and milestone 80 is about exactly that cost. So each landing
# records how many of its flushes saved something (`LandingRun.entryFlushSaves`, 0 to 2), on the record that
# is never pruned, and this is that number's reader (L46): the share of landings that had to save first, over
# a window, which is the rate #4332's plan said should be visible.
#
# A landing record that predates the count (a store from before #4338, or a row A7 wrote before landings
# recorded their start) has no flush count and is not counted at all, never as zero (L90).
#
# The store is never opened directly, even read only: SQLite rewrites the -shm beside it when it is opened
# (L474), so the .store, -wal and -shm are copied to scratch and the copy is read.
#
# Usage: scripts/landing-flush-rate.sh [--store PATH] [--days N]
#   --store  the store to read; the live Release store by default
#   --days   the window, landings STARTED in the last N days; 14 by default
#
# Exit codes: 0 measured (a window holding no landing says so, with no rate). 2 UNMEASURED, the store is
# there and could not be read, or it records no flush count. 3 there is no store at that path, the ordinary
# state in CI and in a worktree. 64 an argument it does not know.

FLUSH_RATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/scratch.sh
. "${FLUSH_RATE_SCRIPT_DIR}/lib/scratch.sh"

# The column SwiftData stores `LandingRun.entryFlushSaves` in. `LandingFlushRateColumnTests` holds this name to
# the column a real store of this build has, so a rename on either side goes red.
FLUSH_COLUMN="ZENTRYFLUSHSAVES"
STORE="${HOME}/Library/Application Support/Overture/Overture.store"
DAYS=14

while [[ $# -gt 0 ]]; do
  case "$1" in
    --store) STORE="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -eq 0 ]]; then
  echo "--days needs a whole number of days above zero, not '${DAYS}'" >&2
  exit 64
fi

if [[ ! -f "${STORE}" ]]; then
  echo "NO STORE at ${STORE}"
  echo "Nothing was measured. This is the ordinary state in CI, in a fresh clone and in a worktree."
  exit 3
fi

COPY_DIR="$(overture_scratch_dir landing-flush-rate)" || {
  echo "UNMEASURED: no scratch directory could be made, so the store was never copied."
  exit 2
}
trap 'rm -rf "${COPY_DIR}"' EXIT
for ext in "" "-wal" "-shm"; do
  if [[ -f "${STORE}${ext}" ]]; then cp "${STORE}${ext}" "${COPY_DIR}/copy.store${ext}"; fi
done
COPY="${COPY_DIR}/copy.store"

COLUMNS="$(sqlite3 -readonly "${COPY}" "SELECT name FROM pragma_table_info('ZLANDINGRUN');" 2>&1)"
status=$?
if [[ ${status} -ne 0 ]]; then
  echo "UNMEASURED: the store could not be read (${COLUMNS})."
  exit 2
fi
if ! grep -qx "${FLUSH_COLUMN}" <<< "${COLUMNS}"; then
  echo "UNMEASURED: this store records no entry flush count (no ${FLUSH_COLUMN} on its landing records),"
  echo "so it predates #4338 and there is no rate to read."
  exit 2
fi

# Core Data stores a date as seconds since 2001-01-01, which is 978307200 seconds after the Unix epoch.
CUTOFF=$(( $(date +%s) - DAYS * 86400 - 978307200 ))
ROW="$(sqlite3 -readonly -separator ' ' "${COPY}" \
  "SELECT count(*), ifnull(sum(${FLUSH_COLUMN} > 0), 0), ifnull(sum(${FLUSH_COLUMN} = 1), 0),
          ifnull(sum(${FLUSH_COLUMN} >= 2), 0), ifnull(sum(${FLUSH_COLUMN}), 0)
   FROM ZLANDINGRUN WHERE ZSTARTEDAT IS NOT NULL AND ZSTARTEDAT >= ${CUTOFF};" 2>&1)"
status=$?
if [[ ${status} -ne 0 ]]; then
  echo "UNMEASURED: the landing records could not be read (${ROW})."
  exit 2
fi
read -r LANDINGS FLUSHED ONCE TWICE SAVES <<< "${ROW}"

echo "landing-flush-rate: ${STORE}"
if [[ "${LANDINGS}" -eq 0 ]]; then
  echo "No landing started in the last ${DAYS} days, so there is no rate to give."
  exit 0
fi
echo "landings started in the last ${DAYS} days: ${LANDINGS}"
echo "saved pending edits first: ${FLUSHED} of ${LANDINGS} ($(( FLUSHED * 100 / LANDINGS ))%), once ${ONCE}, twice ${TWICE}, ${SAVES} entry flush saves in all"
