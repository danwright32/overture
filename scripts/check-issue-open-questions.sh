#!/usr/bin/env bash
set -uo pipefail

# #3077: an issue body that still says something is unsettled after a comment settled it.
#
# The body is what anybody triaging reads. The comment thread is where decisions actually get made, and
# nothing carries the outcome back, so a later reader meets a premise that is no longer true.
#
# Measured on #2915, 2026-08-21: its body listed five things that had to be settled, Dan settled three
# of them in a comment on 2026-08-18, and the overnight review of 2026-08-20 read the body, reported
# the issue as needing "five product decisions", and set it aside as blocked on him. It was one decision
# away from buildable. A whole session's triage pointed at a stale sentence.
#
# ADVISORY, never blocking, and that is not timidity. A comment on an issue with open questions is
# usually NOT a decision (it is a note, a measurement, a link), so a gate here would fire on the
# ordinary case and be switched off within a day (L93). What this produces is a short list of PAIRS for
# a person to reconcile: body says unsettled, thread has something newer.
#
# Measured before it was built, 2026-09-04, over every open issue in this repo: 16 bodies name open
# questions and 3 of those carry a comment. Three is a list somebody reads. Had it been thirty, this
# would not be worth having.

# #3481/L372: captured BEFORE any cd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The phrases a body uses to say something is still open. Deliberately a short list of DELIBERATE
# phrasings rather than "any question mark": a body asking a rhetorical question in prose is not a body
# with an open decisions list, and matching one would bury the three real ones (L93).
ISSUE_OPEN_QUESTION_PATTERN='(?i)(open question|to decide|must be settled|needs deciding|decisions? (needed|required)|what to decide)'

# issue_open_question_pairs <json>
#
# The decision, as a pure function over the JSON `gh` returns, so it can be exercised without the
# network and without this repo's real backlog, which is a moving target (L48).
#
# Reports an issue when its body names open questions AND it carries at least one comment. It does NOT
# try to judge whether the comment IS a decision: that is the person's job, and a tool that guessed
# would be wrong in the direction that hides the real ones.
issue_open_question_pairs() {
  printf '%s' "$1" | jq -r --arg pat "${ISSUE_OPEN_QUESTION_PATTERN}" '
    [ .[]
      | select((.body // "") | test($pat))
      | select((.comments | length) > 0)
      | "#\(.number)  \(.comments | length) comment(s)  \(.title)"
    ] | .[]
  ' 2>/dev/null
}

# Everything below is the shell around it: fetching, and saying which of three things happened.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  return 0 2>/dev/null || true
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "UNMEASURED: gh is not installed, so no issue body was read. This is not a clean result."
  exit 2
fi

JSON="$(gh issue list --state open --limit 300 --json number,title,body,comments 2>/dev/null)" || JSON=""
if [ -z "${JSON}" ] || [ "${JSON}" = "[]" ]; then
  # An empty answer and a backlog with nothing to report leave the same silence, and only one of them
  # measured anything (L98).
  echo "UNMEASURED: could not read the open issues, so nothing was checked."
  exit 2
fi

PAIRS="$(issue_open_question_pairs "${JSON}")"
TOTAL="$(printf '%s' "${JSON}" | jq 'length' 2>/dev/null || echo 0)"

if [ -z "${PAIRS}" ]; then
  echo "check-issue-open-questions: no open issue names open questions and also carries a comment (${TOTAL} read)."
  exit 0
fi

echo "check-issue-open-questions: ${TOTAL} open issues read. These name open questions in the body AND"
echo "carry comments, so the body may be claiming something is unsettled that the thread has settled:"
echo
printf '%s\n' "${PAIRS}"
echo
echo "Read each and, where a comment settled something, edit the BODY to say so and point at the"
echo "comment. The thread stays as the record of how it was decided; the body is what triage reads."
exit 0
