#!/usr/bin/env bash
set -uo pipefail

# #3163: every test that names a symbol, listed BEFORE a reversed decision is implemented.
#
# WHY. When a product decision is reversed, the tests asserting the OLD rule survive in whatever files
# they were written in, and they are the most dangerous kind of stale test: they do not merely fail to
# cover the new behaviour, they actively DEFEND the behaviour that was rejected (L252).
#
# Measured 2026-08-23 on #2968, where Dan reversed the rule so a show dismissed after being emailed owes
# no nudge. Two tests asserted the opposite, in two different files, and both had been written the same
# day. `OneDueNumberTests.aDismissedShowThatWasEmailedIsCountedByThePillAsWellAsTheSheet` was found by
# reading and replaced; `DebugStagingTests.theDismissedShowReallyDoesOweAFollowUpToday` was MISSED and
# surfaced only by a full suite run twenty minutes later. The cost that day was one wasted suite run. The
# risk is the reversed assertion sitting in a file nobody re-runs, quietly becoming the authority for a
# rule that was rejected.
#
# WHAT THIS IS, AND WHAT IT IS NOT. #3163 weighed two answers. The other one was a diff-based check on a
# PR (which tests did this change modify, versus which tests elsewhere name the same symbols and were left
# alone). This is the cheaper one it named, and it is deliberately a TOOL A PERSON RUNS rather than a
# gate: most tests naming a symbol are legitimately untouched by a reversal, so anything that refused
# would fire on the common case and be switched off in a day (L93). Run it when a decision is recorded,
# before writing any code, so the full set is in front of you rather than discovered by a red run.
#
# WHY NOT JUST GREP, which is the fair question. `grep -rl isAwaitingNudge mac/OvertureTests` names 14
# files and leaves the reading to be done. What is actually needed is the TEST, because that is the unit
# somebody has to decide about: this attributes every mention to the `@Test func` that encloses it, and
# to the SUITE when the mention sits in a helper or a comment outside any test, which is a different
# thing and is labelled differently rather than silently folded in (L11).
#
# It reports a COMMENT mention exactly like a code one, on purpose. The set this exists to hand somebody
# is "everything written about this rule", and a comment asserting the old rule is as misleading to the
# next reader as an assertion is. Over-reporting costs a line; under-reporting is the whole defect.

