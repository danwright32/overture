#!/usr/bin/env bash
# Does the Mac suite clean up the temporary directories it creates?
#
# #3065. Measured on this Mac 2026-08-22, on an uptime of 8 days and counting only the shapes this repo's
# tests create: 952 debug-seed-test, 560 census, 336 prep-results, 224 prep-reply-cancel, 224
# performer-failure, 112 each of scout-snapshot, scout-extract-cancel and overture-test, and 56 each of
# venue-identity, no-repo, debug-seed-missing and debug-seed-gmail-missing. Every count is a multiple of
# 56, the number of suite runs, so the per-run leak was about 52 directories. venue-identity sandboxes
# held a clone of the live store at roughly 4 MB each. macOS clears the per-user temp folder only at boot,
# so nothing else was going to remove any of it, and this repo amplifies the rate by running its suite
# from worktrees, many copies against one shared folder.
#
# Named check- rather than test- ON PURPOSE: scripts/run-shell-fixtures.sh runs every *.test.sh, and this
# one runs the whole Mac suite. Its judging half is exercised on every push by
# scripts/check-temp-dir-leaks.test.sh through the --before/--after/--log-file seam.
#
# Exit codes, deliberately THREE rather than two:
#   0  tests ran and left nothing behind
#   1  tests ran and left sandboxes behind, which are named
#   2  nothing was measured (an input is missing, no prefix could be derived, or no test executed)
#
# The 2 matters more than the 1. A suite that cleans up perfectly and a suite that NEVER RAN leave the
# SAME empty before/after difference, so judging on that difference alone reports the emptiest possible
# failure as the cleanest possible pass (L98). The proof that tests ran therefore comes from the run's own
# output, never from the difference.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LEAKS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# #3258: scratch that honours TMPDIR, so a leak is visible to the checks that look there. This script
# in particular: its whole subject is scratch nobody reclaims, and it was making its own where it
# could not see it.
# shellcheck source=./lib/scratch.sh
. "${LEAKS_SCRIPT_DIR}/lib/scratch.sh"

UUID_SHAPE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

# The roots holding the code that creates sandboxes. Overridable so the fixture can drive the judging half
# against a tree of its own; colon separated, because this repo's own path contains spaces.
DEFAULT_ROOTS="mac/OvertureTests:mac/OvertureHostedTests:mac/TestSupport"

# The prefixes are DERIVED from the sources that create the directories, never kept by hand beside them,
# or a newly added sandbox is exempt from the check meant to catch it (L41, L96).
#
# FOUR forms, because all four exist and any one alone would exempt the others:
#
#   sandboxes.make(named: "census")                              a converted suite
#   sandboxes.makeFile(named: "x", inSandboxNamed: "prep-results")   a converted file sandbox
#   sandboxes.reserve(named: "debug-seed-missing")               a path the code under test creates
#   .appendingPathComponent("still-leaking-\(UUID()...)")        one not yet converted
#
# Reading only the last is the trap this comment exists for: converting a suite to TemporarySandboxes
# DELETES its appendingPathComponent line, so the guard would stop covering a suite at the exact moment
# that suite was fixed, and would go on reporting a clean tree.
derive_prefixes() {
  local roots="${OVERTURE_TEMP_LEAK_TESTS_DIRS:-$DEFAULT_ROOTS}"
  local files=()
  local root
  while IFS= read -r root; do
    [ -n "${root}" ] || continue
    [ -d "${root}" ] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find "${root}" -name '*.swift' -type f -print0 2>/dev/null)
  done < <(printf '%s\n' "${roots}" | tr ':' '\n')
  [ "${#files[@]}" -gt 0 ] || return 0
  {
    grep -ohE 'appendingPathComponent\("[A-Za-z0-9._-]+-\\\(UUID' "${files[@]}" 2>/dev/null \
      | sed -E 's/appendingPathComponent\("//; s/\\\(UUID//'
    grep -ohE '(make|reserve)\(named: "[A-Za-z0-9._-]+"' "${files[@]}" 2>/dev/null \
      | sed -E 's/(make|reserve)\(named: "//; s/"$/-/'
    grep -ohE 'inSandboxNamed: "[A-Za-z0-9._-]+"' "${files[@]}" 2>/dev/null \
      | sed -E 's/inSandboxNamed: "//; s/"$/-/'
  } | sort -u
}

usage() {
  echo "usage: $0 [--before FILE --after FILE --log-file FILE] [--list-prefixes] [--snapshot]" >&2
}

BEFORE=""; AFTER=""; LOG=""; LIST_ONLY=no; SNAPSHOT_ONLY=no
while [ $# -gt 0 ]; do
  case "$1" in
    --before)        BEFORE="${2:-}"; shift 2 ;;
    --after)         AFTER="${2:-}";  shift 2 ;;
    --log-file)      LOG="${2:-}";    shift 2 ;;
    --list-prefixes) LIST_ONLY=yes;   shift ;;
    --snapshot)      SNAPSHOT_ONLY=yes; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# The listing has ONE definition and this is it, so a caller taking its own snapshots cannot drift into
