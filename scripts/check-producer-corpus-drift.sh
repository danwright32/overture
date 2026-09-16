#!/usr/bin/env bash
# Whether the producer rule's calibration corpus has drifted from the live VenueTix feed (#2680).
#
# WHY. #2554 pinned the producer rule's boundary against the real feed, committed as
# `fixtures/venuetix-supertitles/2026-08-13.json` (248 events, 148 distinct supertitles), and
# `SuperTitleCalibrationTests` asserts the exact set of phrases the rule calls a producer. That guard
# exists because this rule has drifted before: its first version matched 34 of 141 and was wrong on
# several, and the numbers then lived only in a comment where nothing could go red.
#
# The gap is that NOTHING RE-MEASURES. The fixture is a snapshot of one day, the live feed keeps changing,
# and the test will stay green against August's world indefinitely. A rule calibrated on a snapshot and
# then trusted as a contract is L48 and L56 exactly, and the guard's own value decays with nobody noticing.
#
# WHAT IT DOES NOT DO, deliberately. It never rewrites the fixture. A new corpus is always a change
# somebody read, on `docs/copy-inventory.md`'s rule since #1994: a check that regenerates its own subject
# defends whatever it happened to produce. And it REPORTS rather than blocks, because the feed turns over
# every week and a gate on ordinary churn has its threshold raised until it catches nothing (L93, L36).
#
# THREE OUTCOMES, and the third is the one that matters (L98, L11):
#
#   0  IN STEP. The committed corpus still describes the live feed, and the rule judges the live feed
#      exactly as the fixture records.
#   1  DRIFTED. Supertitles have arrived or vanished, or the rule would now call something a producer
#      that the committed calibration does not carry. Advisory: it names them and does not fail.
#   2  UNMEASURED. The feed could not be fetched, came back empty or unparseable, the fixture is missing,
#      or the rule could not be compiled to judge with. A failed fetch and a feed that genuinely changed
#      nothing leave the same empty difference, and the emptiest possible failure must not read as the
#      cleanest possible pass.
#
# OPT IN, and not in `scripts/test-all.sh`: it reaches the network, which is also why the fetch needs the
# venue's own Origin header. Its JUDGING half rides along on every push through
# `scripts/check-producer-corpus-drift.test.sh`, which drives every outcome through the feed seam without
# a single request.
set -uo pipefail
# #3481/L372: captured BEFORE the cd, because `$0` and `BASH_SOURCE[0]` are the path this was INVOKED by.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/scratch.sh
. "${SCRIPT_DIR}/lib/scratch.sh"

FIXTURE="${OVERTURE_SUPERTITLE_FIXTURE:-${SCRIPT_DIR}/../fixtures/venuetix-supertitles/2026-08-13.json}"
RULE_SOURCE="${OVERTURE_PRODUCER_RULE_SOURCE:-${SCRIPT_DIR}/../mac/Overture/Domain/ProducerShapedName.swift}"
VENUE_HOST="${OVERTURE_VENUETIX_HOST:-thegreenroom42.venuetix.com}"
FEED_URL="https://us-east1-venuetixprod.cloudfunctions.net/clientApi/client/nine-events"
# The seam. A local file standing in for the live feed, so every outcome below can be driven without a
# request. Named rather than implied, because a test that reaches the real feed measures the venue's
# week rather than this script (L2, L52).
FEED_FILE="${OVERTURE_VENUETIX_FEED_FILE:-}"

WORK="$(overture_scratch_dir producer-corpus-drift)" || exit 2
trap 'rm -rf "${WORK}"' EXIT

unmeasured() {
  echo "check-producer-corpus-drift: UNMEASURED. $1"
  echo "  Nothing was compared, which is a failed measurement and not a clean bill of health: a feed"
  echo "  that could not be read and a feed that changed nothing leave the same empty difference."
  exit 2
}

# ---- the live feed ------------------------------------------------------------------------------
if [ -n "${FEED_FILE}" ]; then
  [ -f "${FEED_FILE}" ] || unmeasured "the feed file ${FEED_FILE} does not exist."
  cp "${FEED_FILE}" "${WORK}/feed.json" || unmeasured "could not read ${FEED_FILE}."
  SOURCE_DESCRIPTION="${FEED_FILE}"
else
  # The feed answers "Unauthorized access" without the venue's own subdomain as Origin and Referer; the
  # headers are the same ones `VenueTixCalendar.feedRequest` sends.
  curl --silent --show-error --fail --max-time 30 \
    --header "Origin: https://${VENUE_HOST}" \
    --header "Referer: https://${VENUE_HOST}/" \
    --header "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36" \
    --output "${WORK}/feed.json" "${FEED_URL}" \
    || unmeasured "the fetch of ${VENUE_HOST}'s feed failed."
  SOURCE_DESCRIPTION="https://${VENUE_HOST}/ via the VenueTix client feed"
fi

# Distinct supertitles, and the event count, out of the feed. Python rather than jq because jq is not a
# dependency of this repository and a missing tool would report as drift.
python3 - "${WORK}/feed.json" "${WORK}/live.txt" "${WORK}/live-count.txt" <<'PY' || unmeasured "the feed did not parse as the array of events this reader expects, which is what a feed shape change looks like."
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
items = json.loads(raw)
if not isinstance(items, list) or not items:
    raise SystemExit(1)
