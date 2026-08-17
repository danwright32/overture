#!/usr/bin/env bash
set -uo pipefail

# Coverage for the shared project-freshness judgement (#2818): the one implementation every merge path
# uses to ask "is this ref's own committed project file fresh".
#
# Two things are under test, and they are different claims (a-guard-and-its-wiring-are-two-claims).
# First, that judge_ref_project_freshness turns check-pbxproj-fresh.sh's three outcomes into three
# DIFFERENT answers, the two refusals included, since folding them together is the drift this issue
# exists to remove. Second, that both merge scripts actually route through it, because a shared helper
# nothing calls leaves the copies exactly where they were.
#
# check-pbxproj-fresh.sh itself is driven by a stand-in with the same published contract (0 fresh,
# 1 BLOCK, 2 cannot verify). The real script's own verdicts belong to its own fixture; what matters here
# is what this library DOES with each of them.

# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

FAILURES=0
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${LIB_DIR}/.." && pwd)"

# shellcheck source=./project-freshness.sh
source "${LIB_DIR}/project-freshness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/overture-freshness-2818.XXXXXX")" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/scripts" "${WORK}/mac"

cat > "${WORK}/scripts/check-pbxproj-fresh.sh" <<'FRESH'
#!/usr/bin/env bash
dir="${1:-.}"
if [ -f "${dir}/mac/CANNOT-VERIFY" ]; then
  echo "check-pbxproj-fresh: cannot verify: xcodegen version mismatch (stand-in)." >&2
  exit 2
fi
if [ -f "${dir}/mac/STALE" ]; then
  echo "check-pbxproj-fresh: BLOCK: project.pbxproj is stale (stand-in)." >&2
  exit 1
fi
echo "STAND-IN-RAN ${dir}"
exit 0
FRESH
chmod +x "${WORK}/scripts/check-pbxproj-fresh.sh"

# --- the three outcomes -------------------------------------------------------------------

FRESH_OUTPUT="$(judge_ref_project_freshness "${WORK}" "feat-fresh" 2>&1)"
assert_eq "a ref whose project file is fresh passes" "0" "$?"

# The gate has to be pointed at the ref's own checkout, not at whatever directory the merge script
# happens to be run from, or every judgement is about the wrong tree.
assert_contains "and the gate was run against that ref's own worktree" "${FRESH_OUTPUT}" "STAND-IN-RAN ${WORK}"

: > "${WORK}/mac/STALE"
STALE_OUTPUT="$(judge_ref_project_freshness "${WORK}" "feat-stale" 2>&1)"
STALE_STATUS=$?
rm -f "${WORK}/mac/STALE"
assert_eq "a ref carrying a stale project file is refused" "1" "${STALE_STATUS}"
assert_contains "the refusal names the ref" "${STALE_OUTPUT}" "feat-stale carries a stale"
assert_contains "and names the file it is about" "${STALE_OUTPUT}" "${PROJECT_FRESHNESS_PATH_REL}"
assert_contains "and says regenerating it here would only hide what lands on main" "${STALE_OUTPUT}" "#1368"
assert_contains "and gives the command that fixes it" "${STALE_OUTPUT}" "xcodegen generate"

: > "${WORK}/mac/CANNOT-VERIFY"
UNJUDGEABLE_OUTPUT="$(judge_ref_project_freshness "${WORK}" "feat-unjudgeable" 2>&1)"
UNJUDGEABLE_STATUS=$?
rm -f "${WORK}/mac/CANNOT-VERIFY"
assert_eq "a ref whose freshness cannot be judged is also refused" "1" "${UNJUDGEABLE_STATUS}"
assert_contains "but it is told apart from staleness" "${UNJUDGEABLE_OUTPUT}" "Cannot judge"
# The whole reason the two are kept apart: an unjudgeable file is this Mac's xcodegen disagreeing with
# the pin, and the stale message's remedy would send someone to regenerate a file already correct (L11).
assert_not_contains "and is never reported as a stale file, which is a different fact" \
  "${UNJUDGEABLE_OUTPUT}" "carries a stale"
assert_not_contains "nor told to regenerate anything" "${UNJUDGEABLE_OUTPUT}" "xcodegen generate"

# --- the wiring: both merge paths ask through this, and neither keeps its own copy ----------
#
# Scoped to the function that answers this question, never to the whole file (L135):
# verify-and-merge-branch.sh legitimately runs check-pbxproj-fresh.sh a second time inside
# run_full_suite, over the COMBINED tree, and a whole-file search would be satisfied by that while the
# per-ref copy sat right back where it was.
function_body() {
  awk -v name="$2" '$0 ~ "^" name "\\(\\) \\{" {inside=1} inside {print} inside && /^}$/ {exit}' "$1"
}

MWG_BODY="$(function_body "${SCRIPTS_DIR}/merge-when-green.sh" "verify_branch_pbxproj_fresh")"
assert_contains "merge-when-green asks the shared judgement" "${MWG_BODY}" "judge_ref_project_freshness"
assert_not_contains "and no longer runs the freshness gate itself" "${MWG_BODY}" "check-pbxproj-fresh.sh"

GATE_BODY="$(function_body "${LIB_DIR}/project-freshness.sh" "gate_branch_project_freshness")"
assert_contains "the per-ref gate asks the same judgement" "${GATE_BODY}" "judge_ref_project_freshness"
assert_not_contains "rather than carrying its own reading of the exit codes" "${GATE_BODY}" "-eq 2"

BRANCH_SRC="$(cat "${SCRIPTS_DIR}/verify-and-merge-branch.sh")"
assert_contains "verify-and-merge-branch sources the shared library" "${BRANCH_SRC}" "lib/project-freshness.sh"
assert_not_contains "and no longer defines the gate itself" "${BRANCH_SRC}" "gate_branch_project_freshness() {"
MWG_SRC="$(cat "${SCRIPTS_DIR}/merge-when-green.sh")"
assert_contains "merge-when-green sources it too" "${MWG_SRC}" "lib/project-freshness.sh"

# The batch path is the third caller (#2812) and reaches the gate by sourcing verify-and-merge-branch.sh,
# so what is worth asserting is that it has not grown a fourth copy of its own.
BATCH_SRC="$(cat "${SCRIPTS_DIR}/verify-and-merge-batch.sh")"
assert_not_contains "the batch path defines no freshness gate of its own" "${BATCH_SRC}" "gate_branch_project_freshness() {"
assert_not_contains "and runs no freshness gate of its own" "${BATCH_SRC}" "check-pbxproj-fresh.sh\" "

# One spelling of the file this is all about, rather than one per script: it was written out three times
# and two of those built the sentence a person acts on.
assert_not_contains "verify-and-merge-branch does not respell the generated file's path" \
  "$(function_body "${SCRIPTS_DIR}/verify-and-merge-branch.sh" "commit_merge_regeneration")" \
  "mac/Overture.xcodeproj/project.pbxproj"

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "project-freshness.test.sh: all assertions passed"
