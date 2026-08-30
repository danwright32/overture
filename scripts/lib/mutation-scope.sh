#!/usr/bin/env bash
# shellcheck shell=bash
#
# #3098: did the scope a mutation ran under actually reach the tests for the file it broke?
#
# Hit for real on 2026-08-21 while proving #2726. A sentence in mac/Overture/Integration/ScoutService.swift
# was reworded, scoped to -only-testing:OvertureTests/ScoutStartGateTests, and mutate.sh reported
# SURVIVED. The guard was fine: the test lives in a SECOND suite in that same file,
# ScoutStartGateWiringTests, so the scope ran nine real, unrelated tests and never the one under test.
# Re-run against the right suite, the same mutation reported CAUGHT.
#
# That is a lie in the SURVIVED direction, on the tool the whole repo leans on to prove its ~1,950
# source-text guards are real. #2317's NOTHING RAN structurally cannot catch it, because something DID
# run: nine real tests passed. mutate.sh already prints a caution about it, which is a rule living only
# in prose and reaches nobody in exactly the runs where it matters (L27).
#
# THE QUESTION THIS ASKS, and why it is not the obvious one. The issue floated two signatures. The first,
# a -only-testing: scope naming a suite whose FILE declares more than one @Suite, is rejected: it fires
# just as hard when the scope named the RIGHT suite of the two, which is the common case, and a guard
# that fires on the common case is switched off within a day (L93). The second is the one implemented:
# did any suite that MENTIONS the mutated file actually run? Measured against the real incident, that
# separates the two runs exactly. Suite ScoutStartGateTests mentions ScoutService zero times; suite
# ScoutStartGateWiringTests mentions it once.
#
# The unit is the SUITE, not the file. Per-file would have passed the incident, because both suites live
# in ScoutStartGateTests.swift and one of them ran.
#
# WHAT IT REFUSES TO ANSWER. Three states are deliberately not NOT_REACHED, because each would refuse a
# run nobody should be refused, and one of them would claim a measurement that never happened:
#   - an UNSCOPED run, which by definition ran every suite there is;
#   - a file no suite anywhere mentions, where SURVIVED is a real finding about the code and not about
#     the scope;
#   - a log with no suite lines in it at all, which is what OVERTURE_MUTATE_RUNNER pointed at the shell
#     fixtures or vitest produces. Calling that REACHED would be reporting a measurement that was never
#     taken (L98), so it gets its own verdict and its own exit code.

# mutation_scope_reached_file <run_log> <mutated_file> [scope args...]
#
# Reads the test roots from the MUTATION_TEST_ROOTS array when the caller sets one, so the fixture can
# point it at its own tree. Prints a verdict word on the first line; NOT_REACHED then lists the suites
# that DO mention the file, one per line, which is what tells the reader where to scope instead.
#
# Exit: 0 REACHED or NO_SUITE_MENTIONS_IT (do not refuse), 1 NOT_REACHED (refuse), 2 CANNOT_JUDGE.
mutation_scope_reached_file() {
  local run_log="$1"; shift
  local mutated_file="$1"; shift

  local scoped="false"
  local a
  for a in "$@"; do
    case "$a" in
      -only-testing:*|-only-testing) scoped="true" ;;
    esac
  done
  if [[ "${scoped}" != "true" ]]; then
    echo "REACHED"
    echo "  the run was not scoped, so it ran every suite there is."
    return 0
  fi

  if [[ ! -r "${run_log}" ]]; then
    echo "CANNOT_JUDGE"
    echo "  the run log at ${run_log} could not be read, so which suites ran is unknown."
    return 2
  fi

  # The symbol a test refers to the file by. Swift's one-type-per-file convention makes the basename the
  # type name, which is what a source-text guard names and what a test importing it calls.
  local symbol
  symbol="$(basename "${mutated_file}")"
  symbol="${symbol%.*}"
  if [[ ! "${symbol}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "CANNOT_JUDGE"
    echo "  '${symbol}' is not a name a Swift test could refer to, so there is nothing to look for."
    return 2
  fi

  # Which suites RAN. Swift Testing prints the display name when @Suite gives one and the bare type name
  # when it does not, so both forms are collected. Started, passed and failed together, because a suite
  # that went red is still a suite that ran.
  #
  # Matched on the VERB rather than on the glyph Swift Testing prints in front of it. Those glyphs are
  # characters the repo's own style gate forbids a new line from carrying, and AGENTS.md is explicit that
  # the answer is to avoid needing the literal rather than to override the gate. The verb is the load
  # bearing half in any case: the glyph only repeats what the word already says.
  local executed
  executed="$(
    {
      grep -oE 'Suite "[^"]+" (started|passed|failed)' "${run_log}" 2>/dev/null | sed -E 's/^Suite "//; s/" (started|passed|failed)$//'
      grep -oE 'Suite [A-Za-z_][A-Za-z0-9_]* (started|passed|failed)' "${run_log}" 2>/dev/null | sed -E 's/^Suite //; s/ (started|passed|failed)$//'
    } | sort -u
  )"
  if [[ -z "${executed}" ]]; then
    echo "CANNOT_JUDGE"
    echo "  the log names no suite at all, so this runner's output cannot say which suites ran."
    return 2
  fi

  local roots=()
  if [[ -n "${MUTATION_TEST_ROOTS+x}" ]] && [[ "${#MUTATION_TEST_ROOTS[@]}" -gt 0 ]]; then
    roots=("${MUTATION_TEST_ROOTS[@]}")
  else
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    roots=("${here}/mac/OvertureTests" "${here}/mac/OvertureHostedTests" "${here}/mac/TestSupport")
  fi

  local mentioning
  mentioning="$(mutation_scope_suites_mentioning "${symbol}" "${roots[@]}")"
  if [[ -z "${mentioning}" ]]; then
    echo "NO_SUITE_MENTIONS_IT"
    echo "  no suite anywhere names ${symbol}, so nothing was guarding it whatever the scope was."
    return 0
  fi

  # Any overlap is enough. A suite that mentions the file and ran is a suite that had its chance.
  local suite
  while IFS= read -r suite; do
    [[ -n "${suite}" ]] || continue
    # #3275: a herestring rather than a pipe. `executed` is a whole run's suite list, which is well
    # past a pipe buffer, so an early match would be turned into 141 by SIGPIPE and read as no match
    # under pipefail (L183).
    if grep -qxF "${suite}" <<< "${executed}"; then
      echo "REACHED"
      echo "  ${suite}"
      return 0
    fi
  done <<< "${mentioning}"

  echo "NOT_REACHED"
  printf '%s\n' "${mentioning}"
  return 1
}

