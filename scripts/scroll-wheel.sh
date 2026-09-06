#!/usr/bin/env bash
# Scroll the running Overture, and say whether the scroll landed (#3503).
#
# WHO IS WAITING FOR THIS. #3439 is the decision gate that reads the remaining floor and decides whether
# the deferred architecture escalation is triggered, and one of the four things it must record is the cost
# of ONE SCROLL FRAME on the running app. `scripts/freeze-measure.sh` samples a live process and has no way
# to make that process scroll, and `cliclick` on this Mac has move, click and wait with no wheel at all,
# which is what #3480 measured. So today that gate can measure a keystroke and a render pass and not the
# third thing it is specified to compare.
#
# IT DRIVES DAN'S MACHINE, so it refuses without --yes and says what it is about to do. That is this
# repository's rule for anything that spends real usage or takes over the machine, and the same shape
# `scripts/measure-concurrent-runs.sh` uses.
#
# IT TARGETS BY EXECUTABLE PATH, never by name or bundle id, and proves the pid it found is the only
# candidate. Two copies of this app can run at once, both called Overture, and a lookup that resolves to
# the wrong one has already cost a live app being quit on this Mac. A guard whose two sides come from one
# lookup can only confirm the lookup is consistent, never that it is correct (L70).
#
# Three outcomes, and the third is the one that matters:
#   0  LANDED / SENT   the scroll happened, and the position moved (or landing was not checked)
#   1  DID NOT MOVE    the event was posted and the tree was readable; the surface did not scroll
#   2  UNMEASURED      nothing was measured: no app, two candidates, an unreadable tree, a refusal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # BEFORE any cd (L372, #3481)
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RELEASE_APP="/Applications/Overture.app/Contents/MacOS/Overture"
DEBUG_APP_FRAGMENT="Build/Products/Debug/Overture.app/Contents/MacOS/Overture"

# Seams, so the fixture can drive every decision below without a running app and without posting a single
# real event into whatever Dan has on screen (L2). Every one is named here rather than discovered.
PGREP="${OVERTURE_SCROLL_PGREP:-pgrep}"
POSTER="${OVERTURE_SCROLL_POSTER:-}"

TARGET="release"
YES=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --debug) TARGET="debug"; shift ;;
    --release) TARGET="release"; shift ;;
    --turns|--delta) ARGS+=("$1" "$2"); shift 2 ;;
    --no-confirm) ARGS+=("$1"); shift ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *) echo "scroll-wheel: unrecognised argument $1" >&2; exit 2 ;;
  esac
done

pids_for() {
  # The FULL executable path, so a Debug build and a Release build are different queries rather than two
  # answers to one.
  case "$1" in
    release) "${PGREP}" -f "${RELEASE_APP}" 2>/dev/null || true ;;
    debug)   "${PGREP}" -f "${DEBUG_APP_FRAGMENT}" 2>/dev/null || true ;;
  esac
}

RELEASE_PIDS="$(pids_for release)"
DEBUG_PIDS="$(pids_for debug)"
WANTED="$(pids_for "${TARGET}")"

count_of() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | grep -c . ; }

if [ "$(count_of "${WANTED}")" -eq 0 ]; then
  echo "UNMEASURED: no ${TARGET} Overture is running."
  echo "  Looked for the executable at $([ "${TARGET}" = release ] && echo "${RELEASE_APP}" || echo "...${DEBUG_APP_FRAGMENT}")."
  exit 2
fi
if [ "$(count_of "${WANTED}")" -gt 1 ]; then
  echo "UNMEASURED: ${TARGET} Overture is running more than once, so there is no single target."
  echo "  pids: $(printf '%s' "${WANTED}" | tr '\n' ' ')"
  exit 2
fi

# The OTHER build being up is not a refusal, but it is worth saying: a scroll aimed at one and observed on
# the other is exactly the mistake this targeting exists to prevent, and only the reader can see both.
OTHER="$([ "${TARGET}" = release ] && printf '%s' "${DEBUG_PIDS}" || printf '%s' "${RELEASE_PIDS}")"
if [ "$(count_of "${OTHER}")" -gt 0 ]; then
  echo "note: the other build is also running (pid $(printf '%s' "${OTHER}" | tr '\n' ' ')). This scroll goes to the ${TARGET} one, pid ${WANTED}."
fi

if [ "${YES}" -ne 1 ]; then
  cat <<EOF
scroll-wheel: this DRIVES YOUR MACHINE and would post scroll wheel events to the ${TARGET} Overture
(pid ${WANTED}). Nothing has been posted.

  Before running it, put the window you want measured on screen and leave the pointer off it: the events
  go to the PROCESS rather than to whatever is under the pointer, but a stray click of your own during
  the measurement is indistinguishable from the scroll in every reading it takes.

Re-run with --yes to post them.
EOF
  exit 2
fi

if [ -n "${POSTER}" ]; then
  exec "${POSTER}" --pid "${WANTED}" ${ARGS[@]+"${ARGS[@]}"}
fi

# `swift` compiles the helper on each run, which is about a second and is nothing beside a measurement
# somebody is standing at the machine for. It is deliberately not a build product: a tool that needs
# building before it can be used is a tool nobody uses.
exec swift "${SCRIPT_DIR}/../mac/scripts/lib/post-scroll-wheel.swift" --pid "${WANTED}" ${ARGS[@]+"${ARGS[@]}"}
