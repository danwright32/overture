#!/usr/bin/env bash
set -uo pipefail

# Scores one settled screen against its design with the shared design match score (#4691).
#
#   scripts/design-score.sh <screen> [--design <file>] [--out <folder>] [--perturb] [--pr <number>]
#
# A build is done when it matches its settled design at 100% on BOTH halves: every decision's check met,
# and every frame's pixels within 8 levels a channel (claude-config#1364). This runs the three steps in
# order and stops at the first one that fails:
#
#   1. the DESIGN side: claude-config's web adapter draws every frame of docs/design/<screen>.html in
#      the shared Playwright's browser (`capture-web.mjs --design-only`);
#   2. the BUILT side: the screen's snapshot test, `OvertureHostedTests/DesignScoreTests/<screen>()` with
#      the name in lowerCamelCase (invoice-list is invoiceList), draws the real view for each frame from
#      fixtures/design/<screen>.json, through mac/scripts/run-tests-locked.sh and never a raw xcodebuild;
#   3. the SCORE: `design_score.py score`, whose code this exits with: 0 matched, 1 not matched yet,
#      2 no score.
#
# Anything that stops the run before the score is 2, no score, never 1: a design that could not be drawn
# or a test that failed measured nothing, and unmeasured is never "not matched yet" (L11).
#
#   --design <file>  score against another design file than docs/design/<screen>.html, relative to the
#                    checkout. The pipeline proof's route: `proof --design fixtures/design/proof.design.html`.
#   --out <folder>   where the capture goes; a fresh scratch folder by default. It must be empty or absent
#                    (a picture left from an earlier run must never be scored) and outside the checkout
#                    (a capture inside it would make every run read as uncommitted).
#   --perturb        the negative control (L1): the snapshot test draws every colour about 15 levels off,
#                    so a run that matched is seen to be able to fail. A perturbed score is never posted.
#   --pr <number>    post the score on that pull request and on its milestone's "Match the settled
#                    design" issue (`design_score.py post`), matched or not, as every pull request in a
#                    design milestone does. A score that could not be posted fails the run (2).
#
# Needs claude-config's score tools on this Mac (~/.claude/skills/design-rounds/score, which
# `claude-sync pull` brings) and the shared Playwright (`install-playwright.sh` there, once per Mac).
# The SwiftUI adapter in mac/OvertureHostedTests/DesignScore/DesignScoreCapture.swift is a verbatim copy
# of claude-config's, and a copy that has drifted is refused, with the command that refreshes it.
#
# The seams are for scripts/design-score.test.sh: DESIGN_SCORE_TOOLS, DESIGN_SCORE_NODE,
# DESIGN_SCORE_PYTHON, DESIGN_SCORE_TEST_RUNNER, DESIGN_SCORE_REPO_ROOT and DESIGN_SCORE_REPO.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/scratch.sh
source "${SCRIPT_DIR}/lib/scratch.sh"

REPO_ROOT="${DESIGN_SCORE_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
TOOLS="${DESIGN_SCORE_TOOLS:-${HOME}/.claude/skills/design-rounds/score}"
NODE="${DESIGN_SCORE_NODE:-node}"
PYTHON="${DESIGN_SCORE_PYTHON:-python3}"
TEST_RUNNER="${DESIGN_SCORE_TEST_RUNNER:-${REPO_ROOT}/mac/scripts/run-tests-locked.sh}"
GH_REPO="${DESIGN_SCORE_REPO:-danwright32/overture}"
ADAPTER_COPY="mac/OvertureHostedTests/DesignScore/DesignScoreCapture.swift"

USAGE="usage: scripts/design-score.sh <screen> [--design <file>] [--out <folder>] [--perturb] [--pr <number>]"

refuse() {
  echo "design-score: $1" >&2
  exit 2
}

# The screen's snapshot test name: its hyphenated words in lowerCamelCase.
test_name_for() {
  local screen="$1" out="" word first=1
  local IFS=-
  for word in ${screen}; do
    if [[ "${first}" -eq 1 ]]; then
      out="${word}"
      first=0
    else
      out="${out}$(printf '%s' "${word:0:1}" | tr '[:lower:]' '[:upper:]')${word:1}"
    fi
  done
  printf '%s' "${out}"
}

# A path made absolute, with symlinks in its existing part resolved, so /var and /private/var compare
# as the same place.
real_path() {
  local path="$1" dir base
  dir="$(dirname "${path}")"
  base="$(basename "${path}")"
  while [[ ! -d "${dir}" ]]; do
    base="$(basename "${dir}")/${base}"
    dir="$(dirname "${dir}")"
  done
  printf '%s/%s' "$(cd "${dir}" && pwd -P)" "${base}"
}

screen=""
design_arg=""
out=""
perturb=0
pr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --design) [[ $# -ge 2 ]] || refuse "--design needs a file. ${USAGE}"; design_arg="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || refuse "--out needs a folder. ${USAGE}"; out="$2"; shift 2 ;;
    --perturb) perturb=1; shift ;;
    --pr) [[ $# -ge 2 ]] || refuse "--pr needs a number. ${USAGE}"; pr="$2"; shift 2 ;;
    -*) refuse "unknown option $1. ${USAGE}" ;;
    *) [[ -z "${screen}" ]] || refuse "one screen at a time, and $1 is a second. ${USAGE}"; screen="$1"; shift ;;
  esac