# mutation_scope_suites_mentioning <symbol> <root>...
#
# Every suite, across the given roots, whose OWN BODY names the symbol as a word, printed by the identity
# the run log would use for it: the @Suite display name where there is one, the declared type name where
# there is not.
#
# Word, never substring: a suite mentioning ScoutServiceExtra is not a suite mentioning ScoutService, and
# treating it as one would silently pass the run this exists to refuse (L156 is the same shape).
mutation_scope_suites_mentioning() {
  local symbol="$1"; shift
  local root
  local files=()
  for root in "$@"; do
    [[ -d "${root}" ]] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find "${root}" -name '*.swift' -type f -print0 2>/dev/null)
  done
  [[ "${#files[@]}" -gt 0 ]] || return 0

  awk -v sym="${symbol}" '
    function emit() {
      if (ident != "" && hit) print ident
      ident = ""; hit = 0
    }
    function settype(line,   n, parts, i, tn) {
      n = split(line, parts, /[ \t(<{:]+/)
      for (i = 1; i <= n; i++) {
        if (parts[i] == "struct" || parts[i] == "class" || parts[i] == "actor" || parts[i] == "enum") {
          tn = parts[i+1]
          break
        }
      }
      gsub(/[^A-Za-z0-9_]/, "", tn)
      return tn
    }
    BEGIN { boundary = "[^A-Za-z0-9_]" sym "[^A-Za-z0-9_]" }
    FNR == 1 { emit(); disp = "" }
    # A suite annotation opens a new region and may carry the display name the log will print.
    /^[ \t]*@Suite/ {
      emit()
      disp = ""
      if (match($0, /"[^"]*"/)) disp = substr($0, RSTART + 1, RLENGTH - 2)
      # @Suite("...") struct X { on one line still declares the type, so do not skip the line blind.
      if ($0 ~ /(struct|class|actor|enum)[ \t]+[A-Za-z_]/) {
        ident = (disp != "" ? disp : settype($0))
        disp = ""
        hit = 0
      }
      next
    }
    # A top-level type declaration. Anchored at column zero on purpose: a type nested inside a suite is
    # part of that suite, not a suite of its own.
    /^(public |package |internal |private |fileprivate )*(final )?(struct|class|actor|enum) [A-Za-z_]/ {
      emit()
      ident = (disp != "" ? disp : settype($0))
      disp = ""
      hit = 0
      next
    }
    {
      if (ident != "" && (" " $0 " ") ~ boundary) hit = 1
    }
    END { emit() }
  ' "${files[@]}" | sort -u
}

# mutation_scope_format_candidates <max> < <suite names>
#
# The suites to scope to instead, capped. Measured 2026-08-22: a widely used type like ScoutService is
# named by 65 suites, and 65 lines under a refusal is a wall nobody reads, while a narrow one like
# StoreRelocation is named by exactly 1.
#
# What is dropped is NAMED rather than silently cut, because a truncated list reads as the whole answer
# and the suite you wanted may be the one below the line (AGENTS.md's own "no silent caps").
mutation_scope_format_candidates() {
  local max="${1:-15}"
  local all shown total
  all="$(cat)"
  total="$(printf '%s\n' "${all}" | grep -c . || true)"
  if [[ "${total}" -le "${max}" ]]; then
    printf '%s\n' "${all}" | sed 's/^/    /'
    return 0
  fi
  shown="$(printf '%s\n' "${all}" | head -n "${max}")"
  printf '%s\n' "${shown}" | sed 's/^/    /'
  echo "    ... and $(( total - max )) more of the ${total} suites that name it, not listed here."
}

# #3264: whether this run was genuinely SCOPED, asked by looking for a `-only-testing:` argument rather
# than by counting arguments.
#
# The exemptions below used to ask `$# -eq 0` and `$# -gt 0`, which is "was anything passed at all". That
# is the same defect #3264 records one script over: `run-tests-locked.sh`'s short-run gate stood down on
# ANY argument, so every parallel experiment (which passes `-parallel-testing-enabled YES`, not a scope)
# ran with the gate off, and one of them lost 40 percent of the suite and printed an ordinary verdict.
#
# Here the trailing arguments are documented as test scopes, so counting them is USUALLY right, and that
# is exactly what makes it worth fixing rather than leaving: the one time it is wrong is a run carrying a
# runner FLAG instead of a scope, which is the run most likely to be doing something unusual and least
# likely to be watched closely. A stand-down must be no broader than its reason (L324).
mutate_run_is_scoped() {
  local arg
  for arg in "$@"; do
    [[ "${arg}" == -only-testing:* ]] && return 0
  done
  return 1
}
