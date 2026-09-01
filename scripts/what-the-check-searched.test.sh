#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #2996: when a contact check comes home empty, the useful question is "what did it actually search
# for", and answering it meant reading raw JSONL by hand out of Application Support. That is how #2983
# was diagnosed: extracting one run's 22 web calls showed not one of them mentioned the company whose
# contact page publishes an address, which turned a vague "the check missed it" into a precise defect.
#
# This is a READER over evidence that already exists. It became possible for runs older than the
# current one only with #3446, which archives the streams per run; before that the next run overwrote
# them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${SCRIPT_DIR}/what-the-check-searched.sh"
FAILURES=0
# One trap naming every scratch this fixture makes, because bash keeps exactly ONE EXIT trap and a
# second one silently replaces the first (#3249).
TMP="$(fixture_scratch_dir)"
EMPTY_DIR=""
trap 'rm -rf "${TMP}" "${EMPTY_DIR:-}"' EXIT

# A support directory shaped like the real one: an archived run holding its queue, and the streams for
# that same run under the same stamp in their own directory (#3446).
mkdir -p "${TMP}/check-run-archives/20260830-205244" \
         "${TMP}/check-run-event-archives/20260830-205244"
cat > "${TMP}/check-run-archives/20260830-205244/overture-check-queue.json" <<'JSON'
{"version":6,"generatedAt":"2026-08-30T20:52:44Z","items":[
  {"naturalKey":"kestrel-2027-04-18-rowan","groupName":"Kestrel Quartet","venue":"Rowan Hall",
   "performanceDate":"2027-04-18","presenterOnRecord":"Rowan Presenting"},
  {"naturalKey":"other-2027-05-01-elsewhere","groupName":"Marlow Ensemble","venue":"Elsewhere",
   "performanceDate":"2027-05-01","presenterOnRecord":null}
]}
JSON
cat > "${TMP}/check-run-event-archives/20260830-205244/check-run-events.chunk-1.jsonl" <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"Kestrel Quartet contact"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://kestrelquartet.example/"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"result","total_cost_usd":0.5}
JSON

out="$(bash "${TOOL}" --support "${TMP}" "Kestrel Quartet" 2>&1)"; status=$?

assert_equals "a show that was checked is reported" "0" "${status}"
assert_contains "names the run it found the show in" "${out}" "20260830-205244"
assert_contains "shows the show as the run was GIVEN it, not as the store holds it now" \
  "${out}" "Rowan Presenting"
assert_contains "lists the searches, in order" "${out}" "Kestrel Quartet contact"
assert_contains "and the fetches" "${out}" "https://kestrelquartet.example/"
assert_not_contains "a local file read is not a search and must not pad the list" "${out}" "/tmp/x"

# Matching by natural key too, since that is what every other tool here keys on.
key_out="$(bash "${TOOL}" --support "${TMP}" "kestrel-2027-04-18-rowan" 2>&1)"
assert_contains "matches on the natural key as well as the name" \
  "${key_out}" "Kestrel Quartet contact"

# THE STATE THAT MATTERS MOST, and the commonest one today: the run's queue is archived and its
# streams are not, because streams were only archived from #3446 onwards. Reporting "no searches" there
# would be a claim about the check when the truth is that nobody kept the evidence (L98, L11).
mkdir -p "${TMP}/check-run-archives/20260817-172812"
cat > "${TMP}/check-run-archives/20260817-172812/overture-check-queue.json" <<'JSON'
{"version":6,"generatedAt":"2026-08-17T17:28:12Z","items":[
  {"naturalKey":"older-2027-01-01-room","groupName":"Older Show","venue":"Room","performanceDate":"2027-01-01"}
]}
JSON
old_out="$(bash "${TOOL}" --support "${TMP}" "Older Show" 2>&1)"
assert_contains "a run whose streams were never archived says so" "${old_out}" "not archived"
assert_not_contains "and never claims the check searched for nothing" "${old_out}" "no searches"

# A show nobody has checked is its own answer, and it is not an error.
miss="$(bash "${TOOL}" --support "${TMP}" "Nobody Checked This" 2>&1)"; miss_status=$?
assert_equals "a show that appears in no archived run exits 1" "1" "${miss_status}"
assert_contains "and says which it is" "${miss}" "no archived run"

# UNMEASURED is its own exit code, because a support directory with no archives at all and a show that
# was never checked leave the same empty result, and the emptiest possible failure must not read as the
# cleanest possible answer (L98).
EMPTY_DIR="$(fixture_scratch_dir)"
bash "${TOOL}" --support "${EMPTY_DIR}" "Anything" >/dev/null 2>&1
assert_equals "no archives at all is UNMEASURED, not 'not found'" "2" "$?"

