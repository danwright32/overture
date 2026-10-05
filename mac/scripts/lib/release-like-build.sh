#!/usr/bin/env bash
# #4343 (E0): a RELEASE-LIKE test run, and the proof that it really was one.
#
# The optimised run (#4106, lib/optimised-build.sh) gives the suite Release's optimiser and deliberately
# keeps DEBUG on, because the test targets reach `#if DEBUG` seams. That leaves every `#if DEBUG` block in
# the app compiled IN: the queue's render counter and its log, the landing's Debug-only table snapshots,
# the masthead's Debug label. Code Dan's installed app never runs is then inside every timing, so a hold
# measured on an optimised run is still not a hold the Release app has. Phase E of #4275 judges the scout
# landing against 100 ms per main thread turn, and that has to be read on code shaped like what ships.
#
# So this run takes Release's optimiser AND removes DEBUG from the active compilation conditions, keeping
# testability on. Three things make that possible, and each is load bearing:
#
#   - DEBUG reaches the compiler through ONE project variable, `OVERTURE_DEBUG_CONDITION` (mac/project.yml).
#     A command line override of the conditions themselves would replace every target's value, the hosted
#     target's OVERTURE_HOSTED_TESTS included; replacing the variable removes DEBUG from every target at
#     once and keeps what each target adds. It is replaced by a MARKER, OVERTURE_RELEASE_LIKE, rather than
#     emptied, so the compile line itself shows the override reached the compiler (L319, L188).
#   - The run builds the PURE suite's scheme, OvertureCore, never the full one, and leaves out of it the pure
#     test files that cannot compile without DEBUG: every file naming a Debug-only app symbol outside
#     `#if DEBUG`, and every file using one of those. The list is DERIVED, by `ReleaseLikeBuildExclusionsTests`
#     in every ordinary run, from the app's `#if DEBUG` declarations and the test sources, and committed
#     beside this file (release-like-excluded-tests.txt), which that test fails on when it is stale. Measured
#     2026-10-05: 10 pure files and 15 hosted files named one. The hosted target is not built at all, for that
#     reason; no probe that matters to the release-like reading lives there.
#     Left out rather than wrapped in `#if DEBUG` in the files themselves, because a wrapped region is
#     invisible to every source guard that skips Debug code (the window, store and container scans), so a
#     wrap would quietly take those files out of the guards' reach in every ORDINARY run (L708).
#   - The verdict below reads the build log, as the optimised run's does, and refuses the run unless every
#     compile of the module the pure probes run (OvertureTests, which compiles the app's sources into
#     itself) carried -O, -enable-testing and the marker, and none carried -Onone or DEBUG.
#
# The probe asserts it a second time from inside the compiled code (`#if DEBUG`), because a log check
# proves what the compiler was HANDED and only the code can say what it was compiled AS (L416).

# The pure test module, the only one this run builds that the probes execute.
RELEASE_LIKE_BUILD_MODULES="OvertureTests"
RELEASE_LIKE_SCHEME="OvertureCore"
RELEASE_LIKE_MARKER="OVERTURE_RELEASE_LIKE"

# release_like_build_switch. Prints "on" or "off", or prints a refusal on stderr and returns 2.
release_like_build_switch() {
  case "${OVERTURE_TEST_RELEASE_LIKE:-}" in
    "") echo "off" ;;
    1) echo "on" ;;
    *)
      echo "run-tests-locked.sh: OVERTURE_TEST_RELEASE_LIKE is '${OVERTURE_TEST_RELEASE_LIKE}'. Set it to 1 for a release-like run, or leave it unset. Nothing was run." >&2
      return 2
      ;;
  esac
}

# release_like_build_overrides. The optimised run's overrides (one definition, never a copy), then the two
# that take DEBUG out: the Swift condition through the project variable, and the C side's DEBUG=1, which
# the Debug configuration's preprocessor definitions would otherwise hand the clang importer.
release_like_build_overrides() {
  optimised_build_overrides
  printf '%s\n' \
    "OVERTURE_DEBUG_CONDITION=${RELEASE_LIKE_MARKER}" \
    "GCC_PREPROCESSOR_DEFINITIONS=${RELEASE_LIKE_MARKER}=1"
}

# The derived list of pure test files the release-like build leaves out. A seam, so the fixture can hand the
# runner a list of its own; every real run reads the committed one.
RELEASE_LIKE_EXCLUSIONS_FILE="${OVERTURE_RELEASE_LIKE_EXCLUSIONS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-like-excluded-tests.txt}"