done

[[ -n "${screen}" ]] || refuse "${USAGE}"
[[ "${screen}" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] \
  || refuse "the screen ${screen} is not lowercase words joined by hyphens, which is how its design, fixture and test are named"
[[ -z "${pr}" || "${pr}" =~ ^[0-9]+$ ]] || refuse "--pr ${pr} is not a pull request number"
if [[ "${perturb}" -eq 1 && -n "${pr}" ]]; then
  refuse "a perturbed score is the negative control, drawn wrong on purpose, and is never posted on a pull request"
fi

for tool in capture-web.mjs design_score.py swiftui/DesignScoreTests/DesignScoreCapture.swift; do
  [[ -f "${TOOLS}/${tool}" ]] \
    || refuse "claude-config's score tool ${TOOLS}/${tool} is not on this Mac; run ~/claude-config-sync/claude-sync pull"
done
if ! cmp -s "${TOOLS}/swiftui/DesignScoreTests/DesignScoreCapture.swift" "${REPO_ROOT}/${ADAPTER_COPY}"; then
  refuse "${ADAPTER_COPY} is no longer the same as claude-config's SwiftUI adapter, so the built side would be drawn by a different adapter from the one the score expects. Refresh the copy in its own commit with: cp ${TOOLS}/swiftui/DesignScoreTests/DesignScoreCapture.swift ${REPO_ROOT}/${ADAPTER_COPY}"
fi

design_rel="${design_arg:-docs/design/${screen}.html}"
design="${REPO_ROOT}/${design_rel}"
[[ "${design_arg}" == /* ]] && design="${design_arg}"
[[ -f "${design}" ]] || refuse "no settled design at ${design}; a screen is scored only once a design round settled it (the design rounds skill writes it with make-settled.py)"
fixture="${REPO_ROOT}/fixtures/design/${screen}.json"
[[ -f "${fixture}" ]] || refuse "no committed fixture at ${fixture}; both sides of the score draw that one file"

if [[ -z "${out}" ]]; then
  out="$(overture_scratch_dir "design-score-${screen}")" || refuse "could not make a scratch folder for the capture"
else
  real_out="$(real_path "${out}")"
  real_root="$(real_path "${REPO_ROOT}")"
  if [[ "${real_out}" == "${real_root}" || "${real_out}" == "${real_root}/"* ]]; then
    refuse "the capture folder ${out} is inside the checkout, which would make every run read as uncommitted; put it outside"
  fi
  if [[ -e "${out}" && -n "$(ls -A "${out}" 2>/dev/null)" ]]; then
    refuse "the capture folder ${out} already holds something, and a picture left from an earlier run must never be scored; name an empty folder"
  fi
  mkdir -p "${out}" || refuse "could not make the capture folder ${out}"
fi

commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null)" || refuse "could not read the checkout's commit at ${REPO_ROOT}"
status="$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null)"
dirty=0
[[ -n "${status}" ]] && dirty=1

echo "design-score: ${screen} against ${design_rel}, capture in ${out}"

# 1. The design side.
"${NODE}" "${TOOLS}/capture-web.mjs" --design "${design}" --out "${out}" --design-only --repo "${REPO_ROOT}"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  echo "design-score: STOPPED, no score: the design side could not be drawn (capture-web.mjs exited ${rc})." >&2
  exit 2
fi

# 2. The built side. xcodebuild hands TEST_RUNNER_<NAME> to the test as <NAME>.
test_id="OvertureHostedTests/DesignScoreTests/$(test_name_for "${screen}")()"
perturb_value=""
[[ "${perturb}" -eq 1 ]] && perturb_value=1
TEST_RUNNER_DESIGN_SCORE_CAPTURE="${out}" \
TEST_RUNNER_DESIGN_SCORE_COMMIT="${commit}" \
TEST_RUNNER_DESIGN_SCORE_DIRTY="${dirty}" \
TEST_RUNNER_DESIGN_SCORE_PERTURB="${perturb_value}" \
  "${TEST_RUNNER}" "-only-testing:${test_id}"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  echo "design-score: STOPPED, no score: the snapshot test ${test_id} failed (exited ${rc}), so the built side was not drawn. A screen with no test of that name is reported as NOTHING RAN above." >&2
  exit 2
fi

# 3. The score.
"${PYTHON}" "${TOOLS}/design_score.py" score "${out}"
score_rc=$?
if [[ "${score_rc}" -ne 0 && "${score_rc}" -ne 1 ]]; then
  echo "design-score: no score (design_score.py exited ${score_rc}); the capture is in ${out}" >&2
  exit 2
fi

if [[ -n "${pr}" ]]; then
  "${PYTHON}" "${TOOLS}/design_score.py" post "${out}/score.json" --repo "${GH_REPO}" --pr "${pr}"
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "design-score: the score was NOT POSTED on ${GH_REPO}#${pr} (design_score.py post exited ${rc}); the capture is in ${out}" >&2
    exit 2
  fi
fi

echo "design-score: the capture, with each frame's differences in red, is in ${out}"
exit "${score_rc}"
