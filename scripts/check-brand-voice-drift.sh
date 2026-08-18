#!/usr/bin/env bash
set -euo pipefail

# Warns when docs/prep-runbook.md and the external dan-wright-brand-voice skill drift apart on the
# facts they BOTH state (#731). The AI drafting instructions the Prep run follows live in two
# places: this repo's docs/prep-runbook.md §2, and the dan-wright-brand-voice skill at
# ~/.claude/skills/dan-wright-brand-voice/ (SKILL.md + references/email-and-alt-text.md), which is
# NOT tracked by this repo at all. The #365 and #362 fixes each required matching hand-edits in
# both places, and nothing caught it if you edited only one. The skill is authoritative per the
# runbook ("INVOKE the skill and follow it... the skill always wins"), so a stale runbook copy can
# quietly mislead anyone reading it as the source of truth.
#
# This is a documented, repeatable LOCAL check, not a CI gate: the skill lives outside the clone,
# so CI (and any machine without the skill installed) simply can't compare. main() skips cleanly
# there. The pure comparison (brand_voice_drift) is covered by check-brand-voice-drift.test.sh,
# which runs everywhere.
#
# Usage: scripts/check-brand-voice-drift.sh [runbook-path] [skill-dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The concrete facts both sources state today. Each MUST appear in both the runbook and the skill;
# a fact present on one side but not the other is drift. Deliberately NOT word-for-word (a reword
# or a line wrap must not trip it). These are the credential, venue, portfolio, opener-shape, and
# soft-close facts the #365/#362 fixes had to keep in sync by hand, plus, since #2874, the rate
# answer's own facts.
#
# The rate used to be excluded here on the stated ground that it "lives only in the runbook by
# design, since the skill defers specifics to it". That stopped being true on 2026-08-17: Dan's
# answer to "what do you charge" is now fixed text reproduced VERBATIM, and the skill holds the
# canonical copy. Two sources holding one paragraph word for word is precisely the situation this
# check exists for, and the cost of it drifting is higher than for anything else on this list,
# because these sentences are sent to a stranger under Dan's name and each one answers an objection
# to the price. An anchor that goes missing on one side means somebody edited the answer in one
# place, which is the one thing that must not happen quietly.
BRAND_VOICE_ANCHORS=(
  "nearly 10 years"
  "Madison Square Garden"
  "Lincoln Center"
  "Radio City Music Hall"
  "danwrightphotography.com"
  "reason-first"
  "direct-intent"
  # Dan, 2026-07-31: sentence one always introduces him, by name and by trade. This replaced an earlier
  # instruction NOT to lead with his name, which was invented to manufacture variety and produced openers
  # that started talking before saying who was talking. Both sources must carry it or one side reverts.
  "My name is Dan"
  # Dan, 2026-07-31: the close expects a reply. It replaced "Happy to answer any questions" (now on the
  # rejected list below), which asked the reader to invent a question after the email had already given
  # them the rate, the turnaround and the ask.
  "look forward to hearing from you"
  # Dan, 2026-07-31: the ask presupposes they HAVE photography plans, rather than asking whether they want
  # photography at all. The presupposition is the point, not the wording: a yes/no offer invites a no.
  "photography plans"
  # #2807: within-draft variety, the one axis no rule governed. Every drafting rule here is scoped to ONE
  # sentence and supplies its own canonical phrasing, so stacked back to back they produce an email of a
  # single shape, which is what Dan heard on 2026-08-16. Both halves are anchors because they are separate
  # instructions that fail differently: drop the first and the constructions stack again, drop the second
  # and the body goes back to one block. The second half is the older of the two ("Short paragraphs" has
  # been in the skill's opening line all along) and had never been stated in the runbook at all, which is
  # exactly the one-sided state this check exists to name.
  "no two sentences in a row"
  "short paragraphs"
  # #1824: describe Dan, never categorize the recipient. The phrase that broke this rule ("working with
  # performing arts organizations in New York", sent to one singer-songwriter) was in neither source, which
  # is precisely why the rule now has to be in BOTH: a model with no instruction either way will assemble
  # one from Dan's identity line again.
  "never categorize the recipient"
  # #2874: the rate answer, fact by fact. Single-quoted where the text carries a dollar sign, because
  # "$250" inside double quotes expands as positional parameter $2 and would silently anchor on
  # "50/hr plus tax" instead.
  'two paragraphs, VERBATIM'
  '$250/hr plus tax'
  "minimum of one hour"
  "tax exempt"
  "no charge for time spent editing"
  "within 2 weeks"
  "no extra or hidden fees"
  "black and white edits"
  "named, never priced"
  "high and web-resolution"
  "full usage rights"
)

