#!/usr/bin/env bash
# The parts every reader of macOS's own diagnostic reports needs, in ONE place (#3541).
#
# #3425 built `check-overture-hangs.sh` for `.hang` reports and #3541 added
# `check-overture-cpu.sh` for `.cpu_resource.diag` ones. The two answer different questions from
# different file formats, which is why they are two scripts, but three things are identical in both and
# would otherwise be written twice: which directories could be read, how a report is kept, and the
# three-outcome vocabulary. Two copies of that would eventually disagree about what UNMEASURED means,
# and the one that disagreed quietly would be the one reporting a clean bill (L263, L613).
#
# THE THREE OUTCOMES, which is the trap both scripts exist to avoid:
#
#   0  every directory that could be read holds no such report. It NAMES those directories, so the clean
#      bill states its own scope rather than standing for the whole Mac.
#   1  reports are on record.
#   2  UNMEASURED: not one directory could be read. A Mac that has recorded nothing and a reader that
#      cannot see the folder produce the same empty list, and the emptiest possible failure must never
#      read as the cleanest possible pass (L98, L11).
#
# A directory that is MISSING and one that is present and UNREADABLE are kept apart for the same reason:
# only the second is a permissions problem somebody can fix.

# Sets OVERTURE_REPORTS_READABLE, OVERTURE_REPORTS_UNREADABLE and OVERTURE_REPORTS_MISSING, each a
# newline separated list. Takes the colon separated search path.
overture_classify_report_dirs() {
  local dirs="$1" dir old_ifs
  OVERTURE_REPORTS_READABLE=""
  OVERTURE_REPORTS_UNREADABLE=""
  OVERTURE_REPORTS_MISSING=""
  old_ifs="${IFS}"
  IFS=":"
  for dir in ${dirs}; do
    IFS="${old_ifs}"
    [ -n "${dir}" ] || continue
    if [ ! -d "${dir}" ]; then
      OVERTURE_REPORTS_MISSING="${OVERTURE_REPORTS_MISSING}${dir}
"
    elif [ ! -r "${dir}" ] || ! ls "${dir}" >/dev/null 2>&1; then
      OVERTURE_REPORTS_UNREADABLE="${OVERTURE_REPORTS_UNREADABLE}${dir}
"
    else
      OVERTURE_REPORTS_READABLE="${OVERTURE_REPORTS_READABLE}${dir}
"
    fi
    IFS=":"
  done
  IFS="${old_ifs}"
}

# The UNMEASURED message, printed when not one directory could be read. Takes a short phrase naming what
# was being looked for, so each script's refusal says what it could not answer rather than a generic line.
overture_report_unmeasured() {
  local subject="$1"
  echo "UNMEASURED: not one diagnostic reports directory could be read, so whether macOS has recorded"
  echo "            ${subject} is unknown. That is not the same as there being none."
  if [ -n "${OVERTURE_REPORTS_UNREADABLE}" ]; then
    echo "            present but unreadable (a permissions problem somebody can fix):"
    printf '%s' "${OVERTURE_REPORTS_UNREADABLE}" | sed 's/^/              /'
  fi
  if [ -n "${OVERTURE_REPORTS_MISSING}" ]; then
    echo "            not there at all:"
    printf '%s' "${OVERTURE_REPORTS_MISSING}" | sed 's/^/              /'
  fi
}

# Every file under the readable directories matching a glob suffix, newest first.
#
# Sorted by the stamp macOS puts in the FILENAME rather than by mtime, and that is deliberate: a copy
# operation rewrites an mtime, and the stamp is the report's own account of when the event happened. It
# sorts lexically because it is written largest unit first.
overture_find_reports() {
  local suffix="$1" dir f found=""
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    for f in "${dir}"/Overture*${suffix}; do
      [ -f "${f}" ] || continue
      found="${found}${f}
"
    done
  done <<REPORT_DIR_LIST
${OVERTURE_REPORTS_READABLE}
REPORT_DIR_LIST
  printf '%s' "${found}" | grep -v '^[[:space:]]*$' | sort -r || true
}

# Keep a copy, because these reports ROTATE and a citation to one where it lies expires. A copy already
# there is left alone, so running twice duplicates nothing. Echoes the line to print.
overture_keep_report() {
  local report="$1" out_dir="$2" kept
  kept="${out_dir}/$(basename "${report}")"
  if [ -f "${kept}" ]; then
    echo "${kept} (already there, left alone)"
  elif cp "${report}" "${kept}" 2>/dev/null; then
    echo "${kept}"
  else
    echo "COULD NOT COPY to ${kept}. These reports rotate, so read it where it lies before it goes: ${report}"
  fi
}
