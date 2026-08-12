#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

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

# #1097: the runners no longer carry a literal --allowedTools flag; each folds through a scope function
# (scout_extract_claude_scope, prep_claude_scope, reply_classify_claude_scope) that emits the flag AND a
# fail-closed --permission-mode. Source them so the "can the run obey its own prompt" check below can ask
# each run's REAL effective scope instead of grepping a literal that no longer exists. scout-tools.sh
# sources lib/claude-run-scope.sh, so this one line brings in all three scope functions.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/scout-tools.sh"

# #1682: the scope functions now also turn off every Claude Code plugin installed on this Mac, which they
# can only do by asking the real claude binary what those are. Resolved the same way the runners resolve
# it (lib/runner-setup.sh), so this fixture asks for the scope a real run would get. On a machine with no
# claude installed resolve_claude exits, which is the honest outcome: no runner could launch there either.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/runner-setup.sh"
resolve_claude

# The claude flags each runner actually launches with, resolved through its own scope function (the same
# value the runner splices onto the command line), so a check on tool access reflects the real posture.
effective_scope_for() {
  case "$1" in
    scout-extract-run.sh) scout_extract_claude_scope "${CLAUDE}" ;;
    prep-run.sh) prep_claude_scope "${CLAUDE}" ;;
    reply-classify-run.sh) reply_classify_claude_scope "${CLAUDE}" ;;
  esac
}

