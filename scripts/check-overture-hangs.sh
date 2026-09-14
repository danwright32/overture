#!/usr/bin/env bash
# List the hang reports macOS has already written for Overture (#3425).
#
# WHY IT IS WORTH HAVING even beside an in-app freeze detector: this source is FREE, the OS writes it
# whether or not our own instrumentation is running or correct, and it works BACKWARDS over what is
# already on disk, where a detector can only ever see forward from the day it ships.
#
# Measured 2026-08-31: /Library/Logs/DiagnosticReports/ held two Overture hang reports, both from
# 2026-08-30, one of 6.6 seconds and one of 58 SECONDS. Neither was known to anybody until somebody
# went looking while diagnosing a different freeze, and the 58 second one is the longest freeze on
# record for this app. It left no other trace anywhere.
#
# HOW TO READ ITS ANSWER, which is the trap this exists to avoid. It has THREE outcomes:
#
#   0  every directory it could read holds no Overture hang report. It NAMES those directories, so the
#      clean bill states its own scope rather than standing for the whole Mac.
#   1  hang reports are on record, listed newest first.
#   2  UNMEASURED: not one directory could be read. A Mac that has recorded no hangs and a reader that
#      cannot see the folder produce the same empty list, and the emptiest possible failure must never
#      read as the cleanest possible pass (L98, L11).
#
# A directory that is MISSING and one that is present and UNREADABLE are reported as different things,
# for the same reason: only the second is a permissions problem somebody can fix.
#
# Each report is COPIED to ~/.overture-mac-test-diagnostics/ rather than cited where it lies, because
# these rotate. A copy already there is left alone, so running this twice does not duplicate anything.
#
# It also names the PATH each report was written for. Two builds of Overture can run at once, and a
# hang belonging to the Debug build is a different fact from one belonging to the installed Release
# app; nothing else in the report distinguishes them at a glance.
set -uo pipefail
# #3481/L372: captured BEFORE the cd. `$0` and `BASH_SOURCE[0]` are the path the script was INVOKED
# by, so re-deriving a directory from either after a cd resolves against the NEW working directory.
HANGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HANGS_DIR}/.." || exit 1

# Colon separated, so a fixture can point the whole search somewhere of its own.
REPORT_DIRS="${OVERTURE_HANG_DIRS:-/Library/Logs/DiagnosticReports:${HOME}/Library/Logs/DiagnosticReports}"
OUT_DIR="${OVERTURE_HANG_OUT:-${HOME}/.overture-mac-test-diagnostics}"

# How many of the app's own frames reach the screen per report. The whole report is always kept, so the
# cap costs nothing but has to SAY what it dropped: a truncation that does not announce itself reads as
# the whole answer. Measured 2026-09-04 against this Mac's two real reports: 2 frames and 60, so the
# default is set well above both rather than at a round number that would fire on the ordinary case.
MAX_FRAMES="${OVERTURE_HANG_MAX_FRAMES:-120}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    *)
      # Refused rather than ignored: an argument silently dropped is indistinguishable from one that
      # was honoured (#3245).
      echo "UNMEASURED: unknown argument '$1'."
      echo "            Usage: scripts/check-overture-hangs.sh [--out DIR]"
      exit 2
      ;;
  esac
done

# --- which directories could actually be read ------------------------------------------------------
READABLE=""
UNREADABLE=""
MISSING=""
OLD_IFS="${IFS}"
IFS=":"
for dir in ${REPORT_DIRS}; do
  IFS="${OLD_IFS}"
  [ -n "${dir}" ] || continue
  if [ ! -d "${dir}" ]; then
    MISSING="${MISSING}${dir}
"
  elif [ ! -r "${dir}" ] || ! ls "${dir}" >/dev/null 2>&1; then
    UNREADABLE="${UNREADABLE}${dir}
"
  else
    READABLE="${READABLE}${dir}
"
  fi
  IFS=":"
done
IFS="${OLD_IFS}"

if [ -z "${READABLE}" ]; then
  echo "UNMEASURED: not one diagnostic reports directory could be read, so whether macOS has recorded"
  echo "            a hang for Overture is unknown. That is not the same as there being none."
  if [ -n "${UNREADABLE}" ]; then
    echo "            present but unreadable (a permissions problem somebody can fix):"
    printf '%s' "${UNREADABLE}" | sed 's/^/              /'
  fi
  if [ -n "${MISSING}" ]; then
    echo "            not there at all:"
    printf '%s' "${MISSING}" | sed 's/^/              /'
  fi
  exit 2
fi

# --- the reports -----------------------------------------------------------------------------------
REPORTS=""
while IFS= read -r dir; do
  [ -n "${dir}" ] || continue
  for f in "${dir}"/Overture*.hang; do
    [ -f "${f}" ] || continue
    REPORTS="${REPORTS}${f}
"
  done
done <<REPORT_DIR_LIST
${READABLE}
REPORT_DIR_LIST

# Newest first, by the stamp macOS puts in the filename, which sorts lexically because it is written
# largest unit first. Falling back on the name alone rather than on mtime: a copy operation rewrites an
# mtime and the stamp is the report's own account of when the hang happened.
REPORTS="$(printf '%s' "${REPORTS}" | grep -v '^[[:space:]]*$' | sort -r || true)"

