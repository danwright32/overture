#!/usr/bin/env bash
set -uo pipefail

# #3386: how much of the Swift suite runs on the MAIN ACTOR, which is one serial executor.
#
# Under `-parallel-testing-enabled YES` Swift Testing runs the tests of one process concurrently, so two
# `@MainActor` suites in that process cannot overlap however they are written: they queue. A test that
# awaits anything therefore waits for every main-actor test ahead of it, and past the `.timeLimit` it is
# KILLED, which truncates the whole run (#3266). That is the remaining blocker on the parallel switch,
# and before this nobody could say how big it was.
#
# It REPORTS and does not refuse, deliberately, and the reason is worth knowing before anyone tries to
# make it a gate. Most main-actor suites here are main-actor for a real reason: 300 of the 462 files
# carrying the attribute touch SwiftData, whose containers are main-actor bound. A rule that refused a
# new one would fire on the ordinary case and be switched off within a day (L93). What this exists to
# make visible is the SHARE and which way it is moving, so a reduction is a number rather than a feeling.
#
# Read its answer correctly. Three exit codes, and the third is the one that matters: `2` is UNMEASURED,
# because a tree where no suite could be read and a tree with no main-actor suites in it leave the same
# empty result, and the emptiest possible failure must never read as the cleanest possible pass (L98).
#
# The unit is the SUITE, not the file: one file can declare several, and the queue is per suite's tests.
# A `@MainActor` on a nested helper inside a suite is not counted, because it isolates that helper rather
# than the tests.

REPO_ROOT="${REPO_ROOT_OVERRIDE:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

# main_actor_counts <dir> [dir ...]: prints "<suites> <mainActorSuites>" over the directories given.
#
# A suite's attributes may sit above the `@Suite` line or between it and the type declaration, and both
# spellings are in this tree, so the window is read in both directions and stops at the declaration.
main_actor_counts() {
  python3 - "$@" <<'PYTHON'
import pathlib, re, sys

DECLARATION = re.compile(r"^(final class|struct|class|actor|enum)\b")
suites = 0
main = 0
for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        lines = path.read_text(errors="replace").split("\n")
        for i, line in enumerate(lines):
            if not line.startswith("@Suite"):
                continue
            suites += 1
            window = []
            j = i - 1
            while j >= 0 and (lines[j].startswith("@") or lines[j].strip() == ""):
                window.append(lines[j])
                j -= 1
            j = i + 1
            while j < len(lines) and not DECLARATION.match(lines[j]):
                window.append(lines[j])
                j += 1
            if any(w.strip() == "@MainActor" for w in window):
                main += 1
print(f"{suites} {main}")
PYTHON
}

# main_actor_report <suites> <mainActorSuites> <previous share or empty>: the line to print.
#
# Pure, so both the measured case and the unmeasured one can be shown rather than watched not to happen.
main_actor_report() {
  suites="$1"
  main="$2"
  previous="${3:-}"
  if [ -z "${suites}" ] || [ "${suites}" -eq 0 ] 2>/dev/null; then
    printf '%s\n' "check-main-actor-share: UNMEASURED. No @Suite declaration was read at all, so this says nothing about the main actor (#3386, L98)."
    return 2
  fi
  share=$(( main * 100 / suites ))
  line="check-main-actor-share: ${main} of ${suites} suites are @MainActor (${share}%)."
  if [ -n "${previous}" ] && [ "${previous}" != "${share}" ]; then
    if [ "${share}" -gt "${previous}" ]; then
      line="${line} Up from ${previous}%, so the parallel-testing queue got longer (#3386)."
    else
      line="${line} Down from ${previous}%."
    fi
  fi
  printf '%s\n' "${line}"
  return 0
}

main_actor_share_main() {
  # Resolved HERE rather than at source time, so a fixture can point this at a tree of its own and watch
  # the unmeasured outcome actually happen (L1). A path resolved once at the top is a seam only the
  # process that started first can move.
  root="${REPO_ROOT_OVERRIDE:-${REPO_ROOT}}"
  # Beside the repository and gitignored, on `.overture-hosted-suite-seen`'s precedent (#1995) and for
  # its reason: it records what this MACHINE last saw, and a tracked file rewritten by every run is git
  # noise on every branch plus a conflict on every merge.
  #
  # Read HERE and not at the top of the file for the same reason as the root above, and it is not
  # theoretical: resolved at source time, the fixture's own override arrived too late and its runs wrote
  # their throwaway numbers into the repository's real record, which is precisely what a test must be
  # structurally unable to do (L2).
  record="${OVERTURE_MAIN_ACTOR_RECORD:-${root}/.overture-main-actor-share}"
  counts="$(main_actor_counts "${root}/mac/OvertureTests" "${root}/mac/OvertureHostedTests" 2>/dev/null || true)"
  suites="${counts%% *}"
  main="${counts##* }"
  # Guarded rather than redirected-and-silenced: an input redirection is processed BEFORE the `2>/dev/null`
  # that was meant to quieten it, so a machine with no record yet (every fresh clone, and the first run
  # after this shipped) printed a "No such file or directory" from the shell itself.
  previous=""
  if [ -r "${record}" ]; then
    previous="$(tr -d ' \n' < "${record}" 2>/dev/null || true)"
  fi
  main_actor_report "${suites}" "${main}" "${previous}"
  status=$?
  # Recorded only when it was really measured, so an unmeasured run cannot stamp a number nothing read
  # over the last real one (L98).
  if [ "${status}" -eq 0 ]; then
    printf '%s\n' "$(( main * 100 / suites ))" > "${record}" 2>/dev/null || true
  fi
  return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_actor_share_main
fi
