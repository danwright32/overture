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
  local files=("$@") file line_number
  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    while IFS=: read -r line_number _; do
      [[ -n "${line_number}" ]] || continue
      echo "${file}:${line_number}: imports the app as a module, which the pure suite cannot resolve"
    done < <(grep -nE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+Overture[[:space:]]*$' "${file}")
  done
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
