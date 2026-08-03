#!/usr/bin/env bash
set -uo pipefail

# Drives check-pure-suite-imports.sh against fixture files, so it runs anywhere including CI, and against
# the REAL test directories, so the thing it exists to prevent is actually prevented.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected no violations, got: ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/check-pure-suite-imports.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The exact line that stopped the whole Swift suite compiling on 2026-08-03, in the spelling all four
# offending files used.
cat > "${TMP}/testable.swift" <<'EOF'
import Testing
import Foundation
@testable import Overture

@Suite("something") struct S {}
EOF
assert_contains "a @testable import of the app module is caught" \
  "$(app_module_import_violations "${TMP}/testable.swift")" "testable.swift:3"

# The plain spelling resolves no better, so it is caught too.
cat > "${TMP}/plain.swift" <<'EOF'
import Foundation
import Overture
EOF
assert_contains "a plain import of the app module is caught" \
  "$(app_module_import_violations "${TMP}/plain.swift")" "plain.swift:2"

# Indented (inside an #if, say) is still an import statement.
cat > "${TMP}/indented.swift" <<'EOF'
#if DEBUG
    @testable import Overture
#endif
EOF
assert_contains "an indented import is caught" \
  "$(app_module_import_violations "${TMP}/indented.swift")" "indented.swift:2"

# Prose ABOUT the rule must not be mistaken for the rule being broken. This check's own comments, and
# every issue reference in a test file, name the banned line: flagging those would make the check
# unusable and train everyone to ignore it.
cat > "${TMP}/comment.swift" <<'EOF'
import Foundation
// Deliberately no `@testable import Overture` here: the pure suite compiles the app's sources in.
/* import Overture would not resolve in this target. */
let note = "@testable import Overture"
EOF
assert_empty "a comment or string mentioning the import is not flagged" \
  "$(app_module_import_violations "${TMP}/comment.swift")"

# Importing anything else is ordinary and untouched.
cat > "${TMP}/clean.swift" <<'EOF'
import Testing
import Foundation
import SwiftData
EOF
assert_empty "a file importing other modules passes" \
  "$(app_module_import_violations "${TMP}/clean.swift")"

# A file that does not exist is skipped rather than crashing the run: main() globs the tree, and a file
# deleted between the glob and the read must not take the whole check down with it.
assert_empty "a missing file is skipped, not fatal" \
  "$(app_module_import_violations "${TMP}/does-not-exist.swift")"

# main() must FAIL, not pass quietly, when its own file list comes back empty. A guard whose glob stops
# matching (a directory renamed, the script moved) would otherwise report clean forever while checking
# nothing, which is the failure this whole file exists to make impossible. Run the real script from a
# tree that has no mac/ directories at all.
mkdir -p "${TMP}/lonely/scripts"
cp "${SCRIPT_DIR}/check-pure-suite-imports.sh" "${TMP}/lonely/scripts/"
empty_output="$("${TMP}/lonely/scripts/check-pure-suite-imports.sh" 2>&1)"
empty_status=$?
assert_contains "a glob that matches nothing blocks instead of passing" \
  "${empty_output}" "found no Swift files to check"
if [[ ${empty_status} -eq 0 ]]; then
  echo "FAIL - checking nothing exited 0; a vacuous guard must fail loudly"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - checking nothing exits non-zero"
fi

# The hosted target DOES link the app, so the import is correct there and this check must not reach it.
# Asserted through main()'s own directory list rather than by re-deriving it here.
if [[ " ${PURE_SUITE_DIRS[*]} " == *" mac/OvertureHostedTests "* ]]; then
  echo "FAIL - the hosted tests must not be checked: the import is legitimate there"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - the hosted tests are left alone, where the import is legitimate"
fi

# And the real thing: every file actually compiled into the pure suite.
real=()
for dir in "${PURE_SUITE_DIRS[@]}"; do
  while IFS= read -r -d '' f; do real+=("$f"); done \
    < <(find "${REPO_ROOT}/${dir}" -name '*.swift' -print0 | sort -z)
done
if [[ ${#real[@]} -lt 100 ]]; then
  echo "FAIL - expected to walk the pure suite's real sources, found ${#real[@]}"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - walked ${#real[@]} real pure-suite sources"
fi
assert_empty "no real file in the pure suite imports the app as a module" \
  "$(app_module_import_violations "${real[@]}")"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all check-pure-suite-imports checks passed"
