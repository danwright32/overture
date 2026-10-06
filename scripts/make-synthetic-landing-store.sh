#!/usr/bin/env bash
set -uo pipefail

# #4338 (A10): writes a SYNTHETIC Overture store into a named folder, so a scout landing can be LOOKED at, in
# every state, at the real scale (L606), without a single real name on screen (L222, L155).
#
# What it writes (`SyntheticLandingStore`, in the test target, run through the one opt-in writer): 39 watched
# sources and 1,350 shows, every title, presenter, venue and client drawn from the A1 synthetic arm's invented
# vocabulary, and a landing record in each state that lives in records: a landing waiting to be finished at
# idle (whose kept results are also over a day old, so stuck), one the recovery stopped trying, a landing record
# nobody can read, kept results the launch sweep lands, and kept results that had already landed. Never a clone
# of the live store: this is a public repository.
#
# The folder is refused by the same rule `mac/scripts/run-debug.sh --store-folder` refuses it by (sourced from
# there, so the two cannot differ): never the live Release folder, never the default Debug one, nothing inside
# either and nothing holding either. It must exist, and must not hold a store already: this never writes over one.
#
# Then open it with: mac/scripts/run-debug.sh --store-folder <folder>
#
# Usage: scripts/make-synthetic-landing-store.sh <folder>
# Exit codes: 0 written. 1 the folder was refused. 2 UNMEASURED, the writer failed or wrote no store. 64 usage.
# Seams, for the fixture: OVERTURE_SYNTHETIC_STORE_RUNNER replaces the test runner, and
# OVERTURE_SYNTHETIC_STORE_APP_SUPPORT the Application Support folder whose two stores are refused.

SYNTHETIC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNTHETIC_REPO_ROOT="$(cd "${SYNTHETIC_SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/scratch.sh
. "${SYNTHETIC_SCRIPT_DIR}/lib/scratch.sh"
# The refusal, from run-debug.sh itself (sourceable without running its main).
# shellcheck source=../mac/scripts/run-debug.sh
source "${SYNTHETIC_REPO_ROOT}/mac/scripts/run-debug.sh"
set +e

RUNNER="${OVERTURE_SYNTHETIC_STORE_RUNNER:-${SYNTHETIC_REPO_ROOT}/mac/scripts/run-tests-locked.sh}"
APP_SUPPORT="${OVERTURE_SYNTHETIC_STORE_APP_SUPPORT:-${HOME}/Library/Application Support}"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "Usage: scripts/make-synthetic-landing-store.sh <folder>" >&2
  exit 64
fi

FOLDER="$(resolve_store_folder "$1" "${APP_SUPPORT}")" || exit 1
if [[ -e "${FOLDER}/Overture.store" ]]; then
  # The writer writes its report LAST, so a store with no report beside it is what a run stopped part way
  # leaves. It is still never written over; the refusal names the way out instead (L406).
  if [[ ! -s "${FOLDER}/synthetic-store-report.txt" ]]; then
    echo "Refusing: ${FOLDER} holds a store with no report beside it, which is what a writer run stopped part way leaves. This never writes over a store: delete that folder, or name an empty one, and run this again." >&2
  else
    echo "Refusing: ${FOLDER} already holds a store, and this never writes over one. Name an empty folder." >&2
  fi
  exit 1
fi

LOG="$(overture_scratch_file synthetic-landing-store)" || {
  echo "UNMEASURED: no scratch file could be made for the writer's log, so nothing was run." >&2
  exit 2
}
trap 'rm -f "${LOG}"' EXIT

echo "make-synthetic-landing-store: writing 39 sources and 1,350 invented shows into ${FOLDER}"
TEST_RUNNER_OVERTURE_SYNTHETIC_STORE_OUT="${FOLDER}" \
  "${RUNNER}" -only-testing:OvertureTests/SyntheticLandingStoreWriter > "${LOG}" 2>&1
status=$?

if [[ ${status} -ne 0 ]]; then
  echo "UNMEASURED: the writer run failed (exit ${status}), so no store was written." >&2
  tail -25 "${LOG}" >&2
  exit 2
fi
if [[ ! -f "${FOLDER}/Overture.store" || ! -s "${FOLDER}/synthetic-store-report.txt" ]]; then
  echo "UNMEASURED: the writer run passed but wrote no store, so the opt-in writer did not run." >&2
  tail -25 "${LOG}" >&2
  exit 2
fi

cat "${FOLDER}/synthetic-store-report.txt"
echo
echo "Open it with:"
echo "  mac/scripts/run-debug.sh --store-folder \"${FOLDER}\""
