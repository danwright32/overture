#!/usr/bin/env bash
# Sample the running Overture and print the app's own frames (#3424).
#
# WHY IT EXISTS. Sampling is the only thing that has ever named an Overture freeze correctly, and
# reading the code first has been wrong twice in a week. On 2026-08-30 (#3419) the source pointed at the
# Gmail calls in the reconcile tick; the sample put every one of 2,646 samples in
# `NSAppleScript.executeAndReturnError`. On 2026-08-31 two live samples settled the archive freeze in
# seconds. Doing it by hand is five steps, and it happens under time pressure, because the evidence
# disappears the moment the app unfreezes: about a minute, measured on 2026-08-30.
#
# HOW TO READ ITS ANSWER, which is the part worth knowing before using it. It has THREE outcomes:
#
#   0  the sample names frames of Overture's own, and they are printed
#   1  the sample was taken and kept, and names NONE of the app's own frames
#   2  UNMEASURED: no sample exists to read
#
# The middle one is not a failure and is not a pass, which is why it is neither. An app genuinely
# sitting in the run loop and a sample whose symbols could not be resolved produce the same empty list,
# and folding that into success would make the emptiest possible reading look like the cleanest possible
# one (L98, L11). The sample is kept either way, because it is real evidence whatever it names.
#
# The full file is saved under ~/.overture-mac-test-diagnostics/ rather than cited where `sample` puts
# it: its own default lands in a temp directory macOS clears at boot, and this evidence is routinely
# read days later.
set -uo pipefail
# #3481/L372: captured BEFORE the cd. `$0` and `BASH_SOURCE[0]` are the path the script was INVOKED
# by, so re-deriving a directory from either after a cd resolves against the NEW working directory:
# it works for one invocation and silently misses for another.
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SAMPLE_DIR}/.." || exit 1

# shellcheck source=./lib/overture-pid.sh
. "${SAMPLE_DIR}/lib/overture-pid.sh"

PGREP_CMD="${OVERTURE_SAMPLE_PGREP:-}"
SAMPLE_CMD="${OVERTURE_SAMPLE_CMD:-/usr/bin/sample}"
OUT_DIR="${OVERTURE_SAMPLE_OUT:-${HOME}/.overture-mac-test-diagnostics}"
SECONDS_TO_SAMPLE="${OVERTURE_SAMPLE_SECONDS:-5}"

# How many frame lines reach the screen. The whole file is always saved, so the cap costs nothing but
# says what it dropped: a truncation that does not announce itself reads as the whole answer.
MAX_FRAMES="${OVERTURE_SAMPLE_MAX_FRAMES:-80}"

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_TO_SAMPLE="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    *)
      # Refused rather than ignored: an argument that is silently dropped is indistinguishable from one
      # that was honoured (#3245).
      echo "UNMEASURED: unknown argument '$1'."
      echo "            Usage: scripts/sample-overture.sh [--seconds N] [--out DIR]"
      exit 2
      ;;
  esac
done

# --- which Overture --------------------------------------------------------------------------------
APP_PID="$(overture_resolve_pid "${PGREP_CMD}")"
if [ $? -ne 0 ]; then
  echo "UNMEASURED: ${APP_PID}"
  exit 2
fi

# --- take it ---------------------------------------------------------------------------------------
if ! mkdir -p "${OUT_DIR}" 2>/dev/null; then
  echo "UNMEASURED: could not create ${OUT_DIR}, so there is nowhere to keep the sample."
  exit 2
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
SAMPLE_OUT="${OUT_DIR}/overture-sample-${STAMP}.txt"

# The real interface, checked against /usr/bin/sample itself:
#   sample <pid | partial-process-name> [duration [samplingInterval]] [options...] [-file <filename>]
# The output path is NOT a positional argument. Passing it as one makes the real tool read it as the
# sampling interval in milliseconds and write to a default path instead.
echo "Sampling Overture (pid ${APP_PID}) for ${SECONDS_TO_SAMPLE}s..."
"${SAMPLE_CMD}" "${APP_PID}" "${SECONDS_TO_SAMPLE}" -mayDie -file "${SAMPLE_OUT}" >/dev/null 2>&1
SAMPLE_STATUS=$?

if [ "${SAMPLE_STATUS}" -ne 0 ]; then
  echo "UNMEASURED: sampling pid ${APP_PID} failed (status ${SAMPLE_STATUS}), so this run measured nothing."
  echo "            A failed sample is not a quiet app."
  exit 2
fi
if [ ! -s "${SAMPLE_OUT}" ]; then
  echo "UNMEASURED: the sampler reported success and wrote nothing to ${SAMPLE_OUT}."
  echo "            An empty file is not a reading of an idle app."
  exit 2
fi

# --- what the app itself was doing -------------------------------------------------------------------
FRAMES="$(grep -F '(in Overture)' "${SAMPLE_OUT}" || true)"
FRAME_COUNT="$(printf '%s\n' "${FRAMES}" | grep -c '[^[:space:]]' || true)"

echo "  full sample:  ${SAMPLE_OUT}"

if [ "${FRAME_COUNT}" -eq 0 ]; then
  echo
  echo "  This sample names NO FRAMES OF OVERTURE'S OWN."
  echo "  That is a reading to look at rather than a clean result: an app genuinely waiting in the run"
  echo "  loop and a sample whose symbols could not be resolved both look exactly like this. The file"
  echo "  above is kept either way; open it and read the call graph before concluding anything."
  exit 1
fi

echo "  Overture's own frames (${FRAME_COUNT} line(s)):"
echo
if [ "${FRAME_COUNT}" -gt "${MAX_FRAMES}" ]; then
  printf '%s\n' "${FRAMES}" | head -n "${MAX_FRAMES}"
  echo
  echo "  ... showing ${MAX_FRAMES} of ${FRAME_COUNT}. The rest are in the file above."
else
  printf '%s\n' "${FRAMES}"
fi
exit 0
