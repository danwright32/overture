#!/usr/bin/env bash
set -uo pipefail

# #4328: look for a real-arm file (a hashed snapshot of Dan's real data; see scripts/lib/real-arm-guard.sh)
# in every commit of a range, or in the working tree.
#
#   scripts/real-arm-scan.sh <base sha> <head sha>   every commit reachable from head and not from base.
#                                                    CI runs this over each pull request, because the local
#                                                    pre-push hook can be skipped with --no-verify and this
#                                                    repository is public (L489).
#   scripts/real-arm-scan.sh --tree [<repo dir>]     every tracked and untracked, not ignored, file, which is
#                                                    the second layer scripts/test-all.sh runs.
#
# Exit 0 clean, 1 a real-arm file found (named), 2 the question could not be answered, which is never a
# pass (L98): a range that selects no commit at all is what a wrong base looks like.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARD="${SCRIPT_DIR}/lib/real-arm-guard.sh"

if [ ! -r "${GUARD}" ]; then
  echo "real-arm-scan: UNMEASURED: ${GUARD} is missing or unreadable" >&2
  exit 2
fi
# shellcheck source=./lib/real-arm-guard.sh
source "${GUARD}"

if [ "${1:-}" = "--tree" ]; then
  repo="${2:-${REPO_ROOT}}"
  found="$(real_arm_tree_violations "${repo}")"
  status=$?
  what="the working tree at ${repo}"
elif [ $# -eq 2 ]; then
  found="$(real_arm_range_violations "$2" --not "$1")"
  status=$?
  what="the commits in $1..$2"
else
  echo "usage: scripts/real-arm-scan.sh <base sha> <head sha> | --tree [<repo dir>]" >&2
  exit 2
fi

if [ "${status}" -ne 0 ]; then
  echo "real-arm-scan: UNMEASURED: ${what} could not be checked for a real-arm file" >&2
  exit 2
fi
if [ -n "${found}" ]; then
  echo "real-arm-scan: REFUSED: ${what} carry a real-arm file:" >&2
  echo "${found}" | sed 's/^/    /' >&2
  real_arm_refusal_text >&2
  exit 1
fi
echo "real-arm-scan: clean, no real-arm file in ${what}"
exit 0
