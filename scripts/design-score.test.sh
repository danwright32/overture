#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary (#2501).
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #4691: scripts/design-score.sh, the runner that scores one settled screen against its design. Driven
# against STUBS for node, python and the test runner, in a throwaway checkout, so what is asserted is the
# runner's own logic: the order it runs the three steps in, that it stops at the first one that fails,
# that it exits with the score's own code, what it hands the snapshot test, and every refusal before
# anything runs. The real route, Chrome and xcodebuild included, was proved both ways by hand in the PR
# (100% as built, below it perturbed); a fixture cannot run it, since it needs Playwright and the lock.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/design-score.sh"

FAILURES=0

SCRATCH_REGISTRY="$(fixture_scratch_file)"
cleanup_scratch() {
  local dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    rm -rf "${dir}"
  done < "${SCRATCH_REGISTRY}"
  rm -f "${SCRATCH_REGISTRY}"
}
trap cleanup_scratch EXIT

tracked_scratch_dir() {
  local dir
  dir="$(fixture_scratch_dir)"
  echo "${dir}" >> "${SCRATCH_REGISTRY}"
  echo "${dir}"
}

# A world: a git checkout holding a design, its fixture and the adapter copy; a tools folder holding the
# score's files; and three stubs that append what they were called with to one log, in order, and exit
# with whatever code the case sets (STUB_NODE_RC, STUB_TEST_RC, STUB_SCORE_RC, STUB_POST_RC).
make_world() {
  local w
  w="$(tracked_scratch_dir)"
  mkdir -p "${w}/repo/docs/design" "${w}/repo/fixtures/design" "${w}/repo/mac/OvertureHostedTests/DesignScore"   "${w}/tools/swiftui/DesignScoreTests" "${w}/bin"
  echo "<html>design</html>" > "${w}/repo/docs/design/invoice-list.html"
  echo '{"rows": []}' > "${w}/repo/fixtures/design/invoice-list.json"
  echo "// adapter v1" > "${w}/tools/swiftui/DesignScoreTests/DesignScoreCapture.swift"
  cp "${w}/tools/swiftui/DesignScoreTests/DesignScoreCapture.swift" "${w}/repo/mac/OvertureHostedTests/DesignScore/"
  : > "${w}/tools/capture-web.mjs"
  : > "${w}/tools/design_score.py"
  git -C "${w}/repo" init -q
  git -C "${w}/repo" -c user.email=t@t -c user.name=t add -A
  git -C "${w}/repo" -c user.email=t@t -c user.name=t commit -q -m init

  cat > "${w}/bin/node" <<'STUB'
#!/usr/bin/env bash
echo "node $*" >> "${STUB_LOG}"
exit "${STUB_NODE_RC:-0}"
STUB
  cat > "${w}/bin/python" <<'STUB'
#!/usr/bin/env bash
echo "python $*" >> "${STUB_LOG}"
case "$2" in
  score) exit "${STUB_SCORE_RC:-0}" ;;
  post) exit "${STUB_POST_RC:-0}" ;;
esac
exit 9
STUB
  cat > "${w}/bin/tests" <<'STUB'
#!/usr/bin/env bash
echo "tests $* capture=${TEST_RUNNER_DESIGN_SCORE_CAPTURE:-} commit=${TEST_RUNNER_DESIGN_SCORE_COMMIT:-} dirty=${TEST_RUNNER_DESIGN_SCORE_DIRTY:-} perturb=${TEST_RUNNER_DESIGN_SCORE_PERTURB:-}" >> "${STUB_LOG}"
exit "${STUB_TEST_RC:-0}"
STUB
  chmod +x "${w}/bin/node" "${w}/bin/python" "${w}/bin/tests"
  : > "${w}/log"
  echo "${w}"
}

