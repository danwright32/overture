#!/usr/bin/env bash

# The two claims a PR body makes that only evidence OUTSIDE the body can settle (#3159).
#
# `pr-completeness-guard.sh` beside this one already refuses a body that does not ANSWER the four
# enumerations, and deliberately never judges whether an answer is any good, because judging substance
# mechanically is not possible. These two are the exceptions: both are claims about the world, and both
# can be checked against it cheaply.
#
# WHY THIS EXISTS. PR #3142 opened with `Closes #2967, #2968, #3076` and
# `**Dan's call, 2026-08-22: one number, and the sheet grows a section**`, and merged. There is no
# comment dated 2026-08-22 on any of those three issues; the real calls are both dated 2026-08-21, and
# the PR went against both of them. Its tests then shipped asserting the superseded behaviour, so the
# guard defended it (L252). The same body closed only #2967, and #3076 is open today holding work the
# body said was done.
#
# THE TWO HALVES HAVE DIFFERENT VERDICTS, and that is the whole design rather than caution. Both were
# measured over the last 200 merged PRs before either was written, and they came out very differently.
#
#   The CLOSES half refuses. GitHub links an issue only where the keyword immediately precedes its
#   number, so `Closes #a, #b, #c` closes exactly one issue and silently references the rest. The shape
#   appears 4 times in 200 PRs (#3146, #3142, #2851, #2848) and every one of the four is the defect: two
#   left an issue open that is still open, and the other six were closed by hand days later, within
#   seconds of each other, which is somebody having noticed. No judgement is involved, so it can refuse.
#
#   The DATE half only reports. 39 of those 200 bodies quote a decision with a date, and 12 quote one
#   that matches no comment day on any issue they close. Reading those 12 settles it: nearly all are
#   correct, because most of Dan's calls are made in the working session and not in a comment. #3160
#   says so in its own body ("(this session, in chat)"), #3114's decision lives on an issue the PR does
#   not close, and #3164 quotes a session call that CONFIRMS an earlier comment. A gate there would
#   refuse about one PR in five and be right about one of them, which is a gate somebody switches off in
#   a day (L93). Tightening the attribution to require a decision noun brings it to 8 in 200, which is a
#   fine rate for a line of output and still names the incident exactly.
#
# What it prints for the incident is the whole point: the quoted date beside the days the evidence really
# carries, so the author can go and look. It never says the author is wrong, because it cannot know.

# The keywords GitHub itself closes an issue on. Written out rather than matched loosely, because the
# whole claim being checked is what GitHub will do with the line.
PR_CLOSES_KEYWORDS='(clos(e|es|ed)|fix(e|es|ed)?|resolv(e|es|ed))'

# pr_body_linked_closes <body>: the issue numbers this body will really close, one per line.
#
# Only where the keyword immediately precedes the number, which is GitHub's own rule.
pr_body_linked_closes() {
  printf '%s\n' "$1" \
    | grep -oiE "(^|[^a-z])${PR_CLOSES_KEYWORDS}[[:space:]]+#[0-9]+" \
    | grep -oE '[0-9]+'
}

# pr_body_unlinked_closes <body>: for each keyword fronting a LIST, the numbers after the first, space
# separated, one line per list.
#
# Space separated rather than one per line because they belong together: they are the issues one
# sentence claims and GitHub will not close, and the refusal quotes them as the sentence's own tail.
pr_body_unlinked_closes() {
  printf '%s\n' "$1" \
    | grep -oiE "(^|[^a-z])${PR_CLOSES_KEYWORDS}[[:space:]]+#[0-9]+([[:space:]]*(,|and)[[:space:]]*#[0-9]+)+" \
    | while IFS= read -r chunk; do
        printf '%s' "${chunk}" | grep -oE '#[0-9]+' | sed 's/#//' | tail -n +2 | tr '\n' ' ' | sed 's/ $//'
        echo
      done
}

