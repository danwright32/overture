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
  local output="$1" serial
  # #2317: `tests?` and `suites?`, because Swift Testing writes the words singular when there is one of
  # something ("Test run with 10 tests in 1 suite passed"). Only knowing the plural made a real scoped run
  # read as one that executed nothing, which is the same false alarm the empty-run gate exists to avoid
  # ever raising.
  # #3233 read the serial summary FIRST and used the line count only where there was none, on the
  # reasoning that a summary is xcodebuild's own total rather than one derived by counting. #3266
  # reversed that: a log carrying BOTH is a mixed run, and the two describe different testables. See
  # the summing below.
  serial="$(printf '%s\n' "${output}" | awk '
    match($0, /Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed) after [0-9.]+ seconds/) {
      line = substr($0, RSTART, RLENGTH)
      split(line, f, " ")
      # Test run with <4> tests in <7> suites passed after <11> seconds
      tests += f[4]; suites += f[7]; seconds += f[11]
      seen = 1
    }
    END { if (seen) printf "%d %d %.3f\n", tests, suites, seconds }
  ')"
  local parallel
  parallel="$(test_run_totals_parallel "${output}")"

  # #3266: the two readings are SUMMED, not preferred between, because a run can carry both. Setting
  # one testable parallel and leaving the other serial is exactly what the parallel work does, and such
  # a run prints per-test lines for the parallel testable and a summary for the serial one. Preferring
  # the summary read the hosted suite's 300 as the whole run: measured 2026-08-30, a COMPLETE run
  # (8,323 parallel names plus that 300, against a baseline of 8,624) was reported as 300 and refused by
  # the short-run gate. Under-reporting by 96% makes the gate block a healthy push, which is the failure
  # that gets a gate switched off rather than the one that gets it trusted.
  #
  # Summing cannot double count, and that is measured rather than assumed: a serial run prints NO
  # `Test case ... on 'My Mac - xctest (N)'` lines at all (checked over a full serial run, 2026-08-30),
  # so the per-test lines only ever belong to a parallel testable and the summaries only ever to a
  # serial one.
  if [[ -n "${serial}" && -n "${parallel}" ]]; then
    # The DURATION is not summed. The parallel reading takes the run's own elapsed line, which already
    # spans both testables, so adding the serial half's seconds to it would count that stretch twice.
    awk -v s="${serial}" -v p="${parallel}" '
      BEGIN {
        split(s, a, " "); split(p, b, " ")
        if (b[3] == "unknown") printf "%d %d unknown\n", a[1] + b[1], a[2] + b[2]
        else                   printf "%d %d %.3f\n", a[1] + b[1], a[2] + b[2], b[3]
      }'
    return 0
  fi
  if [[ -n "${serial}" ]]; then
    printf '%s\n' "${serial}"
    return 0
  fi
  printf '%s' "${parallel}"
  [[ -n "${parallel}" ]] && echo
  return 0
}

# The same totals for a run under `-parallel-testing-enabled YES`, which prints NO summary line at
# all (#3233). Empty when the output carries no test line either, for test_run_totals' own reason:
# a reading that could not be taken is not a reading of none.
#
# Every test is reported on its own line instead of being summed for you:
#
#   Test case 'Suite/test()' passed on 'My Mac - xctest (63822)' (0.013 seconds)
#
# Three things about deriving a total from those lines, each of which was wrong in the obvious
# version of this.
#
# Counted by NAME, not by line. A parameterised test prints one line per case and a retried one
# prints its line again, so a line count reports more tests than ran. It is wrong in the one
# direction that matters: the number feeds the short-run gate, and an over-count makes a truncated
# run look longer than it was.
#
# The SECONDS never come from those lines. Each ends in "(N seconds)" and N is elapsed since that
# WORKER began, not what the test cost: in the measured log a one-line boolean reported 64.4
# seconds, and summing the fixture beside this file gives 338.423s for a run that took 95.447. Both
# numbers look entirely plausible, which is why this reads the run's own elapsed line or reports
# nothing.
#
# And a lost elapsed reading does not destroy the counts. They are separate measurements, and the
# duration is the one the format is least able to protect: in the measured log two workers wrote at
# the same instant and the elapsed reading survived only by being glued onto the end of a
# half-written test case line. So an unreadable one is named "unknown" here and named in words by
# format_suite_report, while the counts, which are what gates the run, still arrive.
test_run_totals_parallel() {
  local output="$1"
  printf '%s\n' "${output}" | awk -v q="'" '
    BEGIN { line_rx = "^Test case " q "[^" q "]+" q " (passed|failed|skipped) on " }
    $0 ~ line_rx {
      rest = substr($0, length("Test case " q) + 1)
      name = substr(rest, 1, index(rest, q) - 1)
      if (!(name in seen_test)) { seen_test[name] = 1; tests++ }
      slash = index(name, "/")
      suite = (slash > 0) ? substr(name, 1, slash - 1) : name
      if (!(suite in seen_suite)) { seen_suite[suite] = 1; suites++ }
    }
    !have_elapsed && match($0, /[0-9]+(\.[0-9]+)? elapsed -- Testing started completed/) {
      split(substr($0, RSTART, RLENGTH), f, " ")
      elapsed = f[1]; have_elapsed = 1
    }
    END {
      if (tests > 0) {
        if (have_elapsed) printf "%d %d %.3f\n", tests, suites, elapsed
        else              printf "%d %d unknown\n", tests, suites
      }
    }
  '
}

