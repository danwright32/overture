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
#
# THE ONE EXEMPTION (#2822), and why it is not that flag. A bot-authored PR can never answer the
# enumeration, so dependabot's bumps accumulated unmerged and the dependencies went stale: measured
# 2026-08-16, #2752 and #2753 were both refused with all four items named, and the only workaround was a
# person answering completeness questions on a bot's behalf for a change with no new values in it. That
# is the shape of a gate people learn to route around, and this gate is worth keeping sharp.
#
# So the condition is narrow, stated, and BOTH halves are required: a known bot author AND a diff that
# touches nothing but dependency manifests. A bot PR that touched source still has new values in it and
# still needs the enumeration. It ANNOUNCES itself rather than passing silently, so a mis-scoped rule is
# visible in the output instead of quietly waving PRs through.

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

# The bot authors this repo actually receives PRs from, named rather than matched on "bot" anywhere in
# the login: a pattern would exempt a human whose username happens to contain it, and the cost of being
# wrong here is a real change merging with nothing answered.
PR_COMPLETENESS_BOT_AUTHORS=(
  "dependabot[bot]"
  "app/dependabot"
  "renovate[bot]"
  "app/renovate"
)

# The files a dependency bump may touch, and nothing else. A lockfile and its manifest, per ecosystem
# this repo has or plausibly gains. Deliberately NOT a glob like `*.json`, and deliberately not
# `.github/workflows/`, which is source: a workflow change decides what runs on every PR.
PR_COMPLETENESS_DEPENDENCY_FILES=(
  "package.json"
  "package-lock.json"
  "pnpm-lock.yaml"
  "yarn.lock"
  "Package.swift"
  "Package.resolved"
  "Gemfile"
  "Gemfile.lock"
)

# pr_completeness_exemption <author> <changed-files>: prints the REASON this PR is exempt, or nothing.
#
# `changed-files` is one path per line. An EMPTY list is never exempt, which matters more than it looks:
# an empty answer is what a failed `gh` call returns, and treating it as "touched no source" would exempt
# every bot PR whatever it actually changed (L98). The refusal direction is the safe one here.
pr_completeness_exemption() {
  local author="$1" files="$2" known="" file match known_author allowed

  [ -n "${author}" ] || return 0
  [ -n "${files}" ] || return 0

  for known_author in "${PR_COMPLETENESS_BOT_AUTHORS[@]}"; do
    [ "${author}" = "${known_author}" ] && known="yes"
  done
  [ -n "${known}" ] || return 0

  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    match=""
    for allowed in "${PR_COMPLETENESS_DEPENDENCY_FILES[@]}"; do
      # Matched on the BASENAME, so a manifest in a subdirectory counts and a source file named after
      # one does not sneak in by path.
      [ "${file##*/}" = "${allowed}" ] && match="yes"
    done
    [ -n "${match}" ] || return 0
  done <<< "${files}"

  printf 'the author is %s and the diff touches only dependency manifests (%s)\n' \
    "${author}" "$(printf '%s' "${files}" | tr '\n' ' ' | sed 's/ $//')"
}

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
  local pr_number="$1" body="$2" author="${3:-}" files="${4:-}" missing exemption
  missing="$(pr_completeness_missing "${body}")"
  [ -n "${missing}" ] || return 0

  # #2822: the one exemption, announced rather than silent. Asked only once the body has already
  # failed, so an exempt PR that DID answer the enumeration passes for the ordinary reason and this
  # says nothing about it.
  exemption="$(pr_completeness_exemption "${author}" "${files}")"
  if [ -n "${exemption}" ]; then
    echo "PR #${pr_number} is exempt from the completeness enumeration: ${exemption}" >&2
    return 0
  fi

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