# The nouns that make a mention of Dan a DECISION rather than a fact about him.
#
# Required, and this is the part that was measured rather than guessed. Without a noun the pattern reads
# `Dan's 2026-08-16 complaint` (PR #3059) and `the automatic rescue of Dan's 2026-08-04 loop` (PR #2927)
# as quoted decisions, and puts an advisory on PRs making no such claim at all. `Dan,` and `Dan (`
# fronting a date directly are kept because that is the second commonest form Dan's calls are written in
# here, and nothing else is written that way.
PR_DECISION_NOUNS='(call|decision|rule|spec|question|ruling|verdict)'

# pr_body_decision_dates <body>: every date this body attributes a decision to, sorted, one per line.
pr_body_decision_dates() {
  printf '%s\n' "$1" \
    | grep -oiE "(^|[^a-z])(dan'?s[[:space:]]+${PR_DECISION_NOUNS}|his[[:space:]]+${PR_DECISION_NOUNS}|decided[[:space:]]+by[[:space:]]+dan|dan[[:space:]]*[,(])[^0-9]{0,24}[0-9]{4}-[0-9]{2}-[0-9]{2}" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | sort -u
}

# pr_body_dates_not_in_evidence <dates> <days>: the quoted dates no comment day carries.
#
# EMPTY evidence prints nothing, deliberately. A PR that closes no issue, and an issue whose comments
# could not be fetched, both arrive here as an empty list, and reporting a mismatch on either would be
# the emptiest possible failure reading as the strongest possible finding (L98). Nothing was measured, so
# nothing is said.
pr_body_dates_not_in_evidence() {
  local dates="$1" days="$2" date
  [ -n "${days}" ] || return 0
  while IFS= read -r date; do
    [ -n "${date}" ] || continue
    printf '%s\n' "${days}" | grep -qxF "${date}" || printf '%s\n' "${date}"
  done <<< "${dates}"
}

# require_pr_body_claims <pr-number> <body> <comment-days>
#
# `comment-days` is one yyyy-mm-dd per line: every day carrying a comment on any issue the body closes.
# The caller fetches them, so this stays a pure decision a fixture can drive without a network.
#
# Returns 1 only for the CLOSES half. The date half always prints and never decides.
require_pr_body_claims() {
  local pr_number="$1" body="$2" days="${3:-}" unlinked quoted missing verdict=0

  unlinked="$(pr_body_unlinked_closes "${body}")"
  quoted="$(pr_body_decision_dates "${body}")"
  missing="$(pr_body_dates_not_in_evidence "${quoted}" "${days}")"

  if [ -n "${unlinked}" ]; then
    if [ -n "${ALLOW_UNLINKED_CLOSES:-}" ]; then
      echo "PR #${pr_number}: ALLOW_UNLINKED_CLOSES is set, so the unlinked Closes numbers ($(printf '%s' "${unlinked}" | tr '\n' ' ')) are not refused." >&2
      echo "GitHub will still close only the first of each list. Close the rest by hand after merging." >&2
    else
      echo "REFUSING to merge PR #${pr_number}: its Closes line claims issues GitHub will not close." >&2
      echo "" >&2
      echo "Left open despite being claimed:" >&2
      while IFS= read -r line; do
        [ -n "${line}" ] || continue
        for number in ${line}; do echo "  #${number}" >&2; done
      done <<< "${unlinked}"
      echo "" >&2
      echo "GitHub links an issue only where the keyword immediately precedes its number, so one keyword" >&2
      echo "in front of a comma separated list closes exactly one issue and silently references the rest." >&2
      echo "Write the keyword before each: 'Closes #1. Closes #2.'" >&2
      echo "" >&2
      echo "PR #3142 did this and #3076 is open today holding work its body said was done." >&2
      echo "Edit the PR body (gh pr edit ${pr_number}), then run this again." >&2
      echo "Override for one command with ALLOW_UNLINKED_CLOSES=1, which announces itself." >&2
      verdict=1
    fi
  fi

  # Printed whatever the verdict above, because the incident was BOTH at once and a refusal that
  # swallowed this would hide the half that shipped a contradicted decision.
  if [ -n "${missing}" ]; then
    echo "" >&2
    echo "PR #${pr_number} quotes a decision on a date that no comment on the issues it closes carries." >&2
    echo "" >&2
    while IFS= read -r date; do
      [ -n "${date}" ] && echo "  quoted:    ${date}" >&2
    done <<< "${missing}"
    printf '  comments:  %s\n' "$(printf '%s' "${days}" | sort -u | tr '\n' ' ' | sed 's/ $//')" >&2
    echo "" >&2
    echo "This is a report and not a refusal: most of Dan's calls are made in the working session rather" >&2
    echo "than in a comment, and a body quoting one of those is right. It is printed because the one time" >&2
    echo "it was wrong (PR #3142) the quoted date was a day later than the two real calls, the PR went" >&2
    echo "against both, and its tests shipped defending what had been rejected. Check the date against the" >&2
    echo "issue before merging." >&2
  fi

  return "${verdict}"
}

