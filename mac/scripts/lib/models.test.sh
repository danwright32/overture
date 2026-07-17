#!/usr/bin/env bash
set -uo pipefail

# #804: every detached run used to invoke `claude -p` with no --model flag, so it silently inherited
# whatever the CLI default happened to be on Dan's machine that day.
#
# For the mechanical runs that was only money. For DRAFTING it was his voice: the words that reach a
# stranger. A CLI upgrade or a settings change could have altered how every email he sends sounds, with
# no code change, no commit, and no warning, and nothing in the repo recorded which model wrote a draft,
# so he would only have found out by noticing the emails reading differently.
#
# The model choice lives in ONE file so it cannot be got right in two scripts and wrong in the third.

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

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/models.sh"

# Drafting: Dan's call (2026-07-12). The TIER is pinned, not the exact version, so he picks up each new
# Opus as it ships. He accepted that his voice can shift with a new model in exchange for the
# improvement, which is only a reasonable trade because the model used is now RECORDED: he can tell what
# wrote a draft rather than sensing that something changed.
assert_equals "drafting uses the strong tier" "opus" "${OVERTURE_MODEL_DRAFTING}"

# The extraction run. It LOOKED like the cheap-model case (a strict output schema, no judgment), and rode
# on haiku on that reasoning. Dan's call (2026-07-17), after the first real watchlist scouts: haiku does
# not actually do the job. On a 19-source queue it read only the first ~6 pages and then fabricated
# "no dated content" for the rest without opening them, and it made ZERO detail-page fetches all run, so
# even the pages it did read produced venue-less events that get rejected before ingest. Reading a
# calendar is not mechanical after all: it needs the stamina to work a whole queue and follow each event
# to its own page. The extraction run only ever fires on a scout Dan STARTS (the daily automatic run
# watches and spends nothing, ScoutService.swift), so this heavier tier costs usage only on his manual
# scouts, never on autopilot.
assert_equals "reading a calendar needs a model that will actually read it" "sonnet" "${OVERTURE_MODEL_EXTRACTION}"

# #874: the reply run is NAMED for the classification half of its job, and that is what hid this. It also
# DRAFTS the reply, in Dan's voice, to a person who has already written back to him: a warmer lead than
# any cold pitch, and by this file's own definition that is drafting, not a mechanical read. It ran on the
# cheap tier for exactly as long as nobody said the second half of its name out loud.
#
# Asserted against the DRAFTING tier rather than the literal "opus", so the reply drafter follows Dan
# wherever he pins drafting next instead of quietly falling behind it a second time.
assert_equals "a reply to a warm lead is DRAFTING, so it uses the drafting tier" \
  "${OVERTURE_MODEL_DRAFTING}" "${OVERTURE_MODEL_REPLY_CLASSIFY}"

# The whole point: nothing that writes words to a stranger may quietly become the cheap model, and the
# mechanical run must not quietly become the expensive one.
for var in OVERTURE_MODEL_DRAFTING OVERTURE_MODEL_REPLY_CLASSIFY; do
  if [[ "${!var}" == "${OVERTURE_MODEL_EXTRACTION}" ]]; then
    echo "FAIL - ${var} must not share the extraction model: one is Dan's voice, the other is a parser"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${var} is deliberately not the mechanical model"
  fi
done

# Every runner actually PASSES it. A model constant nobody references is worse than none: it reads as
# solved while every run still inherits the CLI default.
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  body="$(cat "${SCRIPT_DIR}/../${script}")"
  assert_contains "${script} passes --model" "${body}" '--model'
  assert_contains "${script} sources the shared model list" "${body}" 'lib/models.sh'
done

# And each records what it used, so a draft can be traced to what wrote it. Without this, pinning the
# TIER still lets the voice change under Dan with no way to confirm it did.
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  body="$(cat "${SCRIPT_DIR}/../${script}")"
  assert_contains "${script} records the model it used" "${body}" 'record_model'
done

# --- record_model, actually executed ---------------------------------------------------------------
#
# The greps above prove the runners CALL it. These prove it does the right thing, including on the paths
# that matter most: a run that produced nothing, a run whose output is garbage, and a machine with no
# node. record_model runs at the very end of a detached run, so anything it does wrong lands on Dan as a
# corrupted results file or a run that dies after doing all its real work.

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The happy path: the model is stamped in, and nothing else is disturbed.
printf '%s' '{"version":2,"generatedAt":"2026-07-12T00:00:00Z","results":[{"naturalKey":"show"}]}' \
  > "${TMP}/results.json"
record_model "${TMP}/results.json" "opus"
stamped="$(node -e 'const j=require(process.argv[1]); console.log(j.model)' "${TMP}/results.json" 2>/dev/null)"
kept="$(node -e 'const j=require(process.argv[1]); console.log(j.results[0].naturalKey)' "${TMP}/results.json" 2>/dev/null)"
assert_equals "the model is stamped into the results file" "opus" "${stamped}"
assert_equals "and the run's actual results are left untouched" "show" "${kept}"

# A run that produced NO results file. Common (a run that failed, or found nothing to do) and already
# reported loudly on its own path, so this must exit quietly rather than fail the run after the fact.
if record_model "${TMP}/does-not-exist.json" "opus"; then
  echo "ok - a missing results file is not an error here (it is reported on its own path)"
else
  echo "FAIL - record_model must not fail a run just because there was nothing to stamp"
  FAILURES=$((FAILURES + 1))
fi

# A results file that is NOT valid JSON. That means the run itself failed, which is reported elsewhere.
# The file must be left EXACTLY as it was: overwriting it would destroy the evidence of what went wrong,
# and turning it into a second failure would only confuse the first.
printf '%s' 'this is not json {' > "${TMP}/garbage.json"
before="$(cat "${TMP}/garbage.json")"
record_model "${TMP}/garbage.json" "opus" || true
after="$(cat "${TMP}/garbage.json")"
assert_equals "an unparsable results file is left exactly as it was" "${before}" "${after}"

# No node on PATH. The stamp is a nice-to-have; the run's actual results are not. Losing the trace must
# never lose Dan's drafts.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/nonode.json"
nonode_before="$(cat "${TMP}/nonode.json")"
if PATH="/nonexistent" record_model "${TMP}/nonode.json" "opus"; then
  echo "ok - no node on PATH degrades to no trace, never to a failed run"
else
  echo "FAIL - record_model must not fail the run when node is unavailable"
  FAILURES=$((FAILURES + 1))
fi
assert_equals "and the results file survives a machine with no node" \
  "${nonode_before}" "$(cat "${TMP}/nonode.json")"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all models.sh checks passed"