# #1227: phrases Dan has SUPERSEDED. Unlike an anchor (a fact that must appear on both sides), a rejected
# phrase must appear in the skill ONLY as a negative instruction. "let me know how that lands" was the old
# soft close, replaced by "Happy to answer any questions" (Dan flagged the old one as reading douchey,
# 2026-07-18). It stays on this list, not the anchor list: the anchor is now the REPLACEMENT, and this
# guards against the rejected one being re-endorsed anywhere inside the skill.
BRAND_VOICE_REJECTED=(
  "let me know how that lands"
  # Dan, 2026-07-31: the old soft close, retired because inviting questions makes the reader do the work
  # of inventing one. It was an ANCHOR until today, which is exactly why it moves here rather than simply
  # being deleted: once both sources mention it only to retire it, a presence-only anchor passes
  # vacuously and can no longer tell an endorsement from a rejection (the #1227 trap).
  "Happy to answer any questions"
  # Dan, 2026-07-31: two retired opener shapes, anchors until today for the same reason. Credential-first
  # led with venues before the reader knew what Dan does, which sentence one now owns. Observation-first
  # had only the show's own material to observe, which "name the show, describe nothing" forbids, and with
  # that gone it reached for scarcity instead.
  "credential-first"
  "observation-first"
  # #1832: the five galleries. Dan's call, 2026-07-30, is one link in every draft, the site itself, and
  # the reader clicks into whichever portfolio they want. These were ANCHORS under #1405 (a fact both
  # sources had to state); they are rejected phrases now, so either side re-endorsing one is caught
  # instead of quietly reinstating a per-discipline link the other side no longer knows about.
  "danwrightphotography.com/music"
  "danwrightphotography.com/bands"
  "danwrightphotography.com/comedy"
  "danwrightphotography.com/dance"
  "danwrightphotography.com/performing-arts"
)

# Collapses every run of whitespace (including newlines) to a single space and lowercases, so a
# line-wrapped or differently-cased anchor still matches. Without this, "Lincoln Center" wrapped
# across a line break in the runbook reads as missing (see the test's `wrapped` case).
_normalize_text() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' '
}

# Given the runbook text ($1) and the combined skill text ($2), prints one line per drifted anchor
# naming the side missing it, and returns the number of drift lines (0 means fully in sync). Pure:
# takes text, touches no files, so it's driven directly by the test against throwaway content.
brand_voice_drift() {
  local runbook_norm skill_norm anchor anchor_norm drift=0
  runbook_norm="$(_normalize_text "$1")"
  skill_norm="$(_normalize_text "$2")"
  for anchor in "${BRAND_VOICE_ANCHORS[@]}"; do
    anchor_norm="$(_normalize_text "${anchor}")"
    if [[ "${runbook_norm}" != *"${anchor_norm}"* ]]; then
      echo "DRIFT: \"${anchor}\" missing from runbook (docs/prep-runbook.md)"
      drift=$((drift + 1))
    fi
    if [[ "${skill_norm}" != *"${anchor_norm}"* ]]; then
      echo "DRIFT: \"${anchor}\" missing from skill (dan-wright-brand-voice)"
      drift=$((drift + 1))
    fi
  done
  return "${drift}"
}

# A line that mentions a superseded phrase must carry a negation near it. The line is passed already
# lowercased. Deliberately a handful of plain tokens, not a clever parser: the skill's instructions phrase
# a rejection as "never X" / "not X" / "avoid X" / "don't X" / "no longer X".
_line_negates() {
  local line="$1"
  [[ "${line}" == *never* || "${line}" == *"not "* || "${line}" == *avoid* \
     || "${line}" == *"don't"* || "${line}" == *"no longer"* ]]
}

