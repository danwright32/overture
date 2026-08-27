#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

# Coverage for scripts/lib/pr-body-claims.sh (#3159): the two claims a PR body makes that only evidence
# outside the body can settle, and which of them may refuse.
#
# Both come from PR #3142, which opened with `**Dan's call, 2026-08-22: one number, and the sheet grows a
# section**` and `Closes #2967, #2968, #3076`. No comment dated 2026-08-22 exists on any of those three;
# the real calls are both dated 2026-08-21 and the PR went against them. And the Closes line closed only
# #2967, because GitHub links an issue only where the keyword immediately precedes its number, so #3076
# is open to this day holding work the body said was done.
#
# The two halves are measured differently and are therefore treated differently, which is the whole design
# and is recorded on #3159. Over the last 200 merged PRs: the keyword-fronting-a-list shape appears 4
# times and every one is the defect, so it REFUSES. A quoted decision date that matches no comment on a
# closed issue appears 12 times under a loose pattern and 8 under the tightened one, and reading them
# shows nearly all are Dan deciding in the working session rather than in a comment (#3160 says so in its
# own body, "(this session, in chat)"), so that half REPORTS and never refuses (L93).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pr-body-claims.sh
source "${SCRIPT_DIR}/pr-body-claims.sh"
set +e

FAILURES=0

# --- a keyword fronting a list leaves every number after the first unlinked ---------------------------

INCIDENT_BODY="Closes #2967, #2968, #3076.

**Dan's call, 2026-08-22: one number, and the sheet grows a section**"

assert_equals "the incident's unlinked issues are named" \
  "2968 3076" "$(pr_body_unlinked_closes "${INCIDENT_BODY}")"

assert_equals "and the one that really closes is not among them" \
  "" "$(pr_body_unlinked_closes "${INCIDENT_BODY}" | grep -w 2967)"

# Every spelling GitHub itself accepts, because a rule that knew only "Closes" would pass the same defect
# written with "Fixes" and would be worse than none: it would read as covering the class.
assert_equals "Fixes is the same shape" \
  "2842 2846" "$(pr_body_unlinked_closes "Fixes #2843, #2842, #2846")"
assert_equals "and so is Resolves, and 'and' instead of a comma" \
  "2925" "$(pr_body_unlinked_closes "Resolves #2641 and #2925")"

# The ordinary case, which is the one that must stay silent: a keyword repeated per number is what
# GitHub actually needs, and a body that mentions other issues in prose is not claiming to close them.
assert_empty "a keyword repeated per issue is correct and says nothing" \
  "$(pr_body_unlinked_closes "Closes #2967. Closes #2968.")"
assert_empty "one issue on its own says nothing" \
  "$(pr_body_unlinked_closes "Closes #3142. Refs: #2967, #2968, #3076.")"
assert_empty "and a body that closes nothing says nothing" \
  "$(pr_body_unlinked_closes "Refs #1, #2")"

# --- the issues a body really closes, which is what the date half is measured against -----------------

assert_equals "only the linked issue is treated as closed" \
  "2967" "$(pr_body_linked_closes "${INCIDENT_BODY}")"
assert_equals "a repeated keyword links both" \
  "2967
2968" "$(pr_body_linked_closes "Closes #2967. Closes #2968.")"

# --- a decision quoted with a date -------------------------------------------------------------------

assert_equals "the incident's quoted date is read" \
  "2026-08-22" "$(pr_body_decision_dates "${INCIDENT_BODY}")"
assert_equals "his call reads too" \
  "2026-08-14" "$(pr_body_decision_dates "rather than sitting quietly (his call, 2026-08-14)")"
assert_equals "and a bare Dan fronting the date, which is the second commonest form" \
  "2026-08-16" "$(pr_body_decision_dates "Dan, 2026-08-16: you can always push, no need to check with me")"
