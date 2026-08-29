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
  # #3233: the serial summary FIRST, and the line-counting fallback only where there is none. That
  # summary is xcodebuild's own total rather than one derived by counting, so a log carrying both
  # must never be re-counted from the weaker source.
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
  if [[ -n "${serial}" ]]; then
    printf '%s\n' "${serial}"
    return 0
  fi
  test_run_totals_parallel "${output}"
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
failing_tests_report() {
  local output="$1" names count
  names="$(failing_test_names "${output}")"
  [[ -n "${names}" ]] || return 0
  count="$(grep -c . <<< "${names}")"
  echo "FAILING TEST$([[ "${count}" == 1 ]] || echo S) (${count}), reprinted so the list is the last thing on screen:"
  sed 's/^/  /' <<< "${names}"
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
format_suite_report() {
  local totals="$1" ratio="$2" guard_decls="$3" total_decls="$4" restarted="${5:-}"
  local out="Suite shape: "

  if [[ -n "${restarted}" ]]; then
    echo "${out}NOT REPORTED. The test process RESTARTED during this run (xcodebuild relaunched it after an unexpected exit, crash or test timeout), so the totals it printed cover only what ran AFTER the last restart, not this whole run. Nothing here can be read as the size of the suite. Re-run it. See #2821."
    return 0
  fi

  if [[ -n "${totals}" ]]; then
    local tests suites seconds
    read -r tests suites seconds <<< "${totals}"
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
days_since() {
  local from="$1" to="$2" a b
  a="$(date -j -f "%Y-%m-%d" "${from}" +%s 2>/dev/null)" || return 0
  b="$(date -j -f "%Y-%m-%d" "${to}" +%s 2>/dev/null)" || return 0
  [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ ]] || return 0
  echo $(( (b - a) / 86400 ))
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

live_corpus_report() {
  local output="$1" today="${2:-}" seen="${3:-}" counts open reached
  if ! counts="$(live_corpus_counts "${output}")"; then
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
  local output="$1" today="$2" seen="$3" counts open reached
  if ! counts="$(live_corpus_counts "${output}")"; then
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
                      "${guard_decls}" "${total_decls}" \
                      "$(test_run_restarted "${output}")"
}
