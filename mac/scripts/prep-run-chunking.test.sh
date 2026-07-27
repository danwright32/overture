#!/usr/bin/env bash
set -uo pipefail

# #1597: prep-run.sh actually RUN, end to end, under the shell the app launches it with, with a stub in
# place of claude.
#
# This exists because parsing is not running. On 2026-07-27 a `> >(tee_run_events ...)` was added to this
# same script; `bash -n` accepted it, every unit test of the helper passed, the Swift suite passed, and
# the first real reachability check Dan clicked died in seconds with a syntax error, because nothing had
# ever executed the INVOCATION. check-runner-posix.sh now catches that particular shape, but it only
# proves a script parses. Chunking adds a fifo per chunk, a pid list, a prompt rewritten per chunk, a
# merge on a background heartbeat and a summed cost across streams: none of that is provable by parsing,
# and all of it is silent when wrong.
#
# So: build a real support directory, hand the script a real queue, stub claude, and run it with /bin/sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

command -v node >/dev/null 2>&1 || { echo "skip - node unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

SUPPORT="${TMP}/Application Support/Overture"
# A space in the path ON PURPOSE: Dan's real support directory is "Application Support",
# and passing the per-chunk event files as an unquoted string cut every path in half there,
# so a run that reported its cost perfectly was recorded as "not recorded". Under a
# space-free temp dir that bug is completely invisible.
mkdir -p "${SUPPORT}" "${TMP}/home/.local/bin"

# The stub claude. It reads its own -p prompt to learn which queue slice it was given and where to write,
# exactly as the real one would, then emits a stream-json result envelope carrying a cost. Each stub
# records that it ran, so the test can count how many actually launched.
cat > "${TMP}/home/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
flat="$(printf '%s' "$prompt" | tr '\n' ' ')"
# Anchored on the words AROUND the path, not on "no spaces", because the real support directory is
# "Application Support" and a path here legitimately contains one.
queue="$(printf '%s' "$flat" | sed -n 's|.*work-list at \(.*\.json\),\{0,1\} and for every.*|\1|p' | head -1)"
results="$(printf '%s' "$flat" | sed -n 's|.*rewrite \(.*\.json\) with the complete.*|\1|p' | head -1)"
printf '%s\n' "$queue" > "${STUB_LOG_DIR}/queue.$$"
printf '%s\n' "$flat" > "${STUB_LOG_DIR}/prompt.$$"
node -e '
  const fs = require("fs");
  const [q, out] = process.argv.slice(1);
  const queue = JSON.parse(fs.readFileSync(q, "utf8"));
  const results = [];
  for (const item of queue.items) {
    // Every key the item answers for gets its own entry, which is the whole point of alsoAnswersFor.
    for (const key of [item.naturalKey, ...(item.alsoAnswersFor || [])]) {
      results.push({ naturalKey: key, contacts: [{ email: "found@example.org", provenance: "presenter" }] });
    }
  }
  fs.writeFileSync(out, JSON.stringify({ version: 6, generatedAt: "2026-07-27T00:00:00Z", results }, null, 2));
' "$queue" "$results"
printf '%s\n' '{"type":"assistant","message":{"content":"working"}}'
printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":1.25,"duration_ms":60000}'
exit 0
STUB
chmod +x "${TMP}/home/.local/bin/claude"

# Six shows: one grouped producer answering for two others, plus four standalone hunts.
cat > "${SUPPORT}/overture-prep-queue.json" <<'EOF'
{"version":6,"generatedAt":"2026-07-27T00:00:00Z","items":[
 {"naturalKey":"k1","groupName":"One","discipline":"theater","priorRelationship":"none",
  "reprepMode":"contacts_only","alsoAnswersFor":["k1b","k1c"]},
 {"naturalKey":"k2","groupName":"Two","discipline":"theater","priorRelationship":"none","reprepMode":"contacts_only"},
 {"naturalKey":"k3","groupName":"Three","discipline":"theater","priorRelationship":"none","reprepMode":"contacts_only"},
 {"naturalKey":"k4","groupName":"Four","discipline":"theater","priorRelationship":"none","reprepMode":"contacts_only"}
]}
EOF

# The probe marker is what makes this a CHECK rather than a normal Prep run, and so what turns chunking on.
printf '%s' '{"keys":["k1","k1b","k1c","k2","k3","k4"],"startedAt":"2026-07-27T00:00:00Z"}' \
  > "${SUPPORT}/reachability-probe-run.json"

export OVERTURE_SUPPORT_DIR="${SUPPORT}"
export STUB_LOG_DIR="${TMP}/stublogs"
mkdir -p "${STUB_LOG_DIR}"
# A short cancel poll so the heartbeat ticks (and therefore merges) during the run rather than after it.
export PREP_CANCEL_POLL_SECONDS=1

# Run it the way the app does: /bin/sh, which on macOS is bash in POSIX mode.
HOME="${TMP}/home" /bin/sh "${SCRIPT_DIR}/prep-run.sh" >/dev/null 2>&1
RUN_STATUS=$?

RESULTS="${SUPPORT}/overture-prep-results.json"

assert_equals "the run exits cleanly" "0" "${RUN_STATUS}"

# Four queue items and a cap of 10 means one claude per item: the cap is a ceiling, not a target.
assert_equals "one claude launched per work-list item, not one for the whole run" \
  "4" "$(find "${STUB_LOG_DIR}" -name 'queue.*' | wc -l | tr -d ' ')"

assert_equals "every chunk got its OWN slice of the queue, never the whole file" \
  "0" "$(grep -l 'overture-prep-queue.json' "${STUB_LOG_DIR}"/queue.* 2>/dev/null | wc -l | tr -d ' ')"

# The merge is the load-bearing step: four separate chunk-results files become the one file the app reads.
keys="$(node -e 'const r=require(process.argv[1]);console.log(r.results.map(x=>x.naturalKey).sort().join(","))' \
  "${RESULTS}" 2>/dev/null)"
assert_equals "every show comes home, including the two the grouped item answered for" \
  "k1,k1b,k1c,k2,k3,k4" "${keys}"

assert_contains "the merged file carries the prep results version" \
  "$(cat "${RESULTS}")" '"version": 6'

# Cost across streams. Four chunks at 1.25 each is 5.00, and the duration is the longest, not the sum.
# Reading one stream would have said 1.25, and a batch ceiling sized from that would let through four
# times the spend Dan agreed to.
assert_contains "the cost sums every chunk's stream" "$(cat "${RESULTS}")" '"usd": 5'
assert_contains "the cost is marked recorded, so a ceiling may be sized from it" \
  "$(cat "${RESULTS}")" '"recorded": true'
assert_contains "and it says how many streams it read" "$(cat "${RESULTS}")" '"streams": 4'
assert_contains "the duration is the longest chunk, not the sum of the four" \
  "$(cat "${RESULTS}")" '"durationMs": 60000'
# The exact regression: four chunks, four event files, all four read. Anything less means the paths were
# mangled on the way in, and the figure the spending brake is sized from would be silently wrong.
assert_contains "every chunk's event file was found despite the space in the path" \
  "$(cat "${RESULTS}")" '"streams": 4'


# The progress file the toolbar reads must reflect the merged total, not one chunk's share.
assert_contains "progress counts every show, so the toolbar does not stall at one chunk's worth" \
  "$(cat "${SUPPORT}/overture-prep-progress.json" 2>/dev/null)" '"completed": 6'

# A check never drafts, and the chunked prompt must not carry the voice-learning step: several claudes
# rewriting overture-voice-guidance.md at once would race on one file.
assert_equals "no chunk was told to run the once-per-run voice step" \
  "0" "$(grep -l 'voice-feedback' "${STUB_LOG_DIR}"/prompt.* 2>/dev/null | wc -l | tr -d ' ')"
assert_equals "and no chunk was told to draft anything" \
  "0" "$(grep -l 'draft the email' "${STUB_LOG_DIR}"/prompt.* 2>/dev/null | wc -l | tr -d ' ')"
# The grouping instruction has to actually reach the model, or the covered shows never come home. It is
# in EVERY chunk prompt, because any chunk may hold a grouped item.
assert_equals "every chunk was told how to answer for the shows a grouped item covers" \
  "4" "$(grep -l 'alsoAnswersFor' "${STUB_LOG_DIR}"/prompt.* 2>/dev/null | wc -l | tr -d ' ')"

# The in-flight marker and the pid file must both be cleaned up, or the next run sees a run in progress.
assert_equals "the in-flight marker is gone, so the next check is not refused as already running" \
  "absent" "$([ -e "${SUPPORT}/prep-running" ] && echo present || echo absent)"
assert_equals "no named pipe is left behind" \
  "0" "$(find "${SUPPORT}" -name '*.fifo' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# And the NORMAL prep path, with no probe marker, must be untouched: one claude, the whole queue, and
# the single-stream cost exactly as before. Chunking a normal Prep would race the voice guidance file.
# ---------------------------------------------------------------------------
rm -f "${SUPPORT}/reachability-probe-run.json" "${RESULTS}"
rm -f "${STUB_LOG_DIR}"/queue.* "${STUB_LOG_DIR}"/prompt.*
HOME="${TMP}/home" /bin/sh "${SCRIPT_DIR}/prep-run.sh" >/dev/null 2>&1

assert_equals "a normal Prep run still launches exactly one claude" \
  "1" "$(find "${STUB_LOG_DIR}" -name 'queue.*' | wc -l | tr -d ' ')"
assert_equals "and hands it the whole queue, not a chunk" \
  "1" "$(grep -l 'overture-prep-queue.json' "${STUB_LOG_DIR}"/queue.* 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "and records its single-stream cost exactly as before" \
  "$(cat "${RESULTS}")" '"usd": 1.25'
assert_equals "and IS still told to do the once-per-run voice step, which only chunking removes" \
  "1" "$(grep -l 'voice-feedback' "${STUB_LOG_DIR}"/prompt.* 2>/dev/null | wc -l | tr -d ' ')"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "prep-run-chunking.test.sh: all assertions passed"
  exit 0
else
  echo "prep-run-chunking.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