# #1227: catch a contradiction WITHIN the skill, not just runbook-vs-skill drift. The skill states its
# guidance in two places, SKILL.md's quick reference and references/*.md, and during #1215 SKILL.md still
# ENDORSED the "let me know how that lands" soft close that its own references (and the runbook, and Dan)
# had already rejected. The presence-only drift check passed because the phrase was present on both sides;
# it could not tell an endorsement from a rejection. Here a superseded phrase (BRAND_VOICE_REJECTED) may
# appear in either skill file ONLY on a line that also negates it; an un-negated occurrence is one file
# endorsing what the other rejects. Pure: takes the two files' text, so the test drives it directly.
intra_skill_contradiction() {
  local -a labels=("SKILL.md" "references")
  local -a texts=("$1" "$2")
  local phrase phrase_norm i text label line line_norm contradiction=0
  for phrase in "${BRAND_VOICE_REJECTED[@]}"; do
    phrase_norm="$(_normalize_text "${phrase}")"
    for i in 0 1; do
      text="${texts[$i]}"
      label="${labels[$i]}"
      while IFS= read -r line; do
        line_norm="$(_normalize_text "${line}")"
        [[ "${line_norm}" == *"${phrase_norm}"* ]] || continue
        if ! _line_negates "${line_norm}"; then
          echo "CONTRADICTION: superseded phrase \"${phrase}\" is endorsed (not negated) in the skill's ${label}"
          contradiction=$((contradiction + 1))
        fi
      done <<< "${text}"
    done
  done
  return "${contradiction}"
}

main() {
  local runbook="${1:-${REPO_ROOT}/docs/prep-runbook.md}"
  local skill_dir="${2:-${HOME}/.claude/skills/dan-wright-brand-voice}"
  local skill_md="${skill_dir}/SKILL.md"
  local skill_email="${skill_dir}/references/email-and-alt-text.md"

  if [[ ! -f "${runbook}" ]]; then
    echo "ERROR: runbook not found at ${runbook}" >&2
    exit 2
  fi

  # The skill lives outside this repo. On a machine or CI runner without it installed, we can't
  # compare, so say so plainly and exit clean rather than reporting a false drift.
  if [[ ! -f "${skill_md}" || ! -f "${skill_email}" ]]; then
    echo "SKIPPED: dan-wright-brand-voice skill not installed at ${skill_dir}; cannot verify drift."
    exit 0
  fi

  local runbook_text skill_md_text skill_email_text skill_text
  local drift_lines drift_status contradiction_lines contradiction_status
  runbook_text="$(cat "${runbook}")"
  skill_md_text="$(cat "${skill_md}")"
  skill_email_text="$(cat "${skill_email}")"
  skill_text="${skill_md_text}"$'\n'"${skill_email_text}"

  set +e
  drift_lines="$(brand_voice_drift "${runbook_text}" "${skill_text}")"
  drift_status=$?
  # #1227: SKILL.md and references compared SEPARATELY here (not the combined blob the drift check uses),
  # so an endorsement in one and a rejection in the other is visible.
  contradiction_lines="$(intra_skill_contradiction "${skill_md_text}" "${skill_email_text}")"
  contradiction_status=$?
  set -e

  if [[ "${drift_status}" -eq 0 && "${contradiction_status}" -eq 0 ]]; then
    echo "OK: docs/prep-runbook.md and the dan-wright-brand-voice skill agree on all ${#BRAND_VOICE_ANCHORS[@]} anchor facts, and the skill is internally consistent."
    exit 0
  fi

  [[ -n "${drift_lines}" ]] && echo "${drift_lines}"
  [[ -n "${contradiction_lines}" ]] && echo "${contradiction_lines}"
  echo
  echo "The brand-voice sources are out of sync. Update them so the fact matches; the skill is the"
  echo "authoritative source (docs/prep-runbook.md §2 says the skill always wins), and its own SKILL.md"
  echo "summary must never endorse a phrase its references reject."
  exit 1
}

# Sourceable without running (the test sources this to drive brand_voice_drift directly). Mirrors
# the convention in merge-when-green.sh and check-pr-ci.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
