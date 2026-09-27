#!/usr/bin/env bash
# #4106, plan v7 probe 0c.9: an OPTIMISED test run, and the proof that it really was one.
#
# Every timing #4106 has taken so far came from a Debug build, where Swift compiles with -Onone and no
# generic is specialised, so a cost measured there can be an artefact of the build rather than of the
# code. Decision 5 of the plan (keep the queue generic over its models, or extract) cannot be answered
# from Debug numbers alone. This is the first route the plan named: the ordinary runner, with
# optimisation passed to xcodebuild as build setting overrides, OFF unless asked for.
#
# The overrides are only half of it. A setting a caller SETS holds only if nothing downstream recomputes
# it (L188), and a record of what was ASKED FOR says nothing about what was COMPILED (L416). So a run
# with the switch on reads its own build log for the compile invocations of the modules whose code the
# tests run, and refuses the run unless every one of them carried -O and -enable-testing and none carried
# -Onone. A run whose log holds no such invocation (a build that recompiled nothing can look exactly like
# that) is UNMEASURED, never a pass (L98).
#
# WHICH LINES, measured rather than assumed. The plan named "the swift-frontend lines", and on this Mac
# (Xcode with the macOS 27 SDK, 2026-09-27) a full Debug build's log holds ZERO of them: a SwiftCompile
# task prints only its file list, and the flags a module is compiled with appear once per module, on the
# `builtin-SwiftDriver -- .../swiftc -module-name <M> ...` line under its SwiftDriver task. That line is
# what the build system handed the compiler after every setting was resolved, which is the point L188
# makes. Both shapes are read, so a toolchain that does print frontend lines is still judged, and the
# microbenchmark (OptimisedBuildBenchmarkTests) is the downstream half: it reports how the code that RAN
# was compiled, from inside that code.
#
# TWO modules, not one, and the plan's wording names only the first. The pure suite does not link the
# app: `OvertureTests` COMPILES the app's sources into its own module (mac/project.yml, #1967), so every
# probe in that target runs code compiled as module `OvertureTests`. Only the hosted tests run code
# compiled as module `Overture`, through `@testable import`, which is what needs -enable-testing there.
# Checking `Overture` alone would verify a module the pure probes never execute.

# The switch. `1` turns it on; unset or empty leaves the run exactly as it always was. Anything else is
# refused by optimised_build_switch rather than read as either, because a typo silently giving a Debug
# run is the one outcome this whole thing exists to prevent.
OPTIMISED_BUILD_MODULES="Overture OvertureTests"

# How long an optimised run may stand still before the #3976 stall ending stops it, when nobody set
# OVERTURE_TEST_STALL_END_SECONDS. MEASURED, not chosen: on 2026-09-27 the whole module -O compile of
# OvertureTests (which holds the app's sources as well as every pure test) was ONE swift-frontend running
# about 25 minutes of CPU, while xcodebuild itself used 0.31s. The stall ending judges by xcodebuild's own
# CPU, so at its ordinary 1200s it ENDED that healthy build as STALLED. An hour is a little over twice the
# measured compile. Only an optimised run gets it; an ordinary run keeps 1200s.
OPTIMISED_STALL_END_SECONDS=3600

# optimised_build_switch. Prints "on" or "off", or prints a refusal on stderr and returns 2.
optimised_build_switch() {
  case "${OVERTURE_TEST_OPTIMISED:-}" in
    "") echo "off" ;;
    1) echo "on" ;;
    *)
      echo "run-tests-locked.sh: OVERTURE_TEST_OPTIMISED is '${OVERTURE_TEST_OPTIMISED}'. Set it to 1 for an optimised run, or leave it unset. Nothing was run." >&2
      return 2
      ;;
  esac
}

# optimised_build_overrides. The xcodebuild build setting overrides for an optimised run, one per line.
#
# What Release compiles Swift with (-O, whole module), while keeping testability on so the hosted
# tests' `@testable import Overture` still resolves. DEBUG stays in the active compilation conditions on
# purpose: tests reach `#if DEBUG` seams, and taking them away would stop the suite building rather
# than make it faster. So this is Release's OPTIMISER, not Release's configuration.
optimised_build_overrides() {
  printf '%s\n' \
    "SWIFT_OPTIMIZATION_LEVEL=-O" \
    "SWIFT_COMPILATION_MODE=wholemodule" \
    "ENABLE_TESTABILITY=YES"
}

# optimised_build_verdict <build log>. One line, starting VERIFIED, REFUSED or UNMEASURED.
#
# Reads every compile invocation in the log (a swift-frontend line, or the swiftc line under a
# SwiftDriver task) whose -module-name is one of OPTIMISED_BUILD_MODULES.
# REFUSED wins over UNMEASURED, since a module compiled at -Onone is a finding whatever else is missing.
optimised_build_verdict() {
  local output="$1"
  awk -v wanted="${OPTIMISED_BUILD_MODULES}" '
    BEGIN {
      n = split(wanted, names, " ")
      for (i = 1; i <= n; i++) { seen[names[i]] = 0; unopt[names[i]] = 0; untest[names[i]] = 0 }
    }
    /swift-frontend|builtin-SwiftDriver/ {
      module = ""; has_o = 0; has_onone = 0; has_testing = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "-module-name" && i < NF) module = $(i + 1)
        else if ($i == "-O") has_o = 1
        else if ($i == "-Onone") has_onone = 1
        else if ($i == "-enable-testing") has_testing = 1
      }
      if (!(module in seen)) next
      seen[module]++
      if (!has_o || has_onone) unopt[module]++
      if (!has_testing) untest[module]++
    }
    END {
      refused = ""; missing = ""; counts = ""
      for (i = 1; i <= n; i++) {
        m = names[i]
        if (unopt[m] > 0) refused = refused sprintf(" %s was compiled WITHOUT optimisation in %d of its %d compile invocation(s) (-Onone, or no -O).", m, unopt[m], seen[m])
        if (untest[m] > 0) refused = refused sprintf(" %s was compiled WITHOUT -enable-testing in %d of its %d compile invocation(s).", m, untest[m], seen[m])
        if (seen[m] == 0) missing = missing (missing == "" ? "" : ", ") m
        counts = counts (counts == "" ? "" : ", ") sprintf("%s %d", m, seen[m])
      }
      if (refused != "") {
        print "REFUSED:" refused " An override was passed and the compiler did not get it (L188), so no timing from this run is an optimised one."
      } else if (missing != "") {
        print "UNMEASURED: no compile invocation for " missing " appears in this run'"'"'s log, so nothing shows how that code was compiled. A build that recompiled nothing looks exactly like this: clean the build folder, or change a source file, and run again."
      } else {
        print "VERIFIED: every compile invocation carried -O and -enable-testing and none carried -Onone (" counts ")."
      }
    }
  ' <<< "${output}"
}

# optimised_build_evidence <build log>. Only the lines the verdict reads, so a run can keep them across
# a retry without holding the whole log: a retried attempt usually recompiles nothing, and judging it
# alone would read UNMEASURED about a build the first attempt did verifiably optimise.
optimised_build_evidence() {
  grep -aE 'swift-frontend|builtin-SwiftDriver' <<< "$1" || true
}