# Runs the runner in world $1 with any further arguments; sets OUT and RC.
run_in() {
  local w="$1"; shift
  OUT="$(cd "${w}/repo" && STUB_LOG="${w}/log" DESIGN_SCORE_REPO_ROOT="${w}/repo" DESIGN_SCORE_TOOLS="${w}/tools"   DESIGN_SCORE_NODE="${w}/bin/node" DESIGN_SCORE_PYTHON="${w}/bin/python" DESIGN_SCORE_TEST_RUNNER="${w}/bin/tests"   DESIGN_SCORE_REPO=owner/app "${RUNNER}" "$@" 2>&1)"
  RC=$?
}

# --- matched: the three steps in order, the score's code, and what the snapshot test is handed ---------
w="$(make_world)"
run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "a matched score exits 0, the score's own code" "0" "${RC}"
log="$(cat "${w}/log")"
assert_equals "the design side is drawn first" "node" "$(sed -n 1p "${w}/log" | cut -d' ' -f1)"
assert_equals "the snapshot test runs second" "tests" "$(sed -n 2p "${w}/log" | cut -d' ' -f1)"
assert_equals "the score runs last" "python ${w}/tools/design_score.py" "$(sed -n 3p "${w}/log" | cut -d' ' -f1-2)"
assert_contains "the design side is drawn from docs/design/<screen>.html into the capture folder, design only" "${log}" "--design ${w}/repo/docs/design/invoice-list.html --out ${w}/cap --design-only"
assert_contains "the snapshot test is the screen's name in lowerCamelCase, with the () Swift Testing needs" "${log}" "-only-testing:OvertureHostedTests/DesignScoreTests/invoiceList()"
assert_contains "the test is handed the capture folder, the commit, a clean checkout and no perturbation" "${log}" "capture=${w}/cap commit=$(git -C "${w}/repo" rev-parse HEAD) dirty=0 perturb="
assert_contains "the score reads the capture folder" "${log}" "score ${w}/cap"
assert_not_contains "nothing is posted without --pr" "${log}" "post"

# --- the score's other two codes pass straight through ------------------------------------------------
w="$(make_world)"
STUB_SCORE_RC=1 run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "not matched yet exits 1" "1" "${RC}"
w="$(make_world)"
STUB_SCORE_RC=2 run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "no score exits 2" "2" "${RC}"

# --- the first failure stops the run ------------------------------------------------------------------
w="$(make_world)"
STUB_NODE_RC=2 run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "a design side that could not be drawn is no score" "2" "${RC}"
assert_not_contains "and the snapshot test never runs after it" "$(cat "${w}/log")" "tests "
assert_contains "and the runner says which step stopped it" "${OUT}" "design side"
w="$(make_world)"
STUB_NODE_RC=1 run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "any failing design side is no score, never a not matched yet" "2" "${RC}"
w="$(make_world)"
STUB_TEST_RC=65 run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "a failed snapshot test is no score" "2" "${RC}"
assert_not_contains "and nothing scores the capture it left" "$(cat "${w}/log")" "score ${w}/cap"
assert_contains "and the runner says which step stopped it" "${OUT}" "snapshot test"

# --- the checkout's state is what the score records -----------------------------------------------------
w="$(make_world)"
echo "edit" >> "${w}/repo/fixtures/design/invoice-list.json"
run_in "${w}" invoice-list --out "${w}/cap"
assert_contains "uncommitted changes are handed to the test as dirty" "$(cat "${w}/log")" "dirty=1"

# --- the negative control ---------------------------------------------------------------------------
w="$(make_world)"
run_in "${w}" invoice-list --out "${w}/cap" --perturb
assert_contains "--perturb asks the snapshot test for the build drawn wrong on purpose" "$(cat "${w}/log")" "perturb=1"
w="$(make_world)"
run_in "${w}" invoice-list --out "${w}/cap" --perturb --pr 12
assert_equals "a perturbed score is never posted" "2" "${RC}"
assert_empty "and nothing runs" "$(cat "${w}/log")"

