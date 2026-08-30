#!/usr/bin/env bash
set -euo pipefail

# #3270: which test harnesses hold one piece of state for the WHOLE PROCESS?
#
# WHY IT EXISTS. Four of them were found in #3234 by running the Swift suite in parallel and reading
# which tests went red, over four rounds. That costs a full suite run per round and only finds the ones
# that happened to collide that time. A fifth (`StubURLProtocol` in CarnegieExtractorTests, #3269) was
# found afterwards by hand, by listing the mutable statics in the test targets, which took seconds. This
# is that listing, kept.
#
# WHY IT MATTERS NOW. #3266 has to turn parallel testing on. Every remaining piece of shared state is a
# test that fails once in four runs rather than reliably, which is the shape that trains people to
# re-run until green. A search for the SHAPE finds them all at once, before the switch is flipped, and
# it keeps finding the ones that arrive later.
#
# WHAT COUNTS AS A SUBJECT, and what does not. A STORED `static var` is one variable per process, so two
# tests running at once share it. A COMPUTED one derives its value on every read and holds nothing, and
# it is by far the commoner shape in these targets (a liveStoreURL, a source root, a lazily built
# fixture), so a check that reported those would fire on the ordinary case and be switched off within a
# day (L93). A `static let` is immutable. The one stored shape that LOOKS computed is a closure
# initialiser (`static var x: T = { ... }()`), and it is treated as stored, which is what it is.
#
# Prose is not a declaration. Three files in the real tree explain in a COMMENT why they are not a
# `static var`, and a reader that counted those would report the very code that fixed this defect as an
# instance of it.
#
# IT REPORTS, IT DOES NOT REFUSE. A new stored static is not automatically a defect: it may be perfectly
# safe, or it may already be covered by a lock. What this produces is the list NOBODY HAS LOOKED AT YET,
# so the judgement is made once and recorded instead of being remade every sweep. The baseline carries
# the REASON per line, because the useful fact is not that somebody looked but what accounts for it:
# which named lock holds it, or why it cannot collide.
#
# THE BASELINE GROWS, like fixtures/test-identity-provenance.txt and unlike
# fixtures/test-data-email-domains.txt. It is a triage log, not a ratchet: new harnesses legitimately
# arrive with new tests.
#
# COST. One grep over three directories, so it rides along in scripts/test-all.sh as an advisory rather
# than living behind a command nobody types. #2773 is the record of what the other arrangement costs:
# the tool shipped, nothing ran it, and 17 entries had accumulated by the time anybody looked.