# release_like_build_exclusions [file]. The file names to leave out, space separated on one line, from the
# list's lines that are neither blank nor a comment. A list that cannot be read refuses (status 2) rather than
# reading as "nothing to leave out", which would hand the build files that cannot compile and look like a
# broken build rather than a missing list (L215).
release_like_build_exclusions() {
  local file="${1:-${RELEASE_LIKE_EXCLUSIONS_FILE}}"
  if [[ ! -r "${file}" ]]; then
    echo "run-tests-locked.sh: the release-like exclusion list ${file} cannot be read, so the build cannot be told which test files need DEBUG. Run ReleaseLikeBuildExclusionsTests with TEST_RUNNER_REGENERATE_RELEASE_LIKE_EXCLUSIONS=1 to write it. Nothing was run." >&2
    return 2
  fi
  awk '!/^[[:space:]]*(#|$)/ { gsub(/[[:space:]]/, ""); printf "%s%s", (n++ ? " " : ""), $0 } END { if (n) print "" }' "${file}"
}

# release_like_build_verdict <build log>. One line, starting VERIFIED, REFUSED or UNMEASURED.
#
# DEBUG is read as the condition in all three spellings a compile line can carry it: `-DDEBUG`, `-D DEBUG`,
# and the clang importer's `-DDEBUG=<value>`. A word that merely begins with DEBUG is a different condition.
release_like_build_verdict() {
  local output="$1"
  awk -v wanted="${RELEASE_LIKE_BUILD_MODULES}" -v marker="-D${RELEASE_LIKE_MARKER}" '
    BEGIN {
      n = split(wanted, names, " ")
      for (i = 1; i <= n; i++) { seen[names[i]] = 0; unopt[names[i]] = 0; untest[names[i]] = 0; debug[names[i]] = 0; unmarked[names[i]] = 0 }
    }
    /swift-frontend|builtin-SwiftDriver/ {
      module = ""; has_o = 0; has_onone = 0; has_testing = 0; has_debug = 0; has_marker = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "-module-name" && i < NF) module = $(i + 1)
        else if ($i == "-O") has_o = 1
        else if ($i == "-Onone") has_onone = 1
        else if ($i == "-enable-testing") has_testing = 1
        else if ($i == marker) has_marker = 1
        else if ($i == "-DDEBUG" || $i ~ /^-DDEBUG=/) has_debug = 1
        else if ($i == "-D" && i < NF && $(i + 1) == "DEBUG") has_debug = 1
      }
      if (!(module in seen)) next
      seen[module]++
      if (!has_o || has_onone) unopt[module]++
      if (!has_testing) untest[module]++
      if (has_debug) debug[module]++
      if (!has_marker) unmarked[module]++
    }
    END {
      refused = ""; missing = ""; counts = ""
      for (i = 1; i <= n; i++) {
        m = names[i]
        if (unopt[m] > 0) refused = refused sprintf(" %s was compiled WITHOUT optimisation in %d of its %d compile invocation(s) (-Onone, or no -O).", m, unopt[m], seen[m])
        if (untest[m] > 0) refused = refused sprintf(" %s was compiled WITHOUT -enable-testing in %d of its %d compile invocation(s).", m, untest[m], seen[m])
        if (debug[m] > 0) refused = refused sprintf(" %s was compiled WITH DEBUG in %d of its %d compile invocation(s).", m, debug[m], seen[m])
        if (unmarked[m] > 0) refused = refused sprintf(" %s was compiled WITHOUT %s in %d of its %d compile invocation(s), so nothing shows the override reached the compiler.", m, marker, unmarked[m], seen[m])
        if (seen[m] == 0) missing = missing (missing == "" ? "" : ", ") m
        counts = counts (counts == "" ? "" : ", ") sprintf("%s %d", m, seen[m])
      }
      if (refused != "") {
        print "REFUSED:" refused " So no timing from this run is a release-like one."
      } else if (missing != "") {
        print "UNMEASURED: no compile invocation for " missing " appears in this run'"'"'s log, so nothing shows how that code was compiled. A build that recompiled nothing looks exactly like this: clean the build folder, or change a source file, and run again."
      } else {
        print "VERIFIED: every compile invocation carried -O, -enable-testing and " marker ", and none carried -Onone or DEBUG (" counts ")."
      }
    }
  ' <<< "${output}"
}

# release_like_build_evidence <build log>. The compile lines alone, kept across a retry for the reason the
# optimised run keeps them (a retry usually recompiles nothing).
release_like_build_evidence() {
  grep -aE 'swift-frontend|builtin-SwiftDriver' <<< "$1" || true
}