# reading a different directory than the one this script compares against (L41).
snapshot() { find "${TMPDIR:-/tmp}" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | sort; }

if [ "$SNAPSHOT_ONLY" = yes ]; then
  snapshot
  exit 0
fi

PREFIXES=$(derive_prefixes)
if [ -z "$PREFIXES" ]; then
  echo "CANNOT MEASURE: no sandbox prefixes could be derived from the test sources." >&2
  echo "Either the sources moved or the pattern stopped matching them. Every sandbox" >&2
  echo "would be exempt from this check, which reads as a clean tree." >&2
  exit 2
fi

if [ "$LIST_ONLY" = yes ]; then
  echo "$PREFIXES"
  exit 0
fi

# One alternation of the derived prefixes, each of which must be followed by a UUID. Requiring the UUID is
# what keeps a short prefix (census-, accounts-) from matching another application's temp files (L104).
ALTERNATION=$(echo "$PREFIXES" | tr '\n' '|' | sed 's/|$//')
LEAK_PATTERN="^(${ALTERNATION})${UUID_SHAPE}"

# Real mode: take both snapshots around a genuine run of the Mac suite. The runner is injectable so the
# fixture can drive this path without paying for a suite run.
if [ -z "$BEFORE" ] && [ -z "$AFTER" ] && [ -z "$LOG" ]; then
  WORK=$(overture_scratch_dir temp-dir-leaks) || exit 2
  trap 'rm -rf "$WORK"' EXIT
  BEFORE="$WORK/before.txt"; AFTER="$WORK/after.txt"; LOG="$WORK/run.log"
  snapshot > "$BEFORE"
  echo "check-temp-dir-leaks: running the Mac suite, this takes minutes."
  "${TEMP_LEAK_TEST_RUNNER:-./mac/scripts/run-tests-locked.sh}" > "$LOG" 2>&1
  snapshot > "$AFTER"
fi

for pair in "before snapshot:$BEFORE" "after snapshot:$AFTER" "test run log:$LOG"; do
  what="${pair%%:*}"; path="${pair#*:}"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    echo "CANNOT MEASURE: the $what is missing (${path:-not given})." >&2
    echo "An absent input is not an empty one, so this is not a clean tree." >&2
    exit 2
  fi
done

# Did any test actually execute? Read from the run's own output, never from the snapshot difference.
#
# Matched with a case glob rather than a grep pipeline on purpose: under pipefail, `cat big | grep -q`
# reports FAILURE on a match, because grep exits at the first hit and cat takes SIGPIPE writing the rest
# (L183).
OUTPUT=$(cat "$LOG" 2>/dev/null)
FOUND_A_TEST=no
case "$OUTPUT" in
  *"passed after"*) FOUND_A_TEST=yes ;;
  *"Test run with"*) FOUND_A_TEST=yes ;;
esac

if [ "$FOUND_A_TEST" = no ]; then
  echo "CANNOT MEASURE: the log shows no test executed." >&2
  echo "" >&2
  echo "$OUTPUT" | tail -10 >&2
  echo "" >&2
  echo "A suite that ran nothing leaves the same empty difference as a suite that" >&2
  echo "cleaned up perfectly, so this is reported as unmeasured, never as clean." >&2
  exit 2
fi

# What appeared during the run and survived it. Anything already present before the run is somebody else's
# mess, not this run's, or the first run after any earlier leak blames itself for ever (L93).
NEW=$(comm -13 <(sort -u "$BEFORE") <(sort -u "$AFTER"))
LEAKS=$(echo "$NEW" | grep -E "$LEAK_PATTERN" | sort)
LEAK_COUNT=$(echo "$LEAKS" | grep -c .)

if [ "$LEAK_COUNT" -gt 0 ]; then
  echo "TEMP DIRECTORIES LEAKED: the suite left $LEAK_COUNT sandbox(es) behind in ${TMPDIR:-/tmp}." >&2
  echo "" >&2
  echo "by shape:" >&2
  echo "$LEAKS" | sed -E "s/${UUID_SHAPE}/<uuid>/" | sort | uniq -c | sort -rn | awk 'NR<=20' >&2
  echo "" >&2
  # And the real directories, because a shape cannot be gone and looked at (L80).
  echo "for example:" >&2
  echo "$LEAKS" | awk 'NR<=5' | sed "s|^|  ${TMPDIR:-/tmp}|" >&2
  echo "" >&2
  echo "Each of these was created by a test and never removed. macOS clears the" >&2
  echo "per-user temp folder only at boot, so they accumulate until the next one." >&2
  echo "Take the sandbox from TemporarySandboxes, held as a property of a final class" >&2
  echo "suite, rather than a defer at each call site that the next test can forget." >&2
  exit 1
fi

echo "check-temp-dir-leaks: the suite left nothing behind."
echo "  checked ${TMPDIR:-/tmp} against $(echo "$PREFIXES" | grep -c .) derived sandbox prefixes."
exit 0