assert_equals "and a decision credited without the possessive" \
  "2026-08-11" "$(pr_body_decision_dates "\`duplicate\`, decided by Dan 2026-08-11")"

# The measured false matches, which are why the noun is required. Both of these are real merged PR
# bodies (#3059 and #2927) and both are statements ABOUT Dan rather than decisions BY him, so a pattern
# that read them would put the advisory on PRs with no claim in them at all.
assert_empty "a complaint of Dan's is not a decision quote" \
  "$(pr_body_decision_dates "Dan's 2026-08-16 complaint about a cold pitch had four parts")"
assert_empty "nor is a loop of his" \
  "$(pr_body_decision_dates "the automatic rescue of Dan's 2026-08-04 loop, a checkout parked on a branch")"
assert_empty "nor a thing he happened to do on a day" \
  "$(pr_body_decision_dates "Dan handled a reply at 2026-08-19 and the suite went red")"
assert_empty "and a body quoting no date at all says nothing" \
  "$(pr_body_decision_dates "Dan's call: one number.")"

# The plural, which is how PR #3022 wrote it: `**Dan's calls.** 2026-08-15: exclude the overlapping
# SHOWS`. Matched deliberately, and it is the one place this reading and the throwaway python one used to
# measure the rate disagreed, out of 200 bodies. The shell reading is the right one: that is a decision
# quote and the stricter word boundary missed it.
assert_equals "a plural Dan's calls is still a decision quote" \
  "2026-08-15" "$(pr_body_decision_dates "**Dan's calls.** 2026-08-15: exclude the overlapping SHOWS")"

# --- which quoted dates the evidence does not carry ---------------------------------------------------

assert_equals "a date no comment day carries is named" \
  "2026-08-22" "$(pr_body_dates_not_in_evidence "2026-08-22" "2026-08-18
2026-08-21")"
assert_empty "a date the evidence does carry is not" \
  "$(pr_body_dates_not_in_evidence "2026-08-21" "2026-08-18
2026-08-21")"
# NO evidence is not the same as evidence that disagrees, and it must not read as one: a PR that closes
# nothing, or an issue whose comments could not be fetched, has nothing to check the quote against (L98).
assert_empty "no evidence at all reports nothing rather than reporting a mismatch" \
  "$(pr_body_dates_not_in_evidence "2026-08-22" "")"

# --- the verdicts: one refuses, the other only speaks -------------------------------------------------

REFUSAL="$(require_pr_body_claims 3142 "${INCIDENT_BODY}" "2026-08-18
2026-08-21" 2>&1)"
REFUSAL_STATUS=$?
assert_equals "an unlinked Closes refuses the merge" "1" "${REFUSAL_STATUS}"
assert_contains "and names the issues that would be left open" "${REFUSAL}" "2968"
assert_contains "and the other one" "${REFUSAL}" "3076"
assert_contains "and says what to write instead" "${REFUSAL}" "Closes #"
assert_contains "and names the override rather than being a wall" "${REFUSAL}" "ALLOW_UNLINKED_CLOSES"

# The advisory rides along in the SAME output, because a refusal that swallowed it would hide the half
# that matters more: the incident shipped a contradicted decision, and left an issue open as well.
assert_contains "the date advisory speaks even while the other half refuses" \
  "${REFUSAL}" "2026-08-22"
assert_contains "and it names the days the evidence does carry" "${REFUSAL}" "2026-08-21"

ADVISORY_ONLY="$(require_pr_body_claims 3160 "Closes #2991.

**Dan's call, 2026-08-23** (this session, in chat): build the duration half." "2026-08-19" 2>&1)"
ADVISORY_STATUS=$?
assert_equals "a date mismatch on its own does NOT refuse" "0" "${ADVISORY_STATUS}"
assert_contains "it says the date is not on the issue" "${ADVISORY_ONLY}" "2026-08-23"
assert_contains "and prints the days that are, rather than only saying no" "${ADVISORY_ONLY}" "2026-08-19"
assert_contains "and says it is not blocking" "${ADVISORY_ONLY}" "not a refusal"

CLEAN="$(require_pr_body_claims 3173 "Closes #3168. Dan's call, 2026-08-21: ship it." "2026-08-21" 2>&1)"
CLEAN_STATUS=$?
assert_equals "a body whose claims hold passes" "0" "${CLEAN_STATUS}"
assert_empty "and says nothing at all" "${CLEAN}"