# pr_body_claims_comment_days <issue-number>...: every day carrying a comment on any of them, one
# yyyy-mm-dd per line, in BOTH UTC and this machine's own timezone.
#
# Both, because the quote is written in Dan's local day and GitHub records UTC: a call made at nine in
# the evening in New York is stamped the next day, and a check that knew only one of the two would report
# a mismatch on every evening decision (L39 is the same trap the other way round).
#
# The issue's own creation day counts: a decision is routinely stated in the issue body that asks for it.
#
# A fetch that FAILS contributes nothing for that issue rather than failing the check, and an empty pool
# then makes the advisory silent by `pr_body_dates_not_in_evidence`'s own rule. That is the honest
# direction here: this half never refuses anything, so the cost of saying nothing is a line of output,
# and the cost of speaking from a failed fetch is an accusation built on no evidence (L119).
#
# PR_BODY_CLAIMS_GH is the seam a fixture drives instead of the network. It defaults to the plain `gh`
# rather than to this repo's `gh_as_danwright32`, because that helper lives in ci-config.sh and every
# caller of this function has already sourced it: a caller that wants the scoped identity sets the
# variable to it, and one that does not still works.
pr_body_claims_comment_days() {
  local issue ts
  [ "$#" -gt 0 ] || return 0
  for issue in "$@"; do
    [ -n "${issue}" ] || continue
    "${PR_BODY_CLAIMS_GH:-gh}" issue view "${issue}" --json createdAt,comments \
      --jq '[.createdAt] + [.comments[].createdAt] | .[]' 2>/dev/null
  done | while IFS= read -r ts; do
    [ -n "${ts}" ] || continue
    printf '%s\n' "${ts%%T*}"
    date -jf '%Y-%m-%dT%H:%M:%SZ' "${ts}" '+%Y-%m-%d' 2>/dev/null
  done | sort -u
}

# check_pr_body_claims <pr-number> <body>: the whole check, evidence and all.
#
# The evidence is gathered over EVERY issue number the Closes line names, linked or not. That is
# deliberate: on the incident the decision being quoted lived on #2967 and #2968, and #2968 was one of
# the numbers GitHub was never going to close, so a pool built from the linked issues alone would have
# been missing half of the very evidence the report exists to print.
check_pr_body_claims() {
  local pr_number="$1" body="$2" numbers days
  numbers="$(
    { pr_body_linked_closes "${body}"
      pr_body_unlinked_closes "${body}" | tr ' ' '\n'
    } | grep -E '^[0-9]+$' | sort -u
  )"
  # Unquoted on purpose: the numbers are one per line and each is its own argument here.
  # shellcheck disable=SC2086
  days="$(pr_body_claims_comment_days ${numbers})"
  require_pr_body_claims "${pr_number}" "${body}" "${days}"
}