# --- posting -------------------------------------------------------------------------------------------
w="$(make_world)"
STUB_SCORE_RC=1 run_in "${w}" invoice-list --out "${w}/cap" --pr 12
assert_equals "a posted score that is not matched yet still exits 1" "1" "${RC}"
assert_contains "the score is posted on the pull request, not matched yet included" "$(cat "${w}/log")" "post ${w}/cap/score.json --repo owner/app --pr 12"
w="$(make_world)"
STUB_SCORE_RC=2 run_in "${w}" invoice-list --out "${w}/cap" --pr 12
assert_not_contains "no score is never posted" "$(cat "${w}/log")" "post"
w="$(make_world)"
STUB_POST_RC=1 run_in "${w}" invoice-list --out "${w}/cap" --pr 12
assert_equals "a score that could not be posted fails the run" "2" "${RC}"
assert_contains "and says so" "${OUT}" "NOT POSTED"

# --- refusals, before anything runs ------------------------------------------------------------------
w="$(make_world)"
run_in "${w}" missing-screen --out "${w}/cap"
assert_equals "a screen with no settled design is refused" "2" "${RC}"
assert_contains "naming the file it looked for" "${OUT}" "docs/design/missing-screen.html"
assert_empty "and nothing runs" "$(cat "${w}/log")"

w="$(make_world)"
rm "${w}/repo/fixtures/design/invoice-list.json"
git -C "${w}/repo" -c user.email=t@t -c user.name=t commit -q -am "drop fixture"
run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "a screen with no committed fixture is refused" "2" "${RC}"
assert_contains "naming the file it looked for" "${OUT}" "fixtures/design/invoice-list.json"

w="$(make_world)"
echo "// adapter v2" > "${w}/tools/swiftui/DesignScoreTests/DesignScoreCapture.swift"
run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "an adapter copy that has drifted from claude-config's is refused" "2" "${RC}"
assert_contains "with the command that refreshes it" "${OUT}" "cp ${w}/tools/swiftui/DesignScoreTests/DesignScoreCapture.swift"
assert_empty "and nothing runs" "$(cat "${w}/log")"

w="$(make_world)"
rm "${w}/tools/design_score.py"
run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "missing score tools are refused" "2" "${RC}"
assert_contains "naming how to get them" "${OUT}" "claude-sync pull"

w="$(make_world)"
mkdir -p "${w}/cap" && echo old > "${w}/cap/capture.json"
run_in "${w}" invoice-list --out "${w}/cap"
assert_equals "a capture folder already holding something is refused, so no stale picture is scored" "2" "${RC}"
assert_empty "and nothing runs" "$(cat "${w}/log")"

w="$(make_world)"
run_in "${w}" invoice-list --out "${w}/repo/cap"
assert_equals "a capture folder inside the checkout is refused, since it would make every run dirty" "2" "${RC}"

w="$(make_world)"
run_in "${w}" Invoice_List --out "${w}/cap"
assert_equals "a screen name that is not lowercase words joined by hyphens is refused" "2" "${RC}"

w="$(make_world)"
run_in "${w}" invoice-list --pr abc --out "${w}/cap"
assert_equals "a --pr that is not a number is refused" "2" "${RC}"

w="$(make_world)"
run_in "${w}"
assert_equals "no screen at all is a usage error" "2" "${RC}"
assert_contains "which prints the usage" "${OUT}" "usage"

# --- --design names another file, the proof's route -------------------------------------------------
w="$(make_world)"
echo "<html>proof</html>" > "${w}/repo/fixtures/design/proof.design.html"
echo '{}' > "${w}/repo/fixtures/design/proof.json"
git -C "${w}/repo" -c user.email=t@t -c user.name=t add -A
git -C "${w}/repo" -c user.email=t@t -c user.name=t commit -q -m proof
run_in "${w}" proof --design fixtures/design/proof.design.html --out "${w}/cap"
assert_equals "--design scores a screen against a design outside docs/design" "0" "${RC}"
assert_contains "resolved against the checkout" "$(cat "${w}/log")" "--design ${w}/repo/fixtures/design/proof.design.html"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All design-score.sh fixtures passed."
else
  echo "${FAILURES} design-score.sh fixture(s) FAILED."
  exit 1
fi