usage() {
  cat <<'USAGE'
usage: scripts/check-test-shared-state.sh [--record]

  (no flags)  Report every stored mutable process-wide static in the test targets that the baseline
              has not accounted for, plus any baseline line whose declaration is gone.
  --record    Write the baseline to exactly what is in the tree now, keeping the reasons already
              written and marking new entries as not yet explained. Prints what it adds.

exit status
  0  measured, and every declaration present is already accounted for
  1  measured, and there is something to triage (or a baseline line to delete)
  2  UNMEASURED: no Swift was read at all, so nothing was checked

environment
  OVERTURE_SHARED_STATE_REPO      repository to scan (default: this script's own repository)
  OVERTURE_SHARED_STATE_ROOTS     space separated paths inside it (default: the three test targets)
  OVERTURE_SHARED_STATE_BASELINE  the triage log (default: <repo>/fixtures/test-shared-state.txt)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${OVERTURE_SHARED_STATE_REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ROOTS="${OVERTURE_SHARED_STATE_ROOTS:-mac/OvertureTests mac/OvertureHostedTests mac/TestSupport}"
BASELINE="${OVERTURE_SHARED_STATE_BASELINE:-${REPO}/fixtures/test-shared-state.txt}"

RECORD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) RECORD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# How many Swift files were actually READ. This is the evidence that separates "nothing to find" from
# "nothing was looked at", which leave the same empty result (L98). It is a count of files rather than a
# count of roots, because a root that exists and holds no Swift is the same unmeasured state as a root
# that is not there: a renamed target, a bad root, a checkout that did not finish.
swift_files() {
  local root
  for root in ${ROOTS}; do
    [[ -d "${REPO}/${root}" ]] || continue
    find "${REPO}/${root}" -name '*.swift' -type f
  done
}

# Enumerated ONCE, into a list both the count and the extraction read. Counting inside the extraction
# was tried first and cannot work: the extraction runs inside a command substitution, so a variable it
# increments belongs to that subshell and reaches the caller as zero, which is the exact reading this
# count exists to prevent (an unmeasured run wearing a clean verdict).
SWIFT_FILE_LIST="$(swift_files || true)"
SWIFT_FILES_READ="$(printf '%s\n' "${SWIFT_FILE_LIST}" | grep -c . || true)"

# One line per stored mutable process-wide declaration: `<repo-relative path>:<name>`.
#
# Keyed by NAME rather than by line number on purpose: a declaration that moves down a file is the same
# declaration, and a baseline keyed by position would report every unrelated edit as a fresh finding and
# be abandoned in a week.
extract_declarations() {
  local file rel
  [[ -n "${SWIFT_FILE_LIST}" ]] || return 0
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    rel="${file#"${REPO}/"}"
    REL="${rel}" awk '
      {
        line = $0
        # Prose is not a declaration. Stripping from the first // also removes a trailing comment on a
        # real declaration, which is what we want: the comment is not part of the shape.
        sub(/\/\/.*/, "", line)
        if (line !~ /(^|[^A-Za-z0-9_])static[ \t]+var[ \t]/) next

        # Computed or stored. The brace is the tell, and the exception is a closure initialiser, where
        # an `=` comes first and the property is stored after all.
        eq = index(line, "=")
        brace = index(line, "{")
        if (brace > 0 && (eq == 0 || eq > brace)) next

        rest = line
        sub(/^.*static[ \t]+var[ \t]+/, "", rest)
        name = rest
        sub(/[^A-Za-z0-9_].*$/, "", name)
        if (name == "") next
        print ENVIRON["REL"] ":" name
      }
    ' "${file}"
  done <<< "${SWIFT_FILE_LIST}"
}

# The baseline's keys, with the reason stripped. Comments and blank lines are the file's own header.
baseline_keys() {
  [[ -f "${BASELINE}" ]] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "${BASELINE}" \
    | grep -v '^[[:space:]]*$' || true
}

# The reason recorded against one key, or empty. Used by --record to carry a judgement forward rather
# than making somebody make it again.
baseline_reason() {
  local key="$1"
  [[ -f "${BASELINE}" ]] || return 0
  awk -v key="${key}" '
    {
      line = $0
      hash = index(line, "#")
      k = (hash > 0) ? substr(line, 1, hash - 1) : line
      gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k != key) next
      if (hash > 0) { print substr(line, hash + 1); }
      exit
    }
  ' "${BASELINE}"
}

PRESENT="$(extract_declarations | sort -u)"

# UNMEASURED comes FIRST, before any comparison, because every comparison below reads an empty PRESENT
# as "the tree holds nothing", which is the one reading this must never give.
if [[ "${SWIFT_FILES_READ}" -eq 0 ]]; then
  echo "UNMEASURED - no Swift file was read under: ${ROOTS}" >&2
  echo "  (in ${REPO})" >&2
  echo "  Nothing was examined, so this says nothing about whether the test targets hold shared state." >&2
  echo "  A root that is missing and a root that is empty are the same answer here: check the paths." >&2
  exit 2
fi

RECORDED="$(baseline_keys | sort -u)"
FRESH="$(comm -23 <(printf '%s\n' "${PRESENT}" | grep -v '^$' || true) <(printf '%s\n' "${RECORDED}" | grep -v '^$' || true))"
GONE="$(comm -13 <(printf '%s\n' "${PRESENT}" | grep -v '^$' || true) <(printf '%s\n' "${RECORDED}" | grep -v '^$' || true))"

if [[ "${RECORD}" -eq 1 ]]; then
  # Assembled in full BEFORE the file is opened for writing. `{ ... } > "${BASELINE}"` truncates the
  # baseline the instant the redirection is set up, so the reasons this loop exists to carry forward
  # would already be gone by the time it read them: every line came back NOT YET EXPLAINED, and the
  # record read as a clean re-record of a file it had just emptied.
  RECORD_BODY=""
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    reason="$(baseline_reason "${key}")"
    if [[ -n "${reason}" ]]; then
      RECORD_BODY+="$(printf '%s  #%s' "${key}" "${reason}")"$'\n'
    else
      RECORD_BODY+="$(printf '%s  # NOT YET EXPLAINED' "${key}")"$'\n'
    fi
  done <<< "${PRESENT}"

  {
    cat <<'HEADER'
# Test harnesses that hold one piece of state for the WHOLE PROCESS (#3270).
#
# One stored mutable `static var` per line, as `<path>:<name>`, followed by the REASON it is accounted
# for: which named lock holds it, or why it cannot collide. The reason is the point of the file. A line
# with no reason has been seen and not yet judged.
#
# This file GROWS. It is a triage log, not a ratchet: new harnesses legitimately arrive with new tests,
# and recording one is the act of having looked at it.
#
# Regenerate with: scripts/check-test-shared-state.sh --record
# Read the list it prints before you commit the result, and write the reason for anything new.
HEADER
    printf '%s' "${RECORD_BODY}"
  } > "${BASELINE}"
  echo "Wrote ${BASELINE} ($(printf '%s\n' "${PRESENT}" | grep -c . || true) declaration(s) from ${SWIFT_FILES_READ} Swift file(s))."
  if [[ -n "${FRESH}" ]]; then
    echo "Added:"
    printf '%s\n' "${FRESH}" | sed 's/^/  /'
    echo "Write the reason for each of those. A line that says NOT YET EXPLAINED is a judgement nobody made."
  fi
  if [[ -n "${GONE}" ]]; then
    echo "Dropped (no longer in the tree):"
    printf '%s\n' "${GONE}" | sed 's/^/  /'
  fi
  exit 0
fi

STATUS=0

if [[ -n "${FRESH}" ]]; then
  STATUS=1
  echo "$(printf '%s\n' "${FRESH}" | grep -c . || true) stored process-wide static(s) in the test targets that nobody has accounted for:"
  printf '%s\n' "${FRESH}" | sed 's/^/  /'
  echo
  echo "  Each one is a single variable shared by every test in the process, so two tests running at"
  echo "  once share it. .serialized does NOT close that: it orders a suite's own tests, and the"
  echo "  interference comes from OTHER suites (SourceFetcherTests carried .serialized and still failed)."
  echo "  Either give the suites that touch it a shared lock (mac/OvertureTests/SharedStateTestLock.swift,"
  echo "  one line on each suite declaration), or record why it cannot collide, with --record."
fi

if [[ -n "${GONE}" ]]; then
  STATUS=1
  echo
  echo "$(printf '%s\n' "${GONE}" | grep -c . || true) recorded declaration(s) no longer in the tree:"
  printf '%s\n' "${GONE}" | sed 's/^/  /'
  echo
  echo "  Drop those lines with --record. A log that still describes a tree it no longer matches hides a"
  echo "  re-introduction behind a line that looks already answered."
fi

if [[ "${STATUS}" -eq 0 ]]; then
  echo "Every stored process-wide static in the test targets is accounted for ($(printf '%s\n' "${PRESENT}" | grep -c . || true) of them, from ${SWIFT_FILES_READ} Swift file(s))."
fi
exit "${STATUS}"
