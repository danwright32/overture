#!/usr/bin/env bash
set -uo pipefail

# #847: the extract run read Dan's Kaufman Music Center page, extracted 20 events correctly, then
# noticed the listings were paginated and STOPPED TO ASK HIM which he wanted:
#
#   "I can fetch and extract the remaining pages now, or submit the first page and note in the results
#    that pagination wasn't checked. The choice affects completeness vs. speed."
#
# It then exited without writing the results file. Twenty successfully extracted shows, thrown away, and
# the app left polling for a file that would never arrive.
#
# This is a DETACHED run. There is nobody to ask. A question is not an output. The prompt is the only
# place that rule can live, so these checks hold it there.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert_contains() {
  local desc="$1" needle="$2"
  if [[ "${PROMPT}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected the prompt to contain: ${needle}"
    FAILURES=$((FAILURES + 1))
  fi
}

PROMPT="$(cat "${SCRIPT_DIR}/scout-extract-run.sh")"

# The rule that would have saved the twenty shows: ALWAYS write the results file. There is no ending in
# which the right move is to stop and ask.
assert_contains "the run is told it must ALWAYS write results" "ALWAYS write"
assert_contains "the run is told never to stop and ask" "Never stop to ask"
assert_contains "an ambiguity is resolved by deciding, and the decision recorded" "decide"

# The `note` field already exists for exactly this. It is where a decision goes, so the run never has to
# choose between finishing and being honest about what it could not do.
assert_contains "the run is pointed at note as the place to record what it could not do" "note"

# Pagination specifically, because it is what actually happened and it will recur on any real venue's
# calendar. Whatever the rule is, it has to BE a rule, so the run never has to invent one mid-flight.
assert_contains "pagination has a stated rule" "paginat"

# --- the prompt must survive the shell -------------------------------------------------------------
#
# Every runner's prompt is a DOUBLE-QUOTED shell string, so a backtick in it is not punctuation: bash
# runs it as a command. On 2026-07-12 a prompt written as "record the decision in that source's \`note\`"
# made bash execute `note`, print "note: command not found", and hand the model a sentence with the word
# missing: "record the decision in that source's . If you are unsure". The instruction was mangled and the
# run failed, and nothing in a Swift test could ever have seen it.
#
# So: no backticks in any prompt. Ever. Same for $( ), which substitutes just as silently.
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  body="$(cat "${SCRIPT_DIR}/${script}")"
  # Only the PROMPT itself: the script's own $(dirname ...) plumbing above it is legitimate.
  prompt_body="$(sed -n '/^PROMPT=/,/^"$/p' "${SCRIPT_DIR}/${script}")"
  if [[ "${prompt_body}" == *'`'* ]]; then
    echo "FAIL - ${script}'s prompt contains a backtick, which bash executes as a command"
    echo "  the model would receive the sentence with that word silently deleted"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${script}'s prompt has no backticks for bash to swallow"
  fi
done

# The strongest check of the lot, because it tests what the MODEL RECEIVES rather than what the file
# says. Everything above can pass while bash quietly rewrites the sentence on its way out.
#
# Both bugs on 2026-07-12 were exactly that. A backtick made bash execute a word and delete it from the
# sentence. A raw double quote inside the double-quoted prompt ENDED THE STRING EARLY, so the rest of the
# line ran as shell commands ("1: command not found", "later: command not found") and the reader was
# handed a truncated instruction. The run failed, and no Swift test could ever have seen it.
expanded_prompt() {
  ( set +u                      # the prompt references vars the real script sets; we only want its TEXT
    RUNBOOK=RB; QUEUE=Q; RESULTS=R; PROGRESS=P
    eval "$(sed -n "/^PROMPT=/,/^\"\$/p" "${SCRIPT_DIR}/scout-extract-run.sh")" 2>/dev/null
    printf '%s' "${PROMPT}" )
}
EXPANDED="$(expanded_prompt 2>/dev/null)"

assert_expanded_contains() {
  local desc="$1" needle="$2"
  if [[ "${EXPANDED}" == *"${needle}"* ]]; then
    echo "ok - the model actually receives: ${desc}"
  else
    echo "FAIL - the model does NOT receive: ${desc}"
    echo "  bash rewrote the prompt on its way out. Check for backticks, \$( ), or raw double quotes."
    FAILURES=$((FAILURES + 1))
  fi
}

assert_expanded_contains "the always-write rule" "ALWAYS write"
assert_expanded_contains "the never-ask rule" "Never stop to ask"
assert_expanded_contains "the whole decide-and-note sentence" "record the decision in that source's note"
assert_expanded_contains "the pagination rule" "FIRST page only"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all scout-extract prompt checks passed"
