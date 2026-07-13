#!/usr/bin/env bash
set -uo pipefail

# What the three detached runs actually RECEIVE, as opposed to what their prompt files appear to say.
#
# #847: the extract run read Dan's Kaufman Music Center page, extracted 20 events correctly, then noticed
# the listings were paginated and STOPPED TO ASK HIM which he wanted:
#
#   "I can fetch and extract the remaining pages now, or submit the first page and note in the results
#    that pagination wasn't checked. The choice affects completeness vs. speed."
#
# It then exited without writing the results file. Twenty successfully extracted shows, thrown away, and
# the app left polling for a file that would never arrive. This is a DETACHED run. There is nobody to ask.
# A question is not an output, and the prompt is the only place that rule can live.
#
# #853: worse, and quieter. Every runner's prompt is a DOUBLE-QUOTED shell string, so bash rewrites it on
# its way to the model. A backtick made bash EXECUTE a word and delete it from the sentence: "record the
# decision in that source's `note`" reached the model as "record the decision in that source's . If you
# are unsure". A raw double quote ENDED THE STRING EARLY, so the rest of the line ran as shell commands
# and the model was handed a truncated instruction. No error, no symptom, and no Swift test could see it.
#
# #855: only the SCOUT prompt was ever checked this way. Prep and reply-classify are built the same way,
# in the same kind of string, and nobody had ever looked at what they arrive as. Prep is the run that
# writes the emails reaching strangers in Dan's VOICE: a sentence silently truncated there for months
# would produce no error and no symptom, only drafts quietly worse than they should be.
#
# So every prompt is now expanded exactly as its own script expands it, and asserted against what the
# model actually receives.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

fail() {
  echo "FAIL - $1"
  if [[ $# -gt 1 ]]; then echo "  $2"; fi
  FAILURES=$((FAILURES + 1))
}

# The prompt region, BOUNDED. The closing quote sits on a line of its own in every runner precisely so
# this range terminates. Before #856 it did not, and this whole guard was silently reading each script's
# CODE as if it were prompt text: it reported a safety it had never established.
prompt_region() {
  sed -n '/^PROMPT=/,/^"$/p' "${SCRIPT_DIR}/$1"
}

# What the model receives: the prompt after bash has finished with it. The runner's own variables are
# stubbed, because what is under test is the TEXT, not the paths.
expanded_prompt() {
  ( set +u
    RUNBOOK=RB; QUEUE=Q; RESULTS=R; PROGRESS=P; VOICE=V; HISTORY=H; SUPPORT=S
    eval "$(prompt_region "$1")" 2>/dev/null
    printf '%s' "${PROMPT}" )
}

# Each runner's load-bearing rules: the sentences that, if bash ate them, would cost Dan something real
# and cost it silently. Tab-separated, so a rule can contain spaces and commas.
rules_for() {
  case "$1" in
    scout-extract-run.sh)
      # #847: the rules that would have saved the twenty shows.
      printf '%s\n' \
        "the ALWAYS-write rule	ALWAYS write" \
        "the never-stop-and-ask rule	Never stop to ask" \
        "the whole decide-and-record sentence	record the decision in that source's note" \
        "the pagination rule	FIRST page only" \
        "the rule that a sourceId is echoed, never rebuilt	Copy each item's sourceId VERBATIM" \
        "its final sentence, intact	one short line on anything that made this hard"
      ;;
    prep-run.sh)
      # This run writes the emails that reach strangers in Dan's voice. Every rule here is either his
      # voice or a leak guard, and both fail silently: there is no error, only worse drafts.
      printf '%s\n' \
        "the instruction to write in Dan's voice via the skill	dan-wright-brand-voice" \
        "the rule that the skill WINS over the guidance file	the skill wins" \
        "the #119/#249 leak guard on the voice guidance	strip all org/venue/contact" \
        "the leak guard's second half	never carry them into other drafts" \
        "the rule that a naturalKey is echoed, never rebuilt	Copy each item's naturalKey verbatim" \
        "the demand that a contact be real and verified	strict verification" \
        "the instruction to write its results	Write the complete PrepResults JSON" \
        "its final sentence, intact	real, verifiable contacts."
      ;;
    reply-classify-run.sh)
      printf '%s\n' \
        "all four intents, intact	interested, wants_to_book, has_question, or declined" \
        "the #438 rule: never ask for what Overture already knows	NEVER ask the contact for the date" \
        "and its positive half: reference them instead	REFERENCE them, never request them" \
        "the #119/#249 leak guard on raw past emails	NEVER quote or paraphrase raw past email pairs" \
        "the rule that BOTH ids are echoed, never rebuilt	Copy each item's naturalKey AND recipientId verbatim" \
        "its final sentence, intact	draft from the runbook's voice rules alone."
      ;;
  esac
}

for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  echo "--- ${script}"
  region="$(prompt_region "${script}")"

  # The bound itself. If a prompt does not close on a line of its own, the sed range runs to end of file
  # and every check below reads the script's own code as prompt text.
  if [[ "$(printf '%s' "${region}" | tail -1)" == '"' ]]; then
    echo "ok - ${script}: the prompt closes on its own line, so this guard reads the prompt and not the script"
  else
    fail "${script}: the PROMPT does not close on a line of its own" \
         "the sed range runs to EOF, so every check below is reading the script's code as prompt text"
  fi

  # Inside a double-quoted string, bash EXECUTES a backtick and substitutes a $( ), silently.
  if [[ "${region}" == *'`'* ]]; then
    fail "${script}: the prompt contains a backtick, which bash executes as a command" \
         "the model would receive that sentence with the word silently deleted"
  else
    echo "ok - ${script}: no backticks for bash to swallow"
  fi
  if [[ "${region}" == *'$('* ]]; then
    fail "${script}: the prompt contains \$( ), which bash runs as a command" \
         "the model would receive that command's output, or nothing, in place of the words"
  else
    echo "ok - ${script}: no command substitution for bash to run"
  fi

  # The real test, and the strongest: what the model RECEIVES. Every check above can pass while bash
  # quietly rewrites the sentence on its way out.
  expanded="$(expanded_prompt "${script}" 2>/dev/null)"
  if [[ -z "${expanded}" ]]; then
    fail "${script}: the prompt expands to NOTHING" "bash destroyed it entirely; the model would get an empty run"
    continue
  fi
  # Matched against whitespace-normalized text. These prompts are hard-wrapped, so a rule reaches the
  # model as one sentence but sits in the file across two lines. Normalizing means a rule is asserted on
  # its WORDS, and rewrapping a paragraph can never turn this guard red for no reason (which is how a
  # noisy guard gets weakened until it stops guarding).
  expanded="$(printf '%s' "${expanded}" | tr -s '[:space:]' ' ')"

  while IFS=$'\t' read -r desc needle; do
    [[ -n "${desc:-}" ]] || continue
    if [[ "${expanded}" == *"${needle}"* ]]; then
      echo "ok - ${script}: the model actually receives ${desc}"
    else
      fail "${script}: the model does NOT receive ${desc}" \
           "bash rewrote the prompt on its way out. Check for backticks, \$( ), or raw double quotes."
    fi
  done < <(rules_for "${script}")
done

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all runner prompt checks passed"