# Prints "restarted" when xcodebuild relaunched the test process partway through this run, and
# nothing otherwise (#2821).
#
# Why this is worth its own reading. A restart makes every count below it a count of the REMAINDER.
# Measured 2026-08-16 while re-checking #2808's mutations: mutated code made a test exceed its one
# minute .timeLimit, which kills the test process; xcodebuild restarted and ran what was left, and
# the readout said "12 tests in 2 suites" for a run that had really started 70 tests across 8
# suites. xcodebuild's own message promises the summary "will include totals from previous
# launches", and that measurement says it did not, which is exactly why the totals cannot be
# believed and cannot be summed either.
#
# Matched on xcodebuild's own sentence. The same phrase is already what pure_failure_evidence in
# run-tests-locked.sh keeps as a named cause, so this is a shape this repo has captured rather than
# one invented here.
test_run_restarted() {
  local output="$1"
  grep -qa 'Restarting after unexpected exit' <<< "${output}" && echo "restarted"
  return 0
}

# Every test xcodebuild named under its own "Failing tests:" heading, one per line, trimmed of the
# tab it indents them by. Empty when it named none, which is a real and different state: a run that
# reports failure and names NOTHING did not fail, it died (#1006).
#
# One implementation, because three places read this same block and all three have to agree about
# what a named failure is: run_outcome's crashed-versus-failed decision, pure_failure_evidence, and
# the reprint below.
failing_test_names() {
  local output="$1"
  awk '/^Failing tests:/{f=1;next} /^\*\* TEST/{f=0} f' <<< "${output}" \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -a '[^[:space:]]' || true
}

# The failing test list, reprinted with its count, or nothing when this run named no failing test
# (#2600).
#
# Why a reprint rather than "read the log". A failed run reports its failures two different ways and
# reading the log for one of them UNDER-COUNTS: Swift Testing prints "Expectation failed:" for an
# #expect, while a guard raising Issue.record prints only "recorded an issue". On 2026-08-12 a run
# of #2417's branch was read by searching for the first phrase, reported as two failures, and
# actually had eight, and twenty minutes of work followed from believing the branch was nearly
# green. xcodebuild's own block is the honest answer and was in the output the whole time, roughly
# forty thousand lines down a log nobody reads to the end, which is why the cheap partial reading is
# the one anybody working at speed reaches for.
#
# Deliberately uncapped. The list is the whole point, and a cap would reintroduce an under-count at
# exactly the size where one matters most; the count leads so a very long list announces itself
# before it scrolls.
# Since #3348 it also carries each failure's REASON, when it is given a result bundle to read one from.
# Under `-parallel-testing-enabled YES` the reason does not reach the log at all: a worker's stdout does
# not reach xcodebuild's, and Swift Testing writes an issue's text there. Measured 2026-08-30, three full
# parallel runs carrying three real failures between them held ZERO occurrences of `Expectation failed`
# or `recorded an issue`, so a red run was a list of names nobody could diagnose from, and the reason
# behind the one that mattered was read out of the bundle by hand.
#
# BESIDE the names, never instead of them. The block above is xcodebuild's own list and is what the count
# is taken from; this adds a line under each name.
#
# The second argument may be an empty string, which is its own outcome (this run named no bundle) and
# gets its own sentence. Called with ONE argument it is the list alone, exactly as before.
failing_tests_report() {
  local output="$1" names count
  local bundle="" offered=0
  if [[ "$#" -ge 2 ]]; then
    offered=1
    bundle="$2"
  fi
  names="$(failing_test_names "${output}")"
  # A green run reads no bundle whatever it was handed: the count call already costs 6.2s and a run with
  # nothing to report must not pay for a second one.
  [[ -n "${names}" ]] || return 0
  count="$(grep -c . <<< "${names}")"
  echo "FAILING TEST$([[ "${count}" == 1 ]] || echo S) (${count}), reprinted so the list is the last thing on screen:"
  if [[ "${offered}" -eq 0 ]]; then
    sed 's/^/  /' <<< "${names}"
    return 0
  fi
  if [[ -z "${bundle}" ]]; then
    sed 's/^/  /' <<< "${names}"
    echo "  REASONS NOT READ - this run named no result bundle, so these are names without reasons."
    return 0
  fi
  local reasons=""
  if ! reasons="$(result_bundle_failure_reasons "${bundle}")"; then
    sed 's/^/  /' <<< "${names}"
    echo "  REASONS NOT READ - the result bundle could not be read, so these are names without reasons:"
    echo "    ${bundle}"
    return 0
  fi
  # Paired by SUFFIX, in both directions, because the two spellings differ by a target prefix that is
  # present in some runs and not others: the block has written both `OvertureTests.FooTests.bar()` and
  # `LoopbackListenerTests.bindsToARealNonZeroPort()`, and the bundle writes the suite and test alone.
  # Matching on the shorter one being the tail of the longer is specific enough for a name carrying its
  # suite, and it does not invent a rule about which prefix a given xcodebuild version prints.
  # The names reach awk through the ENVIRONMENT rather than through -v, because -v processes escapes and
  # refuses a real newline, and this list is one name per line.
  NAMES="${names}" awk -F'\t' '
    { key[NR] = $1; text[NR] = $2; n = NR }
    END {
      split(ENVIRON["NAMES"], want, "\n")
      for (i = 1; i in want; i++) {
        name = want[i]
        if (name == "") continue
        print "  " name
        found = ""
        for (j = 1; j <= n; j++) {
          k = key[j]
          if (k == "") continue
          if (k == name \
              || (length(k) < length(name) && substr(name, length(name) - length(k) + 1) == k) \
              || (length(name) < length(k) && substr(k, length(k) - length(name) + 1) == name)) {
            found = text[j]
            break
          }
        }
        if (found == "") {
          print "      NO REASON IN THE BUNDLE - this run recorded no failure text for this test."
        } else {
          print "      " found
        }
      }
    }
  ' <<< "${reasons}"
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
#
# #2821: a run whose test process RESTARTED gets no shape at all, and is told so. The counts after a
# restart are counts of the remainder, and this line is the one AGENTS.md names as THE reference for
# "did this run execute the whole suite?". Reporting a small number for a run that was broken rather
# than small is the single reading it must never produce, so it states none: not the totals, not the
# ratio, not the guard share, because a plausible-looking figure standing beside a warning is what
# makes a remainder readable as a measurement in the first place.
# #3243 / #3265: the run's own RESULT BUNDLE, which is where the trustworthy count lives.
#
# WHY NOT THE LOG. Everything above reads xcodebuild's stdout. In a parallel run that stdout is written
# by several worker processes at once and their lines can collide: in the 2026-08-29 experiment log
# exactly one per-test line was corrupted that way, which is why the readable count was 4,874 against
# the bundle's 4,875. One test is immaterial against a 10 percent tolerance. What is not immaterial is
# that the only thing bounding the error is how often two workers happen to write in the same instant,
# which nothing measures and which gets worse with more workers.
#
# WHY IT ALSO SETTLES #3265, which is the sharper half. The short-run gate compares a parallel run's
# count against a baseline recorded by a SERIAL run, and until now the two were produced differently:
# a summary line on one side, distinct per-test NAMES on the other. Measured 2026-08-30, 8,612 by name
# in parallel against a serial 8,618, with `CityFromAddressTests` alone printing 17 case lines under 6
# distinct names. Two numbers being CLOSE is worse than their being obviously different, because it
# reads as trustworthy while comparing two things that are not the same quantity.
#
# `totalTestCount` is ONE quantity however the run was parallelised, and it is by NAME. Measured
# 2026-08-30 on a real serial run: `totalTestCount` 8,626 against a summary line of 8,626, while the
# same bundle's per-configuration figures come to 8,801 because 45 tests ran with dynamic parameters
# over 220 runs. Names on both sides of the comparison, which is what the gate needs.
#
# The path is taken from the run's own output rather than from a `-resultBundlePath` this script sets,
# because xcodebuild prints where it wrote the bundle whether anybody asked for a path or not, and a
# path this script chose would have to be cleaned up by this script.
test_run_result_bundle() {
  local output="$1"
  # The LAST one. A retried run (the #1331 app-host flake) writes a second bundle, and the run whose
  # result anybody is reading is the last attempt, not the one that died.
  printf '%s\n' "${output}" | awk '
    /\.xcresult$/ {
      line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line ~ /\.xcresult$/) last = line
    }
    END { if (last != "") print last }
  '
}