usage() {
  cat <<'USAGE'
usage: scripts/find-tests-naming.sh <symbol> [<symbol> ...]

  Lists every test in the Swift test targets that names any of the symbols, as
  <file>  <suite or test>  <what named it>.

  Run it when a decision is reversed, with the symbols the decision is about, BEFORE
  implementing it: the tests that assert the old rule are the ones to read first.

exit status
  0  measured, and at least one test names at least one symbol
  1  measured, and NO test names any of them
  2  bad usage, or the roots to search are not there

environment
  OVERTURE_TEST_ROOTS  space separated roots to search (default: the two Swift test targets).
                       A root whose path contains a space cannot be passed this way.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The default roots are an ARRAY, never a space separated string, because this repository's own path
# contains a space (it lives under "Photography Assets"). The first version of this held them in one
# string and split on whitespace, which turned each root into three nonexistent directories, found
# nothing, and reported that as "no test names this symbol" in the same words a real empty result gets.
# `scripts/mutate.sh` records the identical trap for its runner argument, for the identical reason.
ROOT_LIST=("${REPO_ROOT}/mac/OvertureTests" "${REPO_ROOT}/mac/OvertureHostedTests")
# The override is still a string, since an environment variable cannot carry an array, so a root with a
# space in it cannot be passed that way. Stated rather than left to be discovered: the fixture drives it
# with space free temp paths and the default path is the one that has to survive a space.
if [[ -n "${OVERTURE_TEST_ROOTS:-}" ]]; then
  read -r -a ROOT_LIST <<< "${OVERTURE_TEST_ROOTS}"
fi

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage; exit 0 ;;
  esac
done

PATHS=()
for root in "${ROOT_LIST[@]}"; do
  [[ -d "${root}" ]] && PATHS+=("${root}")
done
if [[ "${#PATHS[@]}" -eq 0 ]]; then
  echo "find-tests-naming: none of the roots exist, so nothing was searched: ${ROOT_LIST[*]}" >&2
  echo "Nothing was measured, which is not the same as nothing naming these symbols (L98)." >&2
  exit 2
fi

# attribute_file <file> <symbol>...: prints one line per mention, as
#   <relative path>\t<owner>\t<kind>
# where owner is the enclosing `@Test func` name, or the `@Suite` type when the mention is outside any
# test, and kind says which of the two it is so a reader is never left to guess.
#
# Done in awk in one pass rather than by grepping and then hunting for the enclosing declaration: the
# second step is where a line-number-arithmetic reader goes wrong the moment a comment moves (L518).
attribute_file() {
  local file="$1"; shift
  awk -v file="${file}" -v symbols="$*" '
    BEGIN { n = split(symbols, want, " ") }
    { lines[NR] = $0 }
    function typename(l,   m) {
      m = l
      sub(/^[[:space:]]*/, "", m)
      sub(/^@MainActor[[:space:]]+/, "", m)
      sub(/^final[[:space:]]+/, "", m)
      sub(/^(struct|class|enum)[[:space:]]+/, "", m)
      match(m, /^[A-Za-z_][A-Za-z0-9_]*/)
      return substr(m, 1, RLENGTH)
    }
    function fname(l,   m) {
      m = l
      sub(/.*func[[:space:]]+/, "", m)
      sub(/\(.*/, "", m)
      return m
    }
    END {
      suite = ""; test = ""
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (l ~ /^[[:space:]]*(@MainActor[[:space:]]+)?(final[[:space:]]+)?(struct|class|enum)[[:space:]]+[A-Za-z_]/) {
          suite = typename(l); test = ""
        }
        if (l ~ /@Test/) {
          test = ""
          for (j = i; j <= NR && j <= i + 4; j++) {
            if (lines[j] ~ /func[[:space:]]+[A-Za-z_]/) { test = fname(lines[j]); break }
          }
        }
        owner[i] = (test != "" ? test : (suite != "" ? suite : "(file)"))
        kind[i] = (test != "" ? "test" : "outside any test")
        # A comment block sitting immediately ABOVE a @Test describes THAT test, not the one before it.
        # Without this the doc comment on every test is attributed to its predecessor, which sends the
        # reader to a test that does not mention the symbol at all: a wrong answer wearing the same shape
        # as a right one (L11). Walked backwards here rather than guessed forwards, because the block ends
        # at the first line that is neither a comment nor blank and only the lines already read know that.
        if (l ~ /@Test/ && test != "") {
          k = i - 1
          while (k >= 1 && (lines[k] ~ /^[[:space:]]*\/\// || lines[k] ~ /^[[:space:]]*$/)) {
            owner[k] = test; kind[k] = "test"; k--
          }
        }
      }
      for (i = 1; i <= NR; i++) {
        for (s = 1; s <= n; s++) {
          if (index(lines[i], want[s]) > 0) {
            printf "%s\t%s\t%s\t%s\n", file, owner[i], kind[i], want[s]
            break
          }
        }
      }
    }
  ' "${file}"
}

# The files worth reading at all: any test source naming any of the symbols. Built as an ARRAY of
# `-e` arguments rather than by interpolating a command substitution into the command line, which is
# what the first version did and which silently found nothing: an unquoted expansion there is subject
# to word splitting and to whatever the caller's shell has aliased `grep` to.
candidate_files() {
  local args=(-rl --include=*.swift -F) symbol
  for symbol in "$@"; do args+=(-e "${symbol}"); done
  command grep "${args[@]}" "${PATHS[@]}" 2>/dev/null || true
}

FOUND=""
while IFS= read -r file; do
  [[ -n "${file}" ]] || continue
  hits="$(attribute_file "${file}" "$@")"
  [[ -n "${hits}" ]] && FOUND="${FOUND}${hits}"$'\n'
done < <(candidate_files "$@" | sort)

FOUND="$(printf '%s' "${FOUND}" | sed '/^$/d' | sort -u)"

if [[ -z "${FOUND}" ]]; then
  echo "NO test in the Swift test targets names any of: $*"
  echo ""
  echo "That is its own answer and not a pass: the commonest cause is a symbol spelled differently here"
  echo "than in the app, and a reversal implemented against an empty list is one nothing was checked for."
  exit 1
fi

echo "Tests naming $*:"
echo ""
printf '%s\n' "${FOUND}" | awk -F'\t' '
  { rel = $1; sub(/.*\/mac\//, "mac/", rel)
    printf "  %-46s %-52s %s (%s)\n", rel, $2, $3, $4 }'
echo ""
echo "$(printf '%s\n' "${FOUND}" | wc -l | tr -d ' ') mention(s). Read each before implementing the"
echo "reversal: a test asserting the decision that was REVERSED is not stale coverage, it is the guard"
echo "defending the rejected behaviour, so it is deleted rather than adjusted (L252)."