if [ -z "${REPORTS}" ]; then
  echo "No Overture hang report on record."
  echo "  read: $(printf '%s' "${READABLE}" | tr '\n' ' ')"
  if [ -n "${UNREADABLE}" ]; then
    echo "  NOT read (present but unreadable), so this answer is about the directories above only:"
    printf '%s' "${UNREADABLE}" | sed 's/^/    /'
  fi
  exit 0
fi

if ! mkdir -p "${OUT_DIR}" 2>/dev/null; then
  echo "UNMEASURED: could not create ${OUT_DIR}, so a report found here could not be kept."
  echo "            These reports rotate, so listing one without keeping it is a citation that expires."
  exit 2
fi

COUNT="$(printf '%s\n' "${REPORTS}" | grep -c '[^[:space:]]' || true)"
echo "${COUNT} Overture hang report(s) on record, newest first."
echo "  read: $(printf '%s' "${READABLE}" | tr '\n' ' ')"
if [ -n "${UNREADABLE}" ]; then
  echo "  NOT read (present but unreadable): $(printf '%s' "${UNREADABLE}" | tr '\n' ' ')"
fi
echo

while IFS= read -r report; do
  [ -n "${report}" ] || continue
  echo "  $(basename "${report}")"

  WHEN="$(grep -m1 '^Date/Time:' "${report}" 2>/dev/null | sed 's/^Date\/Time: *//')"
  DURATION="$(grep -m1 '^Duration:' "${report}" 2>/dev/null | sed 's/^Duration: *//')"
  # The app the report is about, so a Debug hang is never read as a Release one.
  APP_PATH="$(grep -m1 '^Path:' "${report}" 2>/dev/null | sed 's/^Path: *//')"
  # The sentence alone, without the report's own `Note:` label and column padding, so it reads as a
  # line of this tool's output rather than as a fragment of somebody else's file.
  UNRESPONSIVE="$(grep -m1 'Unresponsive for' "${report}" 2>/dev/null | sed 's/^ *Note: *//; s/^ *//')"

  echo "    when:         ${WHEN:-not stated in the report}"
  echo "    duration:     ${DURATION:-not stated in the report}"
  echo "    unresponsive: ${UNRESPONSIVE:-not stated in the report}"
  echo "    app:          ${APP_PATH:-not stated in the report}"

  # The Overture process block only. A hang report is a system-wide stackshot, so every other running
  # process is in the same file and printing across the boundary would attribute somebody else's stack
  # to this app.
  BLOCK="$(awk '
    /^Process: +Overture \[/ { inblock = 1; print; next }
    inblock && /^Process: / { inblock = 0 }
    inblock { print }
  ' "${report}" 2>/dev/null)"

  if [ -z "${BLOCK}" ]; then
    echo "    stack:        the report carries no Overture process block, so what the app itself was"
    echo "                  doing is not something this report answers."
  else
    # What the main thread was stuck IN is the deepest frame it reached; the app's OWN frames say which
    # of Dan's code led there. They are different questions and both are printed, because a hang is
    # routinely all system frames below one line of ours.
    LEAF="$(printf '%s\n' "${BLOCK}" | awk '
      /main-thread/ { inmain = 1; next }
      inmain && /^ *Thread / { inmain = 0 }
      inmain && /^[[:space:]]+[0-9]+ +/ { leaf = $0 }
      END { if (leaf != "") print leaf }
    ')"
    OWN="$(printf '%s\n' "${BLOCK}" | grep -F ' in Overture +' || true)"

    if [ -n "${LEAF}" ]; then
      echo "    blocked in:   $(printf '%s' "${LEAF}" | sed 's/^ *//')"
    else
      echo "    blocked in:   the main thread's stack could not be read out of this report."
    fi
    if [ -n "${OWN}" ]; then
      OWN_COUNT="$(printf '%s\n' "${OWN}" | grep -c '[^[:space:]]' || true)"
      echo "    Overture's own frames (${OWN_COUNT}):"
      if [ "${OWN_COUNT}" -gt "${MAX_FRAMES}" ]; then
        printf '%s\n' "${OWN}" | sed 's/^ */      /' | sed -n "1,${MAX_FRAMES}p"
        echo "      ... showing ${MAX_FRAMES} of ${OWN_COUNT}. The rest are in the kept report."
      else
        printf '%s\n' "${OWN}" | sed 's/^ */      /'
      fi
    else
      echo "    Overture's own frames: none in this report. That is ordinary for a hang spent entirely"
      echo "                  below one system call, and it is said rather than left as an empty space."
    fi
  fi

  KEPT="${OUT_DIR}/$(basename "${report}")"
  if [ -f "${KEPT}" ]; then
    echo "    kept:         ${KEPT} (already there, left alone)"
  elif cp "${report}" "${KEPT}" 2>/dev/null; then
    echo "    kept:         ${KEPT}"
  else
    echo "    kept:         COULD NOT COPY to ${KEPT}. These reports rotate, so read it where it lies"
    echo "                  before it goes: ${report}"
  fi
  echo
done <<REPORT_LIST
${REPORTS}
REPORT_LIST

exit 1
