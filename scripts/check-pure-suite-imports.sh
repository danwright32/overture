#!/usr/bin/env bash
set -uo pipefail

# The pure suite reaches the app's code by COMPILING IT IN (mac/project.yml gives OvertureTests the
# `Overture` source directory), not by linking the app. That is the whole reason a launch fault can no
# longer take all 4,800 tests with it (#1967). It also means there is no `Overture` MODULE for a test in
# that target to import, and a file that tries does not fail politely: the target stops compiling, so
# not one test runs.
#
# On 2026-08-03 four such files were on main at once (#2007, #2010, #2013, #2015) and the Swift suite
# could not build at all. They passed on the way in because the combined scheme builds the app first,
# leaving an Overture.swiftmodule in the shared products directory that the import could latch onto when
# the build order happened to cooperate; on a clean build it cannot. So it compiled where it was written
# and failed everywhere else, and since #1347 that suite is the ONLY verification a Mac change gets.
#
# This check lives in the shell, NOT in a Swift test, and that is the point. An offending import stops
# the target compiling, so a Swift guard against it could never run to report it: it would sit silent
# through exactly the break it was written for. Here it runs before xcodebuild is called at all, and
# says which file to fix instead of "unable to resolve module dependency".
#
# Usage: scripts/check-pure-suite-imports.sh [file ...]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The directories compiled into the pure suite. TestSupport counts because the HOSTED target does link
# the app, so an import added to a shared helper would compile in one target and break the other.
PURE_SUITE_DIRS=("mac/OvertureTests" "mac/TestSupport")

# Pure-ish: given a list of files, echo one line per offender. Empty output means clean.
#
# Matches an import statement standing alone on its line, so a comment discussing the rule (this file's
# own prose, an issue reference in a test) is never mistaken for one. Both spellings count: @testable
# buys nothing here, and neither resolves.
app_module_import_violations() {
  # ONE grep over every file, not one grep per file, and that is a fix rather than a tidy-up.
  #
  # It was a process substitution inside the loop, so a run over the pure suite forked 1,031 greps. Alone
  # that is three seconds and looks fine. Under `scripts/run-shell-fixtures.sh`, where eight lanes fork at
  # once, it exhausts the per-user process table: `fork` starts failing, bash retries, and the fixture
  # sits at 100% CPU making no progress. Measured on this Mac 2026-09-08, three times, wedging at exactly
  # the same point each time (374 open pipes, about 187 files in), while the same fixture run on its own
  # through the same runner finished in three seconds.
  #
  # That is L102 exactly: the cost was measured with the expensive path switched off, so the number read
  # as reassurance for the one case nobody had tested. It is also why the wedge looked like a hang and
  # not like slowness, and why killing it and re-running never learned anything.
  local files=() file
  for file in "$@"; do
    # A file that does not exist is skipped rather than fatal: main() globs the tree, and a file deleted
    # between the glob and the read must not take the whole check down with it.
    [[ -f "${file}" ]] && files+=("${file}")
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  # `-H` so the filename is printed even when exactly one file is left, which is what a caller checking a
  # single path gets. Without it a one-file call prints `12:` and the reformatting below silently drops
  # the name it exists to report.
  local found status
  found="$(grep -HnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+Overture[[:space:]]*$' \
    "${files[@]}")"
  status=$?
  # THREE OUTCOMES, not two, and the third is the one that matters. grep exits 0 when it matched, 1 when
  # it did not, and 2 or more when it FAILED (a file it could not read, a bad pattern). Folding 1 and 2
  # together is the shape L11 names: a check that could not run would report the same clean answer as one
  # that ran and found nothing, and this guard's whole job is to be believed when it says the pure suite
  # will compile.
  if [[ ${status} -gt 1 ]]; then
    echo "check-pure-suite-imports: UNMEASURED: grep failed (status ${status}) over ${#files[@]} files." >&2
    return 2
  fi
  [[ -n "${found}" ]] || return 0
  while IFS=: read -r file line_number _; do
    [[ -n "${line_number}" ]] || continue
    echo "${file}:${line_number}: imports the app as a module, which the pure suite cannot resolve"
  done <<< "${found}"
  return 0
}

main() {
  local files=()
  if [[ $# -gt 0 ]]; then
    files=("$@")
  else
    local dir
    for dir in "${PURE_SUITE_DIRS[@]}"; do
      [[ -d "${REPO_ROOT}/${dir}" ]] || continue
      while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find "${REPO_ROOT}/${dir}" -name '*.swift' -print0 | sort -z)
    done
  fi

  # An empty file list would make this pass while checking nothing, which is the shape of guard that
  # reports clean for years. Say so instead.
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "check-pure-suite-imports: BLOCK: found no Swift files to check under ${PURE_SUITE_DIRS[*]}." >&2
    exit 1
  fi

  local violations
  violations="$(app_module_import_violations "${files[@]}")"
  if [[ -n "${violations}" ]]; then
    echo "check-pure-suite-imports: BLOCK: the pure Swift suite will not compile." >&2
    echo "${violations}" >&2
    echo "" >&2
    echo "  OvertureTests compiles the app's sources in rather than linking the app, so its types are" >&2
    echo "  already visible and there is no module to import. Delete the import line." >&2
    echo "  A test that genuinely needs the app RUNNING (ViewInspector) belongs in OvertureHostedTests," >&2
    echo "  which does link it and where the import is correct." >&2
    exit 1
  fi
  echo "OK: no file in the pure suite imports the app as a module (${#files[@]} files checked)."
}

# Only run main when executed, so the test can source this file for app_module_import_violations.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