# The override, which exists because Dan's standing rule is that he wants one on anything, with the
# reason named in the message. It is good for the one command it is set on.
OVERRIDDEN="$(ALLOW_UNLINKED_CLOSES=1 require_pr_body_claims 3142 "${INCIDENT_BODY}" "2026-08-21" 2>&1)"
OVERRIDDEN_STATUS=$?
assert_equals "the override lets the merge through" "0" "${OVERRIDDEN_STATUS}"
assert_contains "and announces itself rather than passing silently" "${OVERRIDDEN}" "ALLOW_UNLINKED_CLOSES"

# --- the evidence is gathered over every number the Closes line names, linked or not -------------------
#
# Driven through PR_BODY_CLAIMS_GH rather than the network. It matters that the pool covers the UNLINKED
# numbers too: on the incident the decision lived on #2967 and #2968, and #2968 was one GitHub was never
# going to close.
STUB_DIR="$(mktemp -d)"
cat > "${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# args: issue view <n> --json ... --jq ...
echo "asked ${3}" >> "${STUB_LOG}"
case "${3}" in
  2967) echo "2026-08-21T18:00:00Z" ;;
  2968) echo "2026-08-21T19:30:00Z" ;;
  3076) echo "2026-08-18T12:00:00Z" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${STUB_DIR}/gh"
export STUB_LOG="${STUB_DIR}/asked.log"
: > "${STUB_LOG}"

COMPOSED="$(PR_BODY_CLAIMS_GH="${STUB_DIR}/gh" check_pr_body_claims 3142 "${INCIDENT_BODY}" 2>&1)"
COMPOSED_STATUS=$?
assert_equals "the composed check still refuses the unlinked Closes" "1" "${COMPOSED_STATUS}"
assert_contains "it asked the linked issue" "$(cat "${STUB_LOG}")" "asked 2967"
assert_contains "and the unlinked ones, which is where half the evidence lives" \
  "$(cat "${STUB_LOG}")" "asked 2968"
assert_contains "and the other unlinked one" "$(cat "${STUB_LOG}")" "asked 3076"
assert_contains "and the advisory names the real comment days it gathered" "${COMPOSED}" "2026-08-21"

# An issue whose fetch FAILS contributes nothing, and an empty pool says nothing rather than reporting a
# mismatch it did not measure (L98). Driven with a body closing only an issue the stub refuses.
SILENT="$(PR_BODY_CLAIMS_GH="${STUB_DIR}/gh" check_pr_body_claims 1 "Closes #9999. Dan's call, 2026-08-22: go." 2>&1)"
SILENT_STATUS=$?
assert_equals "a failed fetch does not fail the check" "0" "${SILENT_STATUS}"
assert_not_contains "and reports no mismatch it could not measure" "${SILENT}" "2026-08-22"
rm -rf "${STUB_DIR}"

# --- every merge path that asks the one guard asks this one too ---------------------------------------
#
# Derived from the tree rather than from a list written here, because a list only ever checks what
# somebody remembered (L96), and the failure this prevents is silent: a third merge path exists
# (merge-when-green.sh, verify-and-merge-branch.sh, verify-and-merge-batch.sh) and a check wired into two
# of them reads exactly like a check wired into all three.
#
# The subject is enumerated by the STATE the script reaches, "it refuses a PR before merging it", spelled
# as the completeness guard's own call, rather than by a filename pattern (L247).
REPO_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASKERS="$(grep -rl "require_pr_completeness \"" "${REPO_SCRIPTS}" --include='*.sh' \
  | grep -v '\.test\.sh$' | sort)"
assert_equals "there really are merge paths to check, so this is not passing over an empty list" \
  "3" "$(printf '%s\n' "${ASKERS}" | grep -c .)"

MISSING=""
while IFS= read -r script; do
  [ -n "${script}" ] || continue
  grep -q "check_pr_body_claims" "${script}" || MISSING="${MISSING} $(basename "${script}")"
done <<< "${ASKERS}"
assert_equals "and every one of them also checks the body's claims about the world" "" "${MISSING}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "pr-body-claims.test.sh: all assertions passed"
  exit 0
else
  echo "pr-body-claims.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
