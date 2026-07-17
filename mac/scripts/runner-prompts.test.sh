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
        "the ALWAYS-write rule	ALWAYS have written" \
        "the #1015 incremental-write rule	Immediately after finishing THIS item" \
        "the never-stop-and-ask rule	Never stop to ask" \
        "the whole decide-and-record sentence	record the decision in that source's note" \
        "the rule against following pagination links	NEVER follow a link to another listings page" \
        "the #858 rule that every stitched month gets read	Read EVERY marked section" \
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
        "the #1023 incremental-write rule	Immediately after finishing EACH item, rewrite" \
        "its final sentence, intact	real, verifiable contacts."
      ;;
    reply-classify-run.sh)
      # #872: this run answers a real person who wrote back to Dan, and until then it had NO voice skill
      # and no voice rules: it was inventing his voice from the phrase "in Dan's voice".
      printf '%s\n' \
        "all four intents, intact	interested, wants_to_book, has_question, or declined" \
        "the #438 rule: never ask for what Overture already knows	NEVER ask the contact for the date" \
        "and its positive half: reference them instead	REFERENCE them, never request them" \
        "the instruction to draft from Dan's one voice definition	dan-wright-brand-voice" \
        "the rule that the skill is authoritative	skill is AUTHORITATIVE" \
        "the hard rule that costs him most when broken	no em dashes" \
        "the hard rule against inventing facts	NO fabrication" \
        "the #119/#249 leak guard on raw past emails	NEVER quote or paraphrase raw past email pairs" \
        "the rule that BOTH ids are echoed, never rebuilt	Copy each item's naturalKey AND recipientId verbatim" \
        "its final sentence, intact	the guidance file only ever nudges."
      ;;
  esac
}

# #872: an instruction the run cannot physically obey.
#
# A prompt that says "invoke the dan-wright-brand-voice skill" inside a run whose --allowedTools do not
# include Skill is not an instruction, it is a wish. The model cannot call the tool, so it does the next
# best thing and INVENTS the voice, which is indistinguishable from working right up until Dan reads a
# draft that does not sound like him. The failure is silent by construction, so it has to be caught here.
assert_tools_can_obey_the_prompt() {
  local script="$1"
  local body region
  body="$(cat "${SCRIPT_DIR}/${script}")"
  region="$(prompt_region "${script}")"

  if [[ "${region}" != *"skill"* && "${region}" != *"Skill"* ]]; then
    echo "ok - ${script}: asks for no skill, so it needs no Skill tool"
    return
  fi
  local tools
  tools="$(printf '%s' "${body}" | grep -o -- '--allowedTools "[^"]*"' | head -1)"
  if [[ "${tools}" == *"Skill"* ]]; then
    echo "ok - ${script}: its prompt invokes a skill AND the run is allowed the Skill tool"
  else
    fail "${script}: the prompt invokes a skill but the run cannot call one" \
         "allowedTools is ${tools:-missing}. The model would silently invent Dan's voice instead."
  fi
}

# #872: no em dashes anywhere the drafting runs read.
#
# Dan's rule is absolute and the brand-voice skill states it: no em dashes, ever. These prompts and
# runbooks are the instructions for the runs that write in his voice, and a model reads its instructions
# as a REGISTER as much as a rule list. Telling it "no em dashes" in a document littered with them is the
# one instruction guaranteed to be undermined by its own delivery.
#
# The pattern is built from its BYTES rather than written literally, so this file, which enforces the
# no-dash rule, does not itself have to contain the characters it forbids. (Dan's pre-push hook checks
# every changed line for exactly these, and a guard that has to be exempted from the rule it guards is a
# guard nobody will trust for long.) U+2014 EM DASH, U+2013 EN DASH.
DASH_CLASS="[$(printf '\xe2\x80\x94\xe2\x80\x93')]"

assert_no_dashes() {
  local file="$1" label="$2" content
  # The one exception, and it is not prose: a literal section heading that must match Dan's live
  # overture-voice-guidance.md byte for byte. Changing it here without changing his file would send the
  # run looking for a heading that does not exist, which is a real bug in place of a punctuation one.
  content="$(sed 's/## Dan.s notes (authoritative [^)]*)//' "${file}")"
  if printf '%s' "${content}" | grep -q "${DASH_CLASS}"; then
    fail "${label} contains an em or en dash" \
         "$(printf '%s' "${content}" | grep -n "${DASH_CLASS}" | head -2)"
  else
    echo "ok - ${label} carries no dashes for the model to imitate into Dan's emails"
  fi
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

  assert_tools_can_obey_the_prompt "${script}"
  assert_no_dashes "${SCRIPT_DIR}/${script}" "${script}'s prompt"
done

# The runbooks are read by the runs too, and the drafting ones are read in order to write in Dan's voice.
echo "--- the runbooks the runs read"
for book in prep-runbook.md reply-classify-runbook.md scout-extract-runbook.md; do
  assert_no_dashes "${SCRIPT_DIR}/../../docs/${book}" "docs/${book}"
done

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all runner prompt checks passed"