# An archived queue this tool cannot READ is a different answer from a show that is not in it, and
# until this they were the same silence: the run was skipped and the show reported as never checked.
# That is the worse direction, because the run it cannot read is exactly the one somebody is asking
# about (L10, L11).
mkdir -p "${TMP}/check-run-archives/20260901-090000"
printf '%s' 'not json at all' > "${TMP}/check-run-archives/20260901-090000/overture-check-queue.json"
corrupt="$(bash "${TOOL}" --support "${TMP}" "Nobody Checked This" 2>&1)"
assert_contains "an unreadable archived queue is named, not skipped in silence" \
  "${corrupt}" "20260901-090000"
assert_contains "and says it could not be read" "${corrupt}" "could not be read"

# --- #3357 Phase 1.3: the per item SIDECAR, which is the whole reason the refusal above exists --------
#
# The block above proves the tool refuses to attribute when a chunk carried several shows. This proves
# it STOPS refusing when the run left a sidecar saying which calls were whose, which is the only thing
# that turns "read these as the whole chunk" into an answer about one show.

ATTR_DIR="$(fixture_scratch_dir)"
mkdir -p "${ATTR_DIR}/check-run-archives/20260902-101500" \
         "${ATTR_DIR}/check-run-attribution-archives/20260902-101500"
cat > "${ATTR_DIR}/check-run-archives/20260902-101500/overture-check-queue.json" <<'JSON'
{"version":6,"generatedAt":"2026-09-02T10:15:00Z","items":[
  {"naturalKey":"kestrel-2027-04-18-rowan","groupName":"Kestrel Quartet","venue":"Rowan Hall",
   "performanceDate":"2027-04-18"},
  {"naturalKey":"other-2027-05-01-elsewhere","groupName":"Marlow Ensemble","venue":"Elsewhere",
   "performanceDate":"2027-05-01"}
]}
JSON
cat > "${ATTR_DIR}/check-run-attribution-archives/20260902-101500/check-run-attribution.json" <<'JSON'
{"version":1,"attributed":1,"unattributable":0,"unmeasured":0,"beforeFirstWrite":0,
 "watchdogKills":[{"chunk":2,"at":"2026-09-02T10:20:00Z","requestInFlightSeconds":190,
                   "itemsAlreadyWritten":[],"itemsKnown":true}],
 "killsReadable":true,
 "streams":[{"chunk":1,"outcome":"attributed","complete":true,"unattributedCalls":[],
   "items":[
     {"naturalKey":"kestrel-2027-04-18-rowan",
      "calls":[{"route":"search","detail":"Kestrel Quartet producer"},
               {"route":"fetch","detail":"https://kestrelquartet.example/contact"}]},
     {"naturalKey":"other-2027-05-01-elsewhere",
      "calls":[{"route":"search","detail":"Marlow Ensemble booking"}]}]}]}
JSON

attr_out="$(bash "${TOOL}" --support "${ATTR_DIR}" "Kestrel Quartet" 2>&1)"
assert_contains "the sidecar's calls for THIS show are listed" \
  "${attr_out}" "Kestrel Quartet producer"
assert_contains "and its fetch too" "${attr_out}" "https://kestrelquartet.example/contact"

# THE POINT. Without the sidecar this run would print every call in the chunk and refuse to say whose
# they were; with it, the other show's search must not appear under this one.
assert_not_contains "and the OTHER show's search does not appear under this one" \
  "${attr_out}" "Marlow Ensemble booking"
assert_not_contains "so the whole-chunk refusal is not printed either" \
  "${attr_out}" "NOT attributed to this one"

# #3357 Phase 1.5: a run with a killed chunk in it is a confound, and the tool says so where somebody
# reading the calls will see it (#3007).
assert_contains "a run with a watchdog kill says it is not comparison evidence" \
  "${attr_out}" "not usable as comparison evidence"

# A show the sidecar attributes NO calls to is a real finding, and the commonest one worth having: the
# run reached it and searched for nothing. It must not read as a missing sidecar.
cat > "${ATTR_DIR}/check-run-attribution-archives/20260902-101500/check-run-attribution.json" <<'JSON'
{"version":1,"attributed":1,"unattributable":0,"unmeasured":0,"beforeFirstWrite":0,
 "watchdogKills":[],"killsReadable":true,
 "streams":[{"chunk":1,"outcome":"attributed","complete":true,"unattributedCalls":[],
   "items":[{"naturalKey":"kestrel-2027-04-18-rowan","calls":[]}]}]}
JSON
none_out="$(bash "${TOOL}" --support "${ATTR_DIR}" "Kestrel Quartet" 2>&1)"
assert_contains "a show the run searched for nothing on says exactly that" \
  "${none_out}" "searched for nothing"

rm -rf "${ATTR_DIR}"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all what-the-check-searched checks passed"
