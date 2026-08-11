#!/usr/bin/env bash

# Refuses a merge whose PR body does not answer the four completeness items AGENTS.md demands.
#
# WHY THIS EXISTS. On 2026-08-10 two defects shipped from this repo and were filed as new issues
# within hours of the changes that introduced them: #2490 (a provenance case with no writer and no
# activating issue, where the same change named one for its two siblings) and #2495 (a sibling case
# scoped out without being covered). Both were visible in the diff. Both were already covered by
# rules written down in AGENTS.md and in the global lessons. #2497 then added the enumeration that
# demands those rules be ANSWERED in the PR body rather than merely stated somewhere.
#
# That left the enumeration itself as a rule nothing enforced, which is the same defect one level up:
# a rule that lives only in a prompt is a hope (L27). This is its boundary check.
#
# WHAT IT DELIBERATELY DOES NOT DO. It checks that each item is ANSWERED, never whether the answer is
# any good. Judging the substance mechanically is not possible, and a guard that scored its own
# checklist would give false assurance, which is worse than none (L96 is the same shape: a check
# driven by a registry only ever checks what the registry lists). The realistic failure is omission,
# not fabrication, and omission is exactly what this catches. It does not replace review.
#
# There is no per-change escape hatch, on purpose. The enumeration for a trivial change is three
# lines: #2497 was documentation plus one test file, and answering it still surfaced a real gap the
# author had not named. A "this one is too small" flag would be leaned on by precisely the changes
# that look small and are not.

# The four items, matched on the short phrase AGENTS.md uses for each. Kept deliberately short so
# ordinary rewording of the surrounding sentence does not trip this, while deleting the item does.
PR_COMPLETENESS_ITEMS=(
  "writer"
  "reader"
  "sibling"
  "seen"
)

# Human names for the same four, index-aligned, for the refusal message.
PR_COMPLETENESS_NAMES=(
  "a writer for every new value"
  "a reader for every new value"
  "the siblings of what was fixed"
  "the failure text for every guard"
)

# pr_completeness_missing <body>: prints the human name of each unanswered item, one per line.
# Silent (and returns 0) when every item is answered.
pr_completeness_missing() {
  local body="$1" lowered i
  # Case-insensitive so an author writing "Writers" or "Siblings" as a heading still passes; the
  # point is that the question was answered, not that it was spelled a particular way.
  lowered="$(printf '%s' "${body}" | tr '[:upper:]' '[:lower:]')"
  for i in "${!PR_COMPLETENESS_ITEMS[@]}"; do
    case "${lowered}" in
      *"${PR_COMPLETENESS_ITEMS[$i]}"*) ;;
      *) printf '%s\n' "${PR_COMPLETENESS_NAMES[$i]}" ;;
    esac
  done
}

# require_pr_completeness <pr-number> <body>: exits 1 with an explanation when anything is missing.
#
# An EMPTY body is refused by the same path rather than treated as a special case: a PR with no body
# has answered nothing, and letting it through would make "write no body at all" the way around this.
require_pr_completeness() {
  local pr_number="$1" body="$2" missing
  missing="$(pr_completeness_missing "${body}")"
  [ -n "${missing}" ] || return 0

  echo "REFUSING to merge PR #${pr_number}: its body does not answer the completeness enumeration." >&2
  echo "" >&2
  echo "Unanswered:" >&2
  # Read line by line rather than letting the shell split on spaces: every name here is several
  # words, so an unquoted expansion would print each word as its own bullet and the message meant to
  # explain the refusal would be the least readable thing on screen.
  while IFS= read -r item; do
    [ -n "${item}" ] && echo "  ${item}" >&2
  done <<< "${missing}"
  echo "" >&2
  echo "AGENTS.md requires all four in the PR body before it opens. This checks only that each was" >&2
  echo "ANSWERED, never whether the answer is any good, so passing it is not evidence the change is" >&2
  echo "complete. A gap named in the body is fine; an unnamed one is the defect this exists to catch." >&2
  echo "" >&2
  echo "Two defects shipped on 2026-08-10 that answering these would have caught: #2490 and #2495." >&2
  echo "Edit the PR body (gh pr edit ${pr_number}), then run this again." >&2
  exit 1
}