# The count out of one bundle, or NOTHING. Every way the reading can fail comes back empty rather than
# zero, and that is the whole contract: zero is a real measurement (a run that executed nothing) which
# the empty-run gate acts on, so a failed read arriving as zero would fail a healthy run and name the
# wrong cause (L98, L11).
#
# OVERTURE_XCRESULTTOOL is the seam, so a fixture can drive every one of those failures without a real
# bundle. It defaults to the real tool.
result_bundle_total_test_count() {
  local bundle="$1"
  [[ -n "${bundle}" ]] || return 0
  local tool=("${OVERTURE_XCRESULTTOOL:-}")
  if [[ -z "${OVERTURE_XCRESULTTOOL:-}" ]]; then
    tool=(xcrun xcresulttool)
  fi
  local summary
  summary="$("${tool[@]}" get test-results summary --path "${bundle}" 2>/dev/null)" || return 0
  [[ -n "${summary}" ]] || return 0
  local count
  count="$(printf '%s' "${summary}" | jq -r 'if type == "object" and (.totalTestCount | type) == "number" then .totalTestCount else empty end' 2>/dev/null)" || return 0
  [[ "${count}" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "${count}"
}

# The test whose EXECUTION TIME ALLOWANCE ran out, or nothing (#3266).
#
# This is the missing half of #2821's restart detection, and it is the cause of every short run this
# repository has recorded. A test that exceeds its `.timeLimit` is KILLED, xcodebuild relaunches the test
# process and carries on, and the totals it prints afterwards are the totals of the remainder.
#
# Measured 2026-08-30 over twenty-three full parallel runs: seventeen COMPLETE runs carry no such
# failure, and all six SHORT runs carry exactly one. There is no third case.
#
# Nothing in the log says so. `test_run_restarted` greps for `Restarting after unexpected exit`, and that
# phrase, along with `unexpected exit`, `terminated` and `crashed`, appears ZERO times in every one of
# those short-run logs: xcodebuild prints NOTHING at the relaunch, and the next line is simply a test on
# a new pid. So the run reported a plausible small number, which is the one answer #2821 says it must
# never give, and the cause went undiagnosed across three sessions.
#
# Read from the RESULT BUNDLE, from the same `summary` call the count already makes, so it costs no
# extra `xcresulttool` invocation. The wording is Swift Testing's own
# ("Test exceeded execution time allowance of 1 minute"), matched on the stable part of it rather than
# on the duration, so a suite that declares a different `.timeLimit` is covered without anything being
# listed here (L96).
#
# Every way the read can fail comes back EMPTY, never as a false "no kill": an unreadable bundle must
# not read as a clean run, and the caller keeps whatever the log-based check already said (L98).
result_bundle_time_limit_kill() {
  local bundle="$1"
  [[ -n "${bundle}" ]] || return 0
  local tool=("${OVERTURE_XCRESULTTOOL:-}")
  if [[ -z "${OVERTURE_XCRESULTTOOL:-}" ]]; then
    tool=(xcrun xcresulttool)
  fi
  local summary
  summary="$("${tool[@]}" get test-results summary --path "${bundle}" 2>/dev/null)" || return 0
  [[ -n "${summary}" ]] || return 0
  printf '%s' "${summary}" \
    | jq -r 'if type == "object" and (.testFailures | type) == "array"
             then (.testFailures[] | select((.failureText // "") | test("execution time allowance")) | .testName // empty)
             else empty end' 2>/dev/null \
    | head -n 1
  return 0
}

# Every failure the run's result bundle records, one per line, as the test's identifier and a TAB and the
# reason (#3348).
#
# Read from the same `get test-results summary` call the executed count already makes, so a red run pays
# for no second `xcresulttool` invocation and nothing has to be added to the tests themselves.
#
# The identifier is normalised to xcodebuild's own `Suite.test()` spelling, since the bundle writes
# `Suite/test()` and the `Failing tests:` block writes dots: a reason that cannot be paired with a name
# is no use to the person reading the screen.
#
# One line per failure whatever the reason contains. Swift Testing routinely records a multi-line body in
# an expectation's text, and a reason spilling onto its own lines would read as several failures.
#
# Unlike its neighbours this one answers with its STATUS as well as its output: 1 when the bundle could
# not be READ at all, 0 when it was. An unreadable bundle and a run whose failures carry no text look
# identical from an empty answer, and the caller has to say which it met (L98, L11).
result_bundle_failure_reasons() {
  local bundle="$1"
  [[ -n "${bundle}" ]] || return 1
  local tool=("${OVERTURE_XCRESULTTOOL:-}")
  if [[ -z "${OVERTURE_XCRESULTTOOL:-}" ]]; then
    tool=(xcrun xcresulttool)
  fi
  local summary
  summary="$("${tool[@]}" get test-results summary --path "${bundle}" 2>/dev/null)" || return 1
  [[ -n "${summary}" ]] || return 1
  local lines
  lines="$(printf '%s' "${summary}" | jq -r '
      if type == "object" and (.testFailures | type) == "array"
      then (.testFailures[]
            | ((.testIdentifierString // .testName // "") | gsub("/"; "."))
              + "\t"
              + ((.failureText // "") | gsub("[[:space:]]+"; " ")))
      else error("no testFailures") end' 2>/dev/null)" || return 1
  # A summary that read fine and names no failure prints nothing and SUCCEEDS, which is what a green
  # bundle says and is a different thing from a bundle nobody could open.
  [[ -n "${lines}" ]] || return 0
  # A record with no identifier cannot be paired with a name, so it is dropped here and the name it
  # belongs to says the bundle held no reason for it, rather than a blank line appearing under one.
  grep -v '^	' <<< "${lines}" || true
  return 0
}

# suite_run_series_append <existing text> <date> <totals> <retry reason>
#
# #3166: the new contents of the series file, with this run appended, or the existing text unchanged.
#
# Every run states its own size and duration, and AGENTS.md deliberately refuses to write a duration
# down, because a stale figure weakens the very warning it exists to support (#2532, L32). That is right,
# and the consequence is that the number is only ever read in the moment and compared against nothing.
# This repository pays the full suite twice per issue and serialises it through one lock across every
# worktree, so suite duration is close to the dominant cost of shipping anything here, and a slow climb
# is invisible: no single run looks wrong and there is no series to look at.
#
# `<totals>` is `tests suites seconds`, the same shape `test_run_totals` produces. A run that could not
# state a size writes NOTHING: its counts are the totals of the REMAINDER after a relaunch (#2821), and a
# series carrying those would be a record of something nobody measured (L98).
#
# The RETRY REASON is recorded beside the duration and is not decoration: a retried run's duration covers
# TWO attempts (#3392), so a series that did not say so would read a doubled run as a duration regression
# and name the wrong cause (L11).
SUITE_RUN_SERIES_KEEP="${OVERTURE_SUITE_RUN_SERIES_KEEP:-40}"
suite_run_series_append() {
  local existing="$1" today="$2" totals="$3" reason="${4:-}"
  local tests suites seconds
  tests="$(awk '{print $1}' <<< "${totals}")"
  suites="$(awk '{print $2}' <<< "${totals}")"
  seconds="$(awk '{print $3}' <<< "${totals}")"
  # All three, or nothing. A partial reading is what a truncated or unparsed run produces.
  if [[ ! "${tests}" =~ ^[0-9]+$ || ! "${suites}" =~ ^[0-9]+$ || ! "${seconds}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "${existing}"
    return 0
  fi
  local whole="${seconds%%.*}"
  local line="${today} ${tests} ${suites} ${whole} ${reason:-none}"
  # Header lines first, then the last N readings. Capped, because a machine that runs the suite all day
  # would otherwise grow this without bound, and because the advisory only ever reads the recent window.
  local header body
  header="$(grep '^#' <<< "${existing}" || true)"
  body="$(grep -v '^#' <<< "${existing}" | grep -a '[^[:space:]]' || true)"
  body="${body}${body:+$'\n'}${line}"
  body="$(tail -n "${SUITE_RUN_SERIES_KEEP}" <<< "${body}")"
  printf '%s\n%s' "${header}" "${body}"
}

# suite_run_series_line <series text> <this run's seconds>
#
# #3166: one advisory line when this run is well outside the recent spread, or nothing.
#
# Judged against the MEDIAN of the readings the series holds rather than a written-down number, for
# AGENTS.md's own reason: a figure in a document drifts and then weakens the warning it is quoted in
# support of.
#
# The threshold is TWICE the median, and it is measured rather than chosen. Every full run on this Mac on
# 2026-08-31 fell between 391s and 679s against a median of about 449, so the slowest healthy run of that
# day is 1.51x, and its only problem was that something else was running. A 1.5x rule would have fired on
# it, which is the shape that gets an advisory switched off within a day (L93, L172).
#
# Too little history says NOTHING rather than comparing against one or two runs, because a median of two
# is not a spread and an advisory built on it would be noise (L98).
SUITE_RUN_SERIES_MINIMUM="${OVERTURE_SUITE_RUN_SERIES_MINIMUM:-5}"
suite_run_series_line() {
  local series="$1" seconds="${2:-}"
  [[ "${seconds}" =~ ^[0-9]+$ ]] || return 0
  local readings count median
  readings="$(grep -v '^#' <<< "${series}" | awk 'NF >= 4 { print $4 }' | grep -aE '^[0-9]+$' | sort -n || true)"
  count="$(grep -c . <<< "${readings}")"
  [[ "${count}" -ge "${SUITE_RUN_SERIES_MINIMUM}" ]] || return 0
  median="$(awk -v n="${count}" 'NR == int((n + 1) / 2) { print; exit }' <<< "${readings}")"
  [[ "${median}" =~ ^[0-9]+$ && "${median}" -gt 0 ]] || return 0
  if [[ "${seconds}" -gt $(( median * 2 )) ]]; then
    echo "This run took ${seconds}s, SLOWER than twice the median of the last ${count} full runs (${median}s)."
  fi
  return 0
}

# The same reading taken from the run's own OUTPUT, for when the bundle cannot be read (#3385).
#
# #3384 read the kill from the result bundle only, and the bundle is also where the executed count comes
# from, so one unreadable bundle took BOTH: the detection fell silent and the count fell back to the log
# text and printed the remainder as if it were a size. Measured on the first real truncated run after
# that shipped: `Suite shape: 5035 tests in 782 suites`, naming no cause, for a run that had lost 3,608
# tests. A guard must not draw on the same source as the reading it would refuse, or it is absent exactly
# when that reading is least trustworthy.
#
# The signature is exact and needs no list of declared limits. Swift Testing expresses a time limit in
# whole MINUTES, so a killed test reports a duration that is a whole number of minutes in seconds, to
# three decimals: `60.000`, `120.000`. Measured across twenty-three full runs, every one of the six short
# ones carries exactly one such line and none of the seventeen complete ones carries any.
#
# A FAILED line only. A test that passes cannot have been killed, and a passing test whose elapsed
# reading happens to land on a whole minute is the ordinary case in a parallel log, where the seconds are
# elapsed since the worker began rather than what the test cost.
output_time_limit_kill() {
  local output="$1"
  printf '%s\n' "${output}" | awk -v q="'" '
    match($0, "^Test case " q "[^" q "]+" q " failed on ") {
      rest = substr($0, length("Test case " q) + 1)
      name = substr(rest, 1, index(rest, q) - 1)
      if (match($0, /\(([0-9]+)\.000 seconds\)$/)) {
        seconds = substr($0, RSTART + 1, RLENGTH - 11) + 0
        if (seconds >= 60 && seconds % 60 == 0) { print name; exit }
      }
    }
  '
}

# Which count the run is judged by, and a fourth field naming WHICH SOURCE it came from, because a
# count read from the weaker source and a count read from the stronger one must not be indistinguishable
# once one of them is the only one available (L11).
#
# A RESTARTED run is refused the bundle count, deliberately. Its text totals are the totals of the
# REMAINDER after xcodebuild relaunched the test process (#2821), and whether the bundle counts the
# whole run or only that remainder is not something anybody has measured. Substituting an unmeasured
# whole-run count for a remainder is the one direction that disarms the short-run gate, so a restarted
# run keeps the reading it already had until somebody measures the other (L82).
totals_with_authoritative_count() {
  local totals="$1" bundle_count="$2" restarted="${3:-}"
  if [[ -n "${restarted}" || -z "${bundle_count}" ]]; then
    [[ -n "${totals}" ]] && printf '%s log\n' "${totals}"
    return 0
  fi
  if [[ -z "${totals}" ]]; then
    # A bundle count with no text totals is still the count the gate needs. The suites and the duration
    # say they were not reported rather than being invented from it.
    printf '%s unknown unknown xcresult\n' "${bundle_count}"
    return 0
  fi
  local tests suites seconds
  read -r tests suites seconds <<< "${totals}"
  printf '%s %s %s xcresult\n' "${bundle_count}" "${suites}" "${seconds}"
}

format_suite_report() {
  local totals="$1" ratio="$2" guard_decls="$3" total_decls="$4" restarted="${5:-}"
  local out="Suite shape: "

  if [[ -n "${restarted}" ]]; then
    # #3266: NAME the cause when it is known. Every short run this repository has recorded was a test
    # killed at its time limit, and the run that follows one reports the remainder. Saying which test
    # is the difference between a re-run and a fix, and the reason was previously unavailable anywhere
    # in the log (L11).
    if [[ "${restarted}" == time-limit\ * ]]; then
      echo "${out}NOT REPORTED. ${restarted#time-limit } EXCEEDED ITS TIME LIMIT, so xcodebuild killed the test process and relaunched it, and the totals it printed cover only what ran AFTER that, not this whole run. Nothing here can be read as the size of the suite. That test is the thing to fix, not the run to repeat. See #3266, #2821."
      return 0
    fi
    echo "${out}NOT REPORTED. The test process RESTARTED during this run (xcodebuild relaunched it after an unexpected exit, crash or test timeout), so the totals it printed cover only what ran AFTER the last restart, not this whole run. Nothing here can be read as the size of the suite. Re-run it. See #2821."
    return 0
  fi

  if [[ -n "${totals}" ]]; then
    # #3243: an optional FOURTH field naming where the count came from. Absent means the caller did not
    # ask the question, which is what every existing caller and fixture does, so the readout is
    # unchanged for them.
    local tests suites seconds count_source
    read -r tests suites seconds count_source <<< "${totals}"
    # #2317: a scoped run really can be one suite, and now that scoped runs go through this wrapper the
    # readout says so in words rather than "1 suites".
    out+="${tests} test$([[ "${tests}" == 1 ]] || echo s)"
    out+=" in ${suites} suite$([[ "${suites}" == 1 ]] || echo s), "
    # #3233: a parallel run's counts and its duration are separate measurements, and only the
    # duration can go missing on its own. Naming it beats printing the token: "26 tests in 12
    # suites, unknowns" reads as a number nobody quite parsed rather than as a reading not taken.
    if [[ "${seconds}" == "unknown" ]]; then
      out+="duration not reported by this run."
    else
      out+="${seconds}s."
    fi
    # Said only when the WEAKER source was used, so it is a warning rather than noise. A count parsed
    # from stdout can be corrupted by two parallel workers writing in the same instant, and nothing
    # bounds how often that happens (#3243).
    if [[ "${count_source:-}" == "log" ]]; then
      out+=" The count was counted from the log text rather than read from the result bundle, so it may be short by however many per-test lines collided."
    fi
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

# #2991: whether the live store invariants measured anything, and for HOW LONG they have not.
#
# `ReplyInvariantsLiveStoreTests` prints a corpus line every run giving how many rows each of its
# invariants could examine. Measured 2026-08-19 it read `0 with a reply still open, 0 reached-out rows
# in play`: both passed having asserted nothing about anything, and the only thing separating that
# from a clean bill of health was a printed line thousands of lines up a log nobody reads.
#
# That is L182 exactly. A count driven to zero stops being read as a measurement and starts being read
# as proof the thing cannot occur, and this one goes to zero precisely when Dan finishes his outreach
# work, so it can sit there for months. What is dormant is not the RULE (the synthetic suite still has
# teeth) but the ability to notice an unforeseen SHAPE in his real data, which is the whole reason the
# live suite exists (#2150).
#
# The DURATION is the half worth acting on. "Both measured nothing today" is much weaker than "neither
# has measured anything since June": only the second says whether to care.
#
# Four states, kept apart, because an unmeasured check and a passed one look identical from silence
# (L11), and because one invariant still having teeth is a different fact from neither having any:
#
#   measuring        both invariants had rows to examine
#   PARTLY DORMANT   one had none; it is NAMED, with its own duration, and the other's real count given
#   DORMANT          neither had any, each with its own duration
#   NOT REPORTED     no corpus line in this run at all
#
# NOT REPORTED is the one that matters, and it is not hypothetical: a scoped run does not include this
# suite, and so produces no line. Reading that absence as "nothing to report" would make the emptiest
# possible failure look like the cleanest possible pass (L98).
#
# The clock and the record are PASSED IN, never read inside. This repo passes `now` explicitly
# everywhere for that reason, and a duration read off a hidden clock is one no test can hold still
# (L130). The merge below is likewise a pure function returning the record's new CONTENTS, so the call
# site only writes what it returns and every rule about what may be remembered is testable.

# The two counts the corpus line states, as "open reached", or nothing when there is no readable line.
#
# Each is read off the PHRASE that names it rather than by position, so a reworded or reordered corpus
# line cannot silently hand this the wrong number.
live_corpus_counts() {
  local output="$1" line open reached
  line="$(grep -a "LIVE STORE CORPUS:" <<< "${output}" 2>/dev/null | tail -n 1)"
  [[ -n "${line}" ]] || return 1
  # #3165: the WRITER-HELD count, not the still-open one. The open count empties whenever Dan is up to
  # date, which is most of the time, so it reported the writer-resolution rule as dormant when the truth
  # was that the rule had been asked a question its corpus could not hold. The rule now runs over every
  # replied row whose recorded writer somebody on the show holds, and this is that number.
  open="$(grep -oE '[0-9]+ whose writer a contact holds' <<< "${line}" | grep -oE '^[0-9]+')"
  reached="$(grep -oE '[0-9]+ reached-out rows in play' <<< "${line}" | grep -oE '^[0-9]+')"
  # A line this cannot parse is unmeasured, never clean: the same answer as no line at all, because a
  # number nobody could read is not a number this may report.
  [[ "${open}" =~ ^[0-9]+$ && "${reached}" =~ ^[0-9]+$ ]] || return 1
  echo "${open} ${reached}"
}

# Whole days between two yyyy-mm-dd dates, or NOTHING when either cannot be read. Never a zero standing
# in for an unreadable date: zero days is a measurement and an unreadable date is not one (L11).
# #3191: through the shared helper. This and `hosted_stamp_age_days` were the same function under two
# names, down to the refusal that matters most, and a third copy elsewhere had lost it.
days_since() {
  machine_stamp_days_since "$1" "$2"
}

# The date recorded against one invariant, from the record's text, or nothing.
live_corpus_seen_date() {
  local field="$1" seen="$2"
  grep -aE "^${field}=" <<< "${seen}" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# How long one invariant has been asleep, in words. Says plainly when nothing was ever recorded here,
# rather than guessing a date or falling silent: an unrecorded duration and a short one are different
# facts, and only one of them means "look at this".
live_corpus_dormancy_phrase() {
  local field="$1" today="$2" seen="$3" date days
  date="$(live_corpus_seen_date "${field}" "${seen}")"
  if [[ -n "${date}" ]]; then
    days="$(days_since "${date}" "${today}")"
    if [[ -n "${days}" ]]; then
      echo "since ${date} (${days} day$([[ "${days}" == 1 ]] || echo s))"
      return 0
    fi
    echo "since ${date}"
    return 0
  fi
  echo "for as long as this clone has recorded"
}

# Which text the corpus reading is taken FROM, given what the recorded file holds and what the run
# printed (#3276).
#
# The FILE wins wherever it carries a line, and the log is the fallback. That order rather than the other
# way round because the file is the only channel a PARALLEL worker has: its stdout does not reach
# xcodebuild's, so a parallel run's log carries no corpus line at all while its file does. A serial run
# has both and they are the same sentence, built in one place by `LiveCorpusReport.line` so the two
# sources cannot report different numbers (L263).
#
# Neither one present comes back EMPTY, and the caller reads that as NOT REPORTED. That is the state a
# scoped run produces, and it must never be folded into a measured zero (L98).
corpus_source_text() {
  local file_text="$1" output="$2"
  if [[ "${file_text}" == *"LIVE STORE CORPUS:"* ]]; then
    printf '%s\n' "${file_text}"
    return 0
  fi
  printf '%s\n' "${output}"
}

live_corpus_report() {
  local output="$1" today="${2:-}" seen="${3:-}" file_text="${4:-}" counts open reached source
  source="$(corpus_source_text "${file_text}" "${output}")"
  if ! counts="$(live_corpus_counts "${source}")"; then
    # #3275: NAME the cause this run's own output supports, rather than the one that is usually right.
    # The corpus line is a `print()` from a test, and a PARALLEL worker's stdout does not reach
    # xcodebuild's: measured 2026-08-30, the suite ran and passed and the line appeared zero times. The
    # message said "a scoped run does not include them" for a run that was not scoped, sending the
    # reader to check a scope they never set (L11). A parallel run is told by its own per-test lines,
    # which is evidence in the output rather than an inference about how it was invoked.
    # #3276: the parallel case is no longer "the line cannot get here". The suite records its counts to
    # a file the runner names, which a worker process has and stdout is not, so a parallel run that RAN
    # the suite reports normally. What this branch now means is that the suite did not run, which for a
    # parallel run is the same fact as for a serial one, said in the words that fit it.
    if [[ -n "$(test_run_totals_parallel "${output}")" ]]; then
      echo "Live store invariants: NOT REPORTED. This PARALLEL run left no corpus line in its record file and printed none, which is either a scope that excluded the suite or a run that could not write the file it was given. Nothing here says whether the invariants measured anything (#3276)."
      return 0
    fi
    echo "Live store invariants: NOT REPORTED. This run printed no corpus line, so whether they measured anything is unknown; a scoped run does not include them."
    return 0
  fi
  read -r open reached <<< "${counts}"

  if [[ "${open}" -eq 0 && "${reached}" -eq 0 ]]; then
    echo "Live store invariants: DORMANT. The writer-resolution invariant has measured nothing $(live_corpus_dormancy_phrase writer "${today}" "${seen}"), the reached-out one $(live_corpus_dormancy_phrase reached "${today}" "${seen}"), so both passed having asserted nothing about Dan's real data (#2991, L182)."
    return 0
  fi
  if [[ "${open}" -eq 0 ]]; then
    echo "Live store invariants: PARTLY DORMANT. The writer-resolution invariant has measured nothing $(live_corpus_dormancy_phrase writer "${today}" "${seen}"); the reached-out one measured ${reached} this run (#2991, L182)."
    return 0
  fi
  if [[ "${reached}" -eq 0 ]]; then
    echo "Live store invariants: PARTLY DORMANT. The reached-out invariant has measured nothing $(live_corpus_dormancy_phrase reached "${today}" "${seen}"); the writer-resolution one measured ${open} this run (#2991, L182)."
    return 0
  fi
  echo "Live store invariants: measuring, over ${open} rows the writer-resolution rule can judge and ${reached} reached-out rows in play."
}

# The record's NEW contents after this run, given its old contents. Pure: the caller writes what this
# returns, so every rule here is testable without a file.
#
# Two refusals carry the whole feature, and both are refusals to WRITE:
#
#   * A run in which an invariant measured NOTHING leaves that invariant's date alone. Stamping today
#     regardless would overwrite the last real measurement every single run, so the duration would
#     always read zero and the dormancy would be invisible in a message that mentions a date, which is
#     the defect wearing a disguise.
#   * A run with no corpus line writes nothing at all. It took no reading, so it is evidence about
#     nothing, and a scoped run produces exactly this constantly.
live_corpus_seen_update() {
  local output="$1" today="$2" seen="$3" file_text="${4:-}" counts open reached source
  # The same source rule as the report above, through the same function, so the durable RECORD and the
  # line on screen can never be taken from different places (L263). Without this a parallel run would
  # report its counts and then leave the dormancy record untouched, which is the one number #2991 must
  # never get wrong.
  source="$(corpus_source_text "${file_text}" "${output}")"
  if ! counts="$(live_corpus_counts "${source}")"; then
    printf '%s' "${seen}"
    return 0
  fi
  read -r open reached <<< "${counts}"

  local open_date reached_date
  open_date="$(live_corpus_seen_date writer "${seen}")"
  reached_date="$(live_corpus_seen_date reached "${seen}")"
  [[ "${open}" -gt 0 ]] && open_date="${today}"
  [[ "${reached}" -gt 0 ]] && reached_date="${today}"

  local out=""
  [[ -n "${open_date}" ]] && out="writer=${open_date}"
  if [[ -n "${reached_date}" ]]; then
    [[ -n "${out}" ]] && out="${out}
"
    out="${out}reached=${reached_date}"
  fi
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# #2597: how old the measured queue rebuild cost is
# ---------------------------------------------------------------------------
# `QueueRebuildCostTests` is OPT IN, because it builds a corpus the size of the live store and times it,
# which is seconds of work and a stopwatch, neither of which belongs on the mandatory pre-push gate. The
# consequence is that its figure gets written down and nothing re-runs it, while the store grows every
# night, so the number quietly stops describing reality while still reading as measured (L32, L316).
#
# This is `check-prep-eval-freshness.sh`'s answer applied here: the expensive thing stays opt in, and its
# AGE rides along on every push, so nobody has to remember to wonder.
#
# ADVISORY, and deliberately with NO staleness threshold. A gate on "this measurement is old" fires on
# the ordinary case, which is every push that did not opt in, and gets its threshold raised until it
# catches nothing (L36, L93). What the rebuild COSTS in work units is guarded continuously and
# separately, by #2048's per-card counters on every run; this covers only the clock figure, which is the
# half no always-on test can own.
queue_cost_field() {
  local key="$1" seen="$2"
  printf '%s\n' "${seen}" | awk -F= -v k="${key}" '$1 == k { print $2; exit }'
}

# The line. Four states, kept apart because an unmeasured figure and a fresh one look identical from
# silence (L11, L98).
queue_cost_report() {
  local today="$1" seen="${2:-}" output="${3:-}" date ms rows days fresh
  # This run's OWN reading wins over the stored one, the way `live_corpus_report` reads the run's output
  # rather than a record. Without it the single run that actually took the measurement reported "NEVER
  # measured on this clone", which is the most misleading moment that sentence has.
  fresh="$(queue_cost_seen_update "${output}" "${today}" "")"
  if [[ -n "${fresh}" ]]; then
    echo "Queue rebuild cost: $(queue_cost_field ms "${fresh}") ms over $(queue_cost_field rows "${fresh}") rows, measured by THIS run."
    return 0
  fi
  if [[ -z "${seen}" ]]; then
    echo "Queue rebuild cost: NEVER measured on this clone. Run TEST_RUNNER_MEASURE_QUEUE_REBUILD=1 to take it."
    return 0
  fi
  date="$(queue_cost_field date "${seen}")"
  ms="$(queue_cost_field ms "${seen}")"
  rows="$(queue_cost_field rows "${seen}")"
  if [[ -z "${date}" || -z "${ms}" || -z "${rows}" ]]; then
    echo "Queue rebuild cost: UNREADABLE record. It carries a date but no figure, so nothing here says what the last measurement was."
    return 0
  fi
  days="$(days_since "${date}" "${today}")"
  echo "Queue rebuild cost: ${ms} ms over ${rows} rows, last measured ${date} (${days} days ago)."
}

# What gets REMEMBERED. Pure, returning the file's whole new contents, so the call site only ever writes
# what this hands back.
#
# The case the whole thing rests on is the LAST one: a run that did not take the measurement must change
# NOTHING. Stamping every run with today would move the date forward while the figure stayed put, and the
# age would always read zero, which is the defect wearing a date. That is the same rule, for the same
# reason, as `live_corpus_seen_update` above.
queue_cost_seen_update() {
  local output="$1" today="$2" seen="${3:-}" parsed rows ms
  # ONE awk over a herestring, with no pipeline at all, which is deliberate rather than tidy. The first
  # version of this read `printf ... | grep ... | head -1`, and `run-shell-fixtures.sh`'s #3401 guard
  # refused it: `head` exits on its first line, which kills the producer with SIGPIPE, and under
  # `set -o pipefail` that 141 becomes the pipeline's status. An EARLY match and NO match are then
  # indistinguishable, and the failure reads as a clean "nothing was measured" (L183, #3275).
  #
  # The rows count and the total live on consecutive lines, so `getline` takes the second while the first
  # is still in hand, and `exit` stops at the first pairing rather than a consumer stopping it.
  parsed="$(awk '
    /queue-rebuild-cost: one rebuild of/ {
      if (match($0, /of [0-9]+ rows/)) { r = substr($0, RSTART + 3, RLENGTH - 8) }
      if ((getline) > 0 && match($0, /[0-9]+\.[0-9]+/)) { m = substr($0, RSTART, RLENGTH) }
      if (r != "" && m != "") { print r " " m; exit }
    }' <<< "${output}")"
  [[ -z "${parsed}" ]] && { printf '%s' "${seen}"; return 0; }
  read -r rows ms <<< "${parsed}"
  if [[ -z "${rows}" || -z "${ms}" ]]; then
    printf '%s' "${seen}"
    return 0
  fi
  printf 'date=%s\nms=%s\nrows=%s' "${today}" "${ms}" "${rows}"
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
# #3408: counted in ONE pass rather than one process per file. It ran `grep -o | wc -l | tr -d` for each
# of about 470 matching files, so the readout every run prints cost roughly 1,400 processes: measured
# 2026-08-31 on a stubbed wrapper run with no build and no tests in it, this loop was 940 of the 2,436
# traced lines and the run took 5.07 seconds. `mac/scripts/run-tests-locked.test.sh` pays that 28 times,
# which is most of why it is the floor of the cheap lane.
#
# NUL separated on the way into xargs, because this repository's own path has spaces in it and a list
# split on whitespace would count nothing here while reporting a confident zero (L98). The empty case is
# answered before xargs is reached: with no arguments xargs runs its command over STDIN, which would hang
# rather than report nothing.
source_guard_declarations_under() {
  local dir="$1"
  [[ -d "${dir}" ]] || { echo 0; return 0; }
  local files
  files="$(grep -rl -E 'SwiftSource|SourceGuardHelper|CopyInventory' "${dir}" --include='*.swift' 2>/dev/null)"
  [[ -n "${files}" ]] || { echo 0; return 0; }
  printf '%s\n' "${files}" | tr '\n' '\0' \
    | xargs -0 grep -ho '@Test' 2>/dev/null | wc -l | tr -d ' '
}

# The whole readout for a finished run, given that run's output and the repo's mac directory.
# #3243: `totals` is the already-decided totals line (count, suites, seconds, source) when the caller
# has one. Optional, so every existing caller and fixture reads exactly as before, computing the totals
# from the text. The runner passes it because it has already read the result bundle for the gate, and
# the readout and the gate must be judging the same number: two independent readings of one run is how
# a readout comes to disagree with the verdict beside it (L53).
suite_report_for_run() {
  local output="$1" mac_dir="$2" totals="${3:-}"
  local app_lines test_lines guard_decls total_decls

  app_lines="$(swift_lines_under "${mac_dir}/Overture")"
  test_lines=$(( $(swift_lines_under "${mac_dir}/OvertureTests") \
               + $(swift_lines_under "${mac_dir}/OvertureHostedTests") \
               + $(swift_lines_under "${mac_dir}/TestSupport") ))
  total_decls=$(( $(test_declarations_under "${mac_dir}/OvertureTests") \
                + $(test_declarations_under "${mac_dir}/OvertureHostedTests") ))
  guard_decls=$(( $(source_guard_declarations_under "${mac_dir}/OvertureTests") \
                + $(source_guard_declarations_under "${mac_dir}/OvertureHostedTests") ))

  [[ -n "${totals}" ]] || totals="$(test_run_totals "${output}")"
  format_suite_report "${totals}" \
                      "$(line_ratio "${app_lines}" "${test_lines}")" \
                      "${guard_decls}" "${total_decls}" \
                      "$(test_run_restarted "${output}")"
}
