#!/usr/bin/env bash
set -uo pipefail

# #3077: coverage for the decision inside `check-issue-open-questions.sh`.
#
# The decision is a pure function over the JSON `gh` returns, driven here against throwaway issues
# rather than against this repo's real backlog, which is a moving target and would make the fixture
# assert about whatever happened to be open that day (L48).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"
FAILURES=0

# shellcheck source=./check-issue-open-questions.sh
. "${SCRIPT_DIR}/check-issue-open-questions.sh"

BOTH='[{"number":1,"title":"Needs a call","body":"## Open questions\nOne thing to settle.","comments":[{"body":"Settled: do the first."}]}]'
assert_contains "an issue naming open questions AND carrying a comment is reported" \
  "$(issue_open_question_pairs "${BOTH}")" "#1"

# BOTH halves are required, and each is asserted alone, because a check that fired on either would
# report most of the backlog and be switched off within a day (L93).
NO_COMMENT='[{"number":2,"title":"Waiting on Dan","body":"## Open questions\nOne thing to settle.","comments":[]}]'
assert_empty "open questions with NO comment is not a pair: nothing has answered it" \
  "$(issue_open_question_pairs "${NO_COMMENT}")"

NO_QUESTIONS='[{"number":3,"title":"An ordinary bug","body":"The parser drops the last row.","comments":[{"body":"Confirmed."}]}]'
assert_empty "a comment on an issue with no open questions is not a pair" \
  "$(issue_open_question_pairs "${NO_QUESTIONS}")"

# The phrasings a body actually uses, each driven so the pattern is not one spelling somebody happened
# to think of (L217).
for phrase in "Open questions" "to decide" "must be settled" "needs deciding" "Decisions needed" "decisions required"; do
  ONE="$(printf '[{"number":9,"title":"t","body":"Something %s here.","comments":[{"body":"c"}]}]' "${phrase}")"
  assert_contains "a body saying '${phrase}' counts" "$(issue_open_question_pairs "${ONE}")" "#9"
done

# Case does not decide it: a heading is routinely capitalised and prose is not.
UPPER='[{"number":4,"title":"t","body":"OPEN QUESTION: which way round.","comments":[{"body":"c"}]}]'
assert_contains "the match is case-insensitive" "$(issue_open_question_pairs "${UPPER}")" "#4"

# A rhetorical question mark in prose is NOT an open-decisions list. This is the over-match that would
# have buried the real ones: measured 2026-09-04, 16 of the repo's open bodies name open questions
# under these phrasings, and 3 of those carry a comment. Matching every "?" would have reported most of
# the backlog.
RHETORICAL='[{"number":5,"title":"t","body":"Why does this happen? Because the fold runs twice.","comments":[{"body":"c"}]}]'
assert_empty "a question mark in prose is not an open-decisions list" \
  "$(issue_open_question_pairs "${RHETORICAL}")"

# Several at once come back as several lines, so the report is a list rather than the first hit.
MANY='[{"number":6,"title":"a","body":"Open questions","comments":[{"body":"c"}]},
       {"number":7,"title":"b","body":"to decide","comments":[{"body":"c"}]}]'
assert_equals "every pair is reported, not just the first" "2" \
  "$(issue_open_question_pairs "${MANY}" | grep -c .)"

# Malformed input answers NOTHING rather than something: an unparseable fetch and a clean backlog must
# not look the same to the caller, which is why the script prints UNMEASURED for an empty fetch and
# this returns empty for junk (L98).
assert_empty "unparseable JSON yields no pairs rather than a guess" \
  "$(issue_open_question_pairs 'not json at all')"

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all check-issue-open-questions checks passed"