fail() {
  echo "FAIL - $1"
  if [[ $# -gt 1 ]]; then echo "  $2"; fi
  FAILURES=$((FAILURES + 1))
}

# The prompt region, BOUNDED. The closing quote sits on a line of its own in every runner precisely so
# this range terminates. Before #856 it did not, and this whole guard was silently reading each script's
# CODE as if it were prompt text: it reported a safety it had never established.
# #1597: takes the VARIABLE NAME too, because prep-run.sh now carries a second prompt (PROBE_PROMPT, the
# reachability check, which omits the voice step so ten concurrent chunks cannot race on one file). Left
# hard-coded to PROMPT, this guard would have silently skipped it, which is precisely the #855 gap: for
# months only the scout prompt was ever checked, while prep and reply-classify were built the same way
# and nobody had looked at what they arrive as.
#
# #1710: an empty region is a FAILURE here, not an empty prompt. This helper resolves its subject
# dynamically (a sed range built from two arguments), and every such helper is one refactor away from
# matching nothing and handing back "" to a caller that reads it as "there is nothing objectionable
# in this prompt". That is not a hypothetical: #1597 gave this function a second argument and left one
# caller passing one, so for months it asked sed for a range beginning `^=`, matched nothing, and the
# #872 guard reported "asks for no skill" about all three runners, two of which name the brand-voice
# skill in their first paragraph. It was green and it was measuring nothing.
#
# The refusal lives HERE rather than in each caller, so a caller written later inherits it.
prompt_region() {
  local region
  region="$(sed -n "/^$2=/,/^\"$/p" "${SCRIPT_DIR}/$1")"
  if [[ -z "${region//[[:space:]]/}" ]]; then
    echo "no prompt region for \$$2 in $1: the range matched nothing, so every check standing on it would be reading an empty prompt and reporting it clean (#1710)" >&2
    return 1
  fi
  printf '%s\n' "${region}"
}

# What the model receives: the prompt after bash has finished with it. The runner's own variables are
# stubbed, because what is under test is the TEXT, not the paths.
expanded_prompt() {
  ( set +u
    RUNBOOK=RB; QUEUE=Q; RESULTS=R; PROGRESS=P; VOICE=V; HISTORY=H; SUPPORT=S
    eval "$(prompt_region "$1" "$2")" 2>/dev/null
    eval "printf '%s' \"\${$2}\"" )
}

# Each runner's load-bearing rules: the sentences that, if bash ate them, would cost Dan something real
# and cost it silently. Tab-separated, so a rule can contain spaces and commas.
rules_for() {
  case "$1" in
    prep-run.sh:PROBE_PROMPT)
      # #1597: the reachability check. It never drafts, so the rules that matter are the ones that keep it
      # from spending twice on one producer and the ones that keep a show from silently going unanswered.
      printf '%s\n' \
        "the never-draft rule	Do NOT draft any email" \
        "the incremental-write rule	Immediately after finishing EACH item" \
        "the never-stop-and-ask rule	never stop to ask" \
        "the rule that a naturalKey is echoed, never rebuilt	Copy each item's naturalKey verbatim" \
        "the grouping rule that stops it paying per show	research its contact ONCE" \
        "the rule that every covered show still gets its own answer	for every key listed there"
      ;;
    scout-extract-run.sh:PROMPT)
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
    prep-run.sh:PROMPT)
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
    reply-classify-run.sh:PROMPT)
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
        "the #1081 incremental-write rule	Immediately after finishing EACH item, rewrite" \
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
#
# #1682: this guard is also the one that has to prove the plugin lockout did not take Dan's skills with
# it. Restricting a detached run's settings has already done exactly that once (--setting-sources drops
# ~/.claude wholesale, brand-voice included), and the damage is invisible: the drafts still arrive, just
# not in his voice. So it must be asked of the REAL effective scope, built the way the runner builds it.
assert_tools_can_obey_the_prompt() {
  local script="$1" var="$2"
  local body region
  body="$(cat "${SCRIPT_DIR}/${script}")"
  # #1597 gave prompt_region a second argument (the prompt VARIABLE name) and this caller was not
  # updated, so every call has since asked sed for a range beginning `^=`, matched nothing, and returned
  # an empty region. An empty region contains no "skill", which took the early return below: this whole
  # guard reported "asks for no skill, so it needs no Skill tool" for all three runners, including the two
  # whose prompts name the brand-voice skill in their first paragraph. It was green and it was measuring
  # nothing.
  if ! region="$(prompt_region "${script}" "${var}")"; then
    fail "${script}: could not read the \$${var} prompt at all" \
         "every check below would have run against an empty region and reported it clean (#1710)"
    return 1
  fi

  if [[ "${region}" != *"skill"* && "${region}" != *"Skill"* ]]; then
    echo "ok - ${script}: asks for no skill, so it needs no Skill tool"
    return
  fi
  # #1097: ask the run's REAL effective scope (resolved through its scope function), not a literal flag.
  local tools
  tools="$(effective_scope_for "${script}")"
  if [[ "${tools}" == *"Skill"* ]]; then
    echo "ok - ${script}: its prompt invokes a skill AND the run is allowed the Skill tool"
  else
    fail "${script}: the prompt invokes a skill but the run cannot call one" \
         "effective scope is ${tools:-missing}. The model would silently invent Dan's voice instead."
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

for target in prep-run.sh:PROMPT prep-run.sh:PROBE_PROMPT \
              reply-classify-run.sh:PROMPT scout-extract-run.sh:PROMPT; do
  script="${target%%:*}"
  var="${target##*:}"
  echo "--- ${script} (${var})"
  if ! region="$(prompt_region "${script}" "${var}")"; then
    fail "${script}: could not read the \$${var} prompt at all" \
         "every check below would have run against an empty region and reported it clean (#1710)"
    continue
  fi

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
  expanded="$(expanded_prompt "${script}" "${var}" 2>/dev/null)"
  if [[ -z "${expanded}" ]]; then
    fail "${script}: the prompt expands to NOTHING" "bash destroyed it entirely; the model would get an empty run"
    continue
  fi
  # Matched against whitespace-normalized text. These prompts are hard-wrapped, so a rule reaches the
  # model as one sentence but sits in the file across two lines. Normalizing means a rule is asserted on
  # its WORDS, and rewrapping a paragraph can never turn this guard red for no reason (which is how a
  # noisy guard gets weakened until it stops guarding).
  expanded="$(printf '%s' "${expanded}" | tr -s '[:space:]' ' ')"

  # #1710: a target with no rule table is a target whose content is never checked, and the loop below
  # is silent about it: zero iterations reads exactly like zero failures. Counted, so adding a fifth
  # runner without writing its rules fails here instead of quietly buying it an exemption.
  rule_count=0
  while IFS=$'\t' read -r desc needle; do
    [[ -n "${desc:-}" ]] || continue
    rule_count=$((rule_count + 1))
    if [[ "${expanded}" == *"${needle}"* ]]; then
      echo "ok - ${script}: the model actually receives ${desc}"
    else
      fail "${script}: the model does NOT receive ${desc}" \
           "bash rewrote the prompt on its way out. Check for backticks, \$( ), or raw double quotes."
    fi
  done < <(rules_for "${target}")
  if [[ "${rule_count}" -eq 0 ]]; then
    fail "${target}: no load-bearing rules are listed for this prompt" \
         "rules_for has no entry for it, so nothing about what the model receives was checked (#1710)"
  else
    echo "ok - ${script}: ${rule_count} load-bearing rules were actually checked"
  fi

  assert_tools_can_obey_the_prompt "${script}" "${var}"
  assert_no_dashes "${SCRIPT_DIR}/${script}" "${script}'s prompt"
done

# The runbooks are read by the runs too, and the drafting ones are read in order to write in Dan's voice.
echo "--- the runbooks the runs read"
for book in prep-runbook.md reply-classify-runbook.md scout-extract-runbook.md; do
  assert_no_dashes "${SCRIPT_DIR}/../../docs/${book}" "docs/${book}"
done

# #1710: this guard's own refusals, seen to fire.
#
# Everything above is a check that passes when it finds nothing wrong, and the whole point of this
# issue is that such a check is indistinguishable from one finding nothing at all. So the two places
# that resolve their subject dynamically are asked to fail, here, on purpose.
echo "--- the guard's own refusals"

if prompt_region "prep-run.sh" "NO_SUCH_PROMPT" >/dev/null 2>&1; then
  fail "a prompt variable that does not exist was accepted" \
       "the sed range matched nothing and this guard would have read it as a prompt with nothing wrong in it"
else
  echo "ok - a prompt region that matches nothing is refused, not read as a clean prompt"
fi

if prompt_region "prep-run.sh" "PROMPT" >/dev/null 2>&1; then
  echo "ok - a prompt region that does exist is still read"
else
  fail "the refusal above rejects a REAL prompt too" \
       "a guard that refuses everything protects nothing, the same as one that refuses nothing"
fi

if [[ -z "$(rules_for "some-new-runner.sh:PROMPT")" ]]; then
  echo "ok - a runner with no rules listed yields none, which the loop above counts and fails on"
else
  fail "rules_for invented rules for a runner that has none listed"
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all runner prompt checks passed"
