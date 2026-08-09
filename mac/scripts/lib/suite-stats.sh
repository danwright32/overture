#!/usr/bin/env bash
# The test suite's own shape, reported by the run that just happened (#2193, #2232).
#
# Why this exists rather than a number in a document. AGENTS.md stated both targets' sizes as
# hand-written figures and both had drifted, one by 768 tests. That is worse than a stale number,
# because of what the same document uses those figures FOR: it warns that a scoped run can print
# `** TEST SUCCEEDED **` having executed nothing at all, and says the way to tell is to check what
# actually ran. A stated total is exactly the reference someone would check against, so a wrong one
# quietly weakens the guard the document is trying to give. L32 is the standing rule: measured
# numbers are generated or omitted, never hand-written.
#
# So the run prints its own shape, every time, and the document points at that instead of restating
# it. A live reference cannot drift, and it is there at the moment it is needed rather than in a
# file someone has to remember to open.
#
# Everything here is pure. The caller does the reading and counting and hands the text in.

# The totals the run actually executed, as "tests suites seconds", or EMPTY when the output carries
# no such line at all.
#
# Summed across targets, not taken from the last line. A run of the combined scheme prints one line
# per target, and reading only the last would report the hosted suite's couple of hundred as though
# it were the whole suite, which is precisely the "this run executed almost nothing" misreading
# these numbers exist to let someone catch.
#
# Empty rather than zero when nothing matched. A run that executed nothing and a readout that could
# not parse the output are different facts, and reporting the second as "0 tests" would state a
# measurement that was never made.
test_run_totals() {
  local output="$1"
  # #2317: `tests?` and `suites?`, because Swift Testing writes the words singular when there is one of
  # something ("Test run with 10 tests in 1 suite passed"). Only knowing the plural made a real scoped run
  # read as one that executed nothing, which is the same false alarm the empty-run gate exists to avoid
  # ever raising.
  printf '%s\n' "${output}" | awk '
    match($0, /Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed) after [0-9.]+ seconds/) {
      line = substr($0, RSTART, RLENGTH)
      split(line, f, " ")
      # Test run with <4> tests in <7> suites passed after <11> seconds
      tests += f[4]; suites += f[7]; seconds += f[11]
      seen = 1
    }
    END { if (seen) printf "%d %d %.3f\n", tests, suites, seconds }
  '
}

# Test Swift measured against app Swift, to two decimal places, or "unknown" when it cannot be a
# ratio. Never a fabricated stand-in: an app line count of zero means the counting is broken, and
# saying so beats printing a number nobody can act on.
line_ratio() {
  local app_lines="$1" test_lines="$2"
  if [[ ! "${app_lines}" =~ ^[0-9]+$ ]] || [[ "${app_lines}" -eq 0 ]]; then
    echo "unknown"
    return 0
  fi
  awk -v a="${app_lines}" -v t="${test_lines}" 'BEGIN { printf "%.2f\n", t / a }'
}

# The one line the run prints. Each of the three facts is stated only if it was measured, and named
# as unmeasured otherwise, so the report can never claim a number this run did not establish.
#
# The guard share is quoted against test DECLARATIONS rather than against the run's test count, and
# says so. Measured 2026-08-08 the two agree exactly (5923 and 254 per target, against 5923 and 254
# declarations, with 8 parameterised tests that evidently do not multiply this summary line), but
# they are still separate quantities and nothing holds them equal: a disabled test, a conditionally
# compiled one, or a future Swift Testing that counts cases rather than functions would part them.
# A share formed by dividing a count read off the source by a count read off the run would then be
# a percentage of nothing real, and would keep looking plausible (L63).
format_suite_report() {
  local totals="$1" ratio="$2" guard_decls="$3" total_decls="$4"
  local out="Suite shape: "

  if [[ -n "${totals}" ]]; then
    local tests suites seconds
    read -r tests suites seconds <<< "${totals}"
    # #2317: a scoped run really can be one suite, and now that scoped runs go through this wrapper the
    # readout says so in words rather than "1 suites".
    out+="${tests} test$([[ "${tests}" == 1 ]] || echo s)"
    out+=" in ${suites} suite$([[ "${suites}" == 1 ]] || echo s), ${seconds}s."
  else
    out+="could not read the test totals from this run."
  fi

  if [[ "${ratio}" == "unknown" || -z "${ratio}" ]]; then
    out+=" Test Swift to app Swift could not be measured."
  else
    out+=" Test Swift to app Swift ${ratio} to 1."
  fi

  if [[ "${total_decls}" =~ ^[0-9]+$ ]] && [[ "${total_decls}" -gt 0 ]]; then
    out+=" Source-text guards are ${guard_decls} of ${total_decls} test declarations."
  else
    out+=" Source-text guard share could not be measured."
  fi

  echo "${out}"
}

# ---------------------------------------------------------------------------
# Below this line the functions read the repository. Everything above is pure.
# ---------------------------------------------------------------------------

# Lines of Swift under a directory, or 0 when it holds none. Counted rather than stated, which is
# the whole point of the file.
swift_lines_under() {
  local dir="$1"
  [[ -d "${dir}" ]] || { echo 0; return 0; }
  find "${dir}" -name '*.swift' -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' '
}

# `@Test` declarations under a directory, read off the source. Called a declaration rather than a
# test because that is all this can honestly claim: it counts what is written, not what ran.
test_declarations_under() {
  local dir="$1"
  [[ -d "${dir}" ]] || { echo 0; return 0; }
  grep -rho '@Test' "${dir}" --include='*.swift' 2>/dev/null | wc -l | tr -d ' '
}

# `@Test` declarations in files that read the app's SOURCE rather than run it: the copy inventory,
# the view-copy guard, the dash guard and their kin, all of which reach the code through
# SwiftSource, SourceGuardHelper or CopyInventory.
#
# Worth watching as a share because these prove something about how the code is WRITTEN, not about
# what it does. A suite drifting towards them is drifting away from testing behaviour, and that is
# visible in a number and invisible in any one diff.
source_guard_declarations_under() {
  local dir="$1"
  [[ -d "${dir}" ]] || { echo 0; return 0; }
  local file total=0
  while IFS= read -r file; do
    total=$(( total + $(grep -o '@Test' "${file}" 2>/dev/null | wc -l | tr -d ' ') ))
  done < <(grep -rl -E 'SwiftSource|SourceGuardHelper|CopyInventory' "${dir}" --include='*.swift' 2>/dev/null)
  echo "${total}"
}

# The whole readout for a finished run, given that run's output and the repo's mac directory.
suite_report_for_run() {
  local output="$1" mac_dir="$2"
  local app_lines test_lines guard_decls total_decls

  app_lines="$(swift_lines_under "${mac_dir}/Overture")"
  test_lines=$(( $(swift_lines_under "${mac_dir}/OvertureTests") \
               + $(swift_lines_under "${mac_dir}/OvertureHostedTests") \
               + $(swift_lines_under "${mac_dir}/TestSupport") ))
  total_decls=$(( $(test_declarations_under "${mac_dir}/OvertureTests") \
                + $(test_declarations_under "${mac_dir}/OvertureHostedTests") ))
  guard_decls=$(( $(source_guard_declarations_under "${mac_dir}/OvertureTests") \
                + $(source_guard_declarations_under "${mac_dir}/OvertureHostedTests") ))

  format_suite_report "$(test_run_totals "${output}")" \
                      "$(line_ratio "${app_lines}" "${test_lines}")" \
                      "${guard_decls}" "${total_decls}"
}