titles = sorted({(i.get("superTitle") or "").strip() for i in items if (i.get("superTitle") or "").strip()})
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(titles) + ("\n" if titles else ""))
open(sys.argv[3], "w", encoding="utf-8").write(str(len(items)))
PY

LIVE_EVENTS="$(cat "${WORK}/live-count.txt")"
[ -s "${WORK}/live.txt" ] || unmeasured "the feed parsed and carried no supertitle at all, so there was nothing to compare."

# ---- the committed corpus -----------------------------------------------------------------------
[ -f "${FIXTURE}" ] || unmeasured "the committed corpus ${FIXTURE} is not there."
python3 - "${FIXTURE}" "${WORK}/fixture.txt" <<'PY' || unmeasured "the committed corpus did not parse, or carries no superTitles array."
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
titles = sorted({t.strip() for t in obj.get("superTitles", []) if t.strip()})
if not titles:
    raise SystemExit(1)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(titles) + "\n")
PY

# ---- what the RULE says about each side ---------------------------------------------------------
# Compiled from the app's own source rather than reimplemented here, because a second definition of the
# producer rule would drift from the one that actually runs and would flatter whoever wrote it (L107).
[ -f "${RULE_SOURCE}" ] || unmeasured "the producer rule source ${RULE_SOURCE} is not there."
cat > "${WORK}/main.swift" <<'SWIFT'
import Foundation
let path = CommandLine.arguments[1]
let text = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
    if let name = ProducerShapedName.from(String(line)) { print("\(line)\t\(name)") }
}
SWIFT
swiftc -O -o "${WORK}/judge" "${RULE_SOURCE}" "${WORK}/main.swift" >"${WORK}/build.log" 2>&1 \
  || unmeasured "the producer rule would not compile on its own, so nothing could be judged. See ${WORK}/build.log."

"${WORK}/judge" "${WORK}/live.txt" > "${WORK}/live-accepted.tsv" || unmeasured "judging the live feed failed."
"${WORK}/judge" "${WORK}/fixture.txt" > "${WORK}/fixture-accepted.tsv" || unmeasured "judging the committed corpus failed."

# EVERY sort and every comm below runs under LC_ALL=C, and they have to agree: `comm` does not verify
# that its inputs are sorted, it answers nonsense on a pair sorted under different collations rather
# than failing. C order is byte order, which is what Python's own `sorted` produced above, so the two
# halves of each comparison were ordered by one rule.
cut -f1 "${WORK}/live-accepted.tsv" | LC_ALL=C sort > "${WORK}/live-accepted.txt"
cut -f1 "${WORK}/fixture-accepted.tsv" | LC_ALL=C sort > "${WORK}/fixture-accepted.txt"

ARRIVED="$(LC_ALL=C comm -13 "${WORK}/fixture.txt" "${WORK}/live.txt")"
VANISHED="$(LC_ALL=C comm -23 "${WORK}/fixture.txt" "${WORK}/live.txt")"
NEWLY_ACCEPTED="$(LC_ALL=C comm -13 "${WORK}/fixture-accepted.txt" "${WORK}/live-accepted.txt")"
NO_LONGER_ACCEPTED="$(LC_ALL=C comm -23 "${WORK}/fixture-accepted.txt" "${WORK}/live-accepted.txt")"

FIXTURE_COUNT="$(wc -l < "${WORK}/fixture.txt" | tr -d ' ')"
LIVE_COUNT="$(wc -l < "${WORK}/live.txt" | tr -d ' ')"
FIXTURE_ACCEPTED="$(wc -l < "${WORK}/fixture-accepted.txt" | tr -d ' ')"
LIVE_ACCEPTED="$(wc -l < "${WORK}/live-accepted.txt" | tr -d ' ')"

echo "check-producer-corpus-drift: ${SOURCE_DESCRIPTION}"
echo "  committed corpus: ${FIXTURE_COUNT} distinct supertitles, ${FIXTURE_ACCEPTED} the rule calls a producer"
echo "  live feed:        ${LIVE_COUNT} distinct supertitles over ${LIVE_EVENTS} events, ${LIVE_ACCEPTED} the rule calls a producer"

if [ -z "${ARRIVED}" ] && [ -z "${VANISHED}" ]; then
  echo "  IN STEP. The committed corpus still describes the live feed exactly."
  exit 0
fi

echo
echo "  DRIFTED."
count_lines() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d ' '; }
echo "    arrived since the corpus was taken: $(count_lines "${ARRIVED}")"
echo "    gone since the corpus was taken:    $(count_lines "${VANISHED}")"

if [ -n "${NEWLY_ACCEPTED}" ]; then
  echo
  echo "  THE BOUNDARY MOVED. The rule calls each of these a producer, and the committed calibration"
  echo "  does not carry it. Read every one before recording a new corpus: silent over-matching is the"
  echo "  failure this area actually has, and it is what took 'A Jennings Vocal Studio NYC Cabaret'."
  printf '%s\n' "${NEWLY_ACCEPTED}" | sed 's/^/    + /'
fi
if [ -n "${NO_LONGER_ACCEPTED}" ]; then
  echo
  echo "  These the calibration carries and the live feed no longer bills at all:"
  printf '%s\n' "${NO_LONGER_ACCEPTED}" | sed 's/^/    - /'
fi

echo
echo "  Advisory: this does NOT fail, and it has NOT written anything. To record a new corpus, read the"
echo "  arrivals above and update fixtures/venuetix-supertitles/ and SuperTitleCalibrationTests together,"
echo "  as a change somebody has looked at."
exit 1
