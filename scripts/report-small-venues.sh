#!/usr/bin/env bash
# #1902: the rooms Dan has shot 1 to 4 times, with every calendar entry and Downbeat booking behind each
# one's band, so a person can see a stray entry (a training session, a reception) before it tells a
# stranger "a few shows here". Nothing automatic can: a keyword filter drops real shoots, and a room this
# small has no band saturation to hide a stray one.
#
# Opt in, run by hand now and then (after re-importing the Shoots calendar is the natural moment). It runs
# ONE opt-in Swift test, `SmallVenueReportLive`, which reads the live shoot history and Downbeat export read
# only and writes the report to a scratch file; this prints it.
#
# PRIVATE. Calendar titles can carry a client's payment notes (#1904). The report is printed here on this
# Mac and deleted afterwards. Never paste it, or any line of it, into GitHub.
#
# Exit codes: 0 the report printed (an empty one is a real answer: no room has 1 to 4 shoots). 2 nothing
# was measured: the Swift run failed, or it wrote no report, and that must never read as "no small rooms".
#
# Usage: scripts/report-small-venues.sh
# Seams: OVERTURE_SMALL_VENUES_RUNNER replaces the test runner, and OVERTURE_SMALL_VENUES_SHOOTS and
# OVERTURE_SMALL_VENUES_EXPORT the two files, for the fixture.
set -uo pipefail
SMALL_VENUES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SMALL_VENUES_SCRIPT_DIR}/.." || exit 2

# shellcheck source=./lib/scratch.sh
. "${SMALL_VENUES_SCRIPT_DIR}/lib/scratch.sh"

WORK="$(overture_scratch_dir small-venues)" || exit 2
trap 'rm -rf "${WORK}"' EXIT
REPORT="${WORK}/report.txt"
LOG="${WORK}/run.log"

RUNNER="${OVERTURE_SMALL_VENUES_RUNNER:-./mac/scripts/run-tests-locked.sh}"
# The Release handoff folder, where the importer writes the shoot history and Downbeat writes its export.
# Named here, by the person asking for the report, so the test itself can never reach them on its own.
LIVE_DIR="${HOME}/Library/Application Support/Overture"
SHOOTS="${OVERTURE_SMALL_VENUES_SHOOTS:-${LIVE_DIR}/overture-shoot-history.json}"
EXPORT="${OVERTURE_SMALL_VENUES_EXPORT:-${LIVE_DIR}/downbeat-export.json}"

if [ ! -r "${SHOOTS}" ]; then
  echo "UNMEASURED: no readable shoot history at ${SHOOTS}. Run the shoot-history import first." >&2
  exit 2
fi

echo "report-small-venues: reading the live shoot history and Downbeat export (read only), this takes minutes."
TEST_RUNNER_OVERTURE_SMALL_VENUES_OUT="${REPORT}" \
TEST_RUNNER_OVERTURE_SMALL_VENUES_SHOOTS="${SHOOTS}" \
TEST_RUNNER_OVERTURE_SMALL_VENUES_EXPORT="${EXPORT}" \
  "${RUNNER}" -only-testing:OvertureTests/SmallVenueReportLive > "${LOG}" 2>&1
status=$?

if [ "${status}" -ne 0 ]; then
  echo "UNMEASURED: the report run failed (exit ${status}), so nothing below is a finding." >&2
  tail -25 "${LOG}" >&2
  exit 2
fi

if [ ! -s "${REPORT}" ]; then
  echo "UNMEASURED: the run passed but wrote no report, so the live test did not run or read nothing." >&2
  echo "An empty result here is never the same as no small rooms." >&2
  tail -25 "${LOG}" >&2
  exit 2
fi

echo
echo "PRIVATE: calendar titles can carry client notes. Keep this on this Mac; never paste it into GitHub."
echo
cat "${REPORT}"
exit 0
