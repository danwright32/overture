#!/usr/bin/env bash
# Is a file that steers every session close to the size at which it stops being loaded? (#3640)
#
# Claude Code loads CLAUDE.md and everything it imports into every session, and refuses a file past a
# character limit. On 2026-09-06 AGENTS.md crossed it at 150,888 characters, growing about 4,500 a
# day, and the only thing that reported the crossing was a warning Dan happened to have on screen.
# Nothing in this repository counted, and nothing could: the growth is one paragraph at a time by
# people who each add a rule and none of whom can see the total (L429).
#
# What it measures is the IMPORT GRAPH, not one named file. CLAUDE.md here is a single line, `@AGENTS.md`,
# so a check that measured the file it was pointed at would report 11 characters and pass forever
# while the file that actually loads is the one in trouble. It is also what covers a second import
# being added later, which no hand-kept list would (L96).
#
# ADVISORY. Exit 1 says a doc is close to or past the limit and does NOT fail the run: what to do
# about it is a judgement (split it, or accept it for now), and a gate on a judgement gets its
# threshold raised until it catches nothing (L93). Exit 2 is UNMEASURED and DOES fail, because a tree
# with no CLAUDE.md and a tree whose docs are all comfortably small leave the same empty result, and
# the emptiest possible failure must not read as the cleanest possible pass (L98, L11).
set -uo pipefail
# #3481/L372: captured BEFORE any cd, because $0 is the path this was INVOKED by.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${OVERTURE_STEERING_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# The platform's limit, and the point at which this starts saying so. The warning threshold is 80% of
# the limit rather than a number measured from anything: there is no distribution of "how big a rules
# file usually is" to set it from, and what makes 80% the right place is arithmetic on the growth
# rate rather than taste. At the rate measured when this was written that is roughly a week of notice,
# and it sits far above what the index weighs today, so it does not fire on the ordinary case.
LIMIT="${OVERTURE_STEERING_LIMIT:-150000}"
WARN_AT="${OVERTURE_STEERING_WARN_AT:-120000}"

unmeasured() {
  echo "check-steering-doc-size: UNMEASURED. $1"
  echo "  Nothing was weighed, so this is a failed measurement rather than a clean one."
  exit 2
}

entry="${ROOT}/CLAUDE.md"
[ -r "${entry}" ] || unmeasured "No readable CLAUDE.md at ${ROOT}."

# The graph: CLAUDE.md, plus every file it imports with a leading @. One level, because that is the
# whole of what this repo does and a deeper walk would be untested code (L535).
docs=("CLAUDE.md")
while IFS= read -r imported; do
  [ -n "${imported}" ] || continue
  # An import naming a file that is not there is the case that HIDES: CLAUDE.md is one line, so
  # measuring it and stopping would report the healthiest possible number for a session whose rules
  # never loaded at all.
  [ -r "${ROOT}/${imported}" ] || unmeasured "CLAUDE.md imports ${imported}, which is not readable."
  docs+=("${imported}")
done < <(sed -n 's/^@\([^[:space:]]*\).*/\1/p' "${entry}")

status=0
for doc in "${docs[@]}"; do
  size=$(wc -c < "${ROOT}/${doc}" | tr -d ' ')
  if [ "${size}" -ge "${LIMIT}" ]; then
    # Kept apart from the warning below on purpose: "getting close" and "already past it" call for
    # the same action and very different urgency, and one wording for both is one outcome (L11, L260).
    echo "check-steering-doc-size: ${doc} is OVER the limit at ${size} characters (limit ${LIMIT})."
    echo "  Past the limit the rules stop arriving rather than failing, and a rule that never"
    echo "  arrived is indistinguishable from one that was followed."
    status=1
  elif [ "${size}" -ge "${WARN_AT}" ]; then
    echo "check-steering-doc-size: ${doc} is ${size} characters, close to the ${LIMIT} limit."
    status=1
  else
    echo "check-steering-doc-size: ${doc} is ${size} characters, in step (limit ${LIMIT})."
  fi
done

if [ "${status}" = "1" ]; then
  echo "  Split the body of each rule into a topic file under docs/agents/ and leave the rule and a"
  echo "  pointer behind, which is what #3640 did. Advisory, so this does not fail the run."
fi
exit "${status}"
