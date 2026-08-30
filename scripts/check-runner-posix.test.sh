#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Drives check-runner-posix.sh against fixture files, so it runs anywhere including CI, and against the
# REAL runners, so the thing it exists to prevent is actually prevented.

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
source "${SCRIPT_DIR}/check-runner-posix.sh"

TMP="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP}"' EXIT

# The exact construct that took the first real reachability check down on 2026-07-27. `bash -n` accepts
# it; /bin/sh does not, and /bin/sh is what the app launches these with.
cat > "${TMP}/process-substitution.sh" <<'EOF'
#!/bin/sh
echo hi > >(cat)
EOF
violations="$(posix_parse_violations "${TMP}/process-substitution.sh")"
assert_contains "process substitution in a #!/bin/sh script is caught" \
  "${violations}" "does not parse under sh"

# Reading process substitution, the same construct in the other direction.
#
# NOTE on what this check can and cannot catch: macOS /bin/sh is bash in POSIX mode, which still ACCEPTS
# plenty of bash-isms ([[ ]] and arrays among them). So this is not a general "is it POSIX" linter, and
# claiming it were would be the more dangerous kind of wrong. It asserts the narrower, true thing: the
# script parses under the shell that will actually run it. Process substitution is the construct that
# shell genuinely rejects, and it is the one that took the first real check down.
cat > "${TMP}/read-process-substitution.sh" <<'EOF'
#!/bin/sh
while read -r line; do echo "$line"; done < <(echo hi)
EOF
violations="$(posix_parse_violations "${TMP}/read-process-substitution.sh")"
assert_contains "reading process substitution in a #!/bin/sh script is caught" \
  "${violations}" "does not parse under sh"

# Plain POSIX is fine.
cat > "${TMP}/clean.sh" <<'EOF'
#!/bin/sh
if [ -n "$1" ]; then echo yes; fi
EOF
assert_empty "a POSIX-clean #!/bin/sh script passes" \
  "$(posix_parse_violations "${TMP}/clean.sh")"

# A script that declares bash is allowed to use bash. The check is about honouring your own shebang.
cat > "${TMP}/declares-bash.sh" <<'EOF'
#!/usr/bin/env bash
echo hi > >(cat)
EOF
assert_empty "a #!/usr/bin/env bash script is not held to POSIX" \
  "$(posix_parse_violations "${TMP}/declares-bash.sh")"

# #1619: a helper is EXECUTED by whichever shell sourced it, so its own shebang decides nothing. The
# runners declare #!/bin/sh and source helpers that declare bash, meaning bash-only syntax in a helper
# dies at run time while the helper, read alone, looks entitled to it.
mkdir -p "${TMP}/lib"
cat > "${TMP}/lib/bash-only-helper.sh" <<'EOF'
#!/usr/bin/env bash
emit() { echo hi > >(cat); }
EOF
cat > "${TMP}/sources-bash-only.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib/bash-only-helper.sh"
emit
EOF
violations="$(posix_parse_violations "${TMP}/sources-bash-only.sh")"
assert_contains "a bash-only helper sourced by a #!/bin/sh runner is caught" \
  "${violations}" "does not parse under sh"
assert_contains "the violation names the helper that will not parse" \
  "${violations}" "lib/bash-only-helper.sh"
assert_contains "the violation names the runner that sources it" \
  "${violations}" "sources-bash-only.sh"

# A helper that parses under sh is fine whatever its own shebang says.
cat > "${TMP}/lib/clean-helper.sh" <<'EOF'
#!/usr/bin/env bash
emit() { echo hi; }
EOF
cat > "${TMP}/sources-clean.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib/clean-helper.sh"
emit
EOF
assert_empty "a POSIX-parsing helper sourced by a #!/bin/sh runner passes" \
  "$(posix_parse_violations "${TMP}/sources-clean.sh")"

# The shebang that decides is the ROOT script's. A bash script may source bash helpers.
cat > "${TMP}/bash-sources-bash-only.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/bash-only-helper.sh"
emit
EOF
assert_empty "a bash runner's helpers are not held to POSIX" \
  "$(posix_parse_violations "${TMP}/bash-sources-bash-only.sh")"

# A helper sourcing a helper: $0 is still the root runner, so the deeper file runs under /bin/sh too.
cat > "${TMP}/lib/middle-helper.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/bash-only-helper.sh"
EOF
cat > "${TMP}/sources-transitively.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib/middle-helper.sh"
emit
EOF
assert_contains "a helper sourced through another helper is still parsed" \
  "$(posix_parse_violations "${TMP}/sources-transitively.sh")" "lib/bash-only-helper.sh"

# The other sourcing form in the tree: a helper reaching a sibling by BASH_SOURCE rather than $0, which
# anchors to the helper's own directory instead of the runner's. scout-tools.sh reaches claude-run-scope.sh
# this way, and reading it as unresolvable would have blocked the real runners on a form that works.
mkdir -p "${TMP}/lib/nested"
cat > "${TMP}/lib/nested/sibling-helper.sh" <<'EOF'
#!/usr/bin/env bash
emit() { echo hi > >(cat); }
EOF
cat > "${TMP}/lib/nested/reaches-sibling.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/sibling-helper.sh"
EOF
cat > "${TMP}/sources-via-bash-source.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib/nested/reaches-sibling.sh"
emit
EOF
violations="$(posix_parse_violations "${TMP}/sources-via-bash-source.sh")"
assert_contains "a sibling reached by BASH_SOURCE is resolved and parsed" \
  "${violations}" "lib/nested/sibling-helper.sh"
assert_empty "resolving a BASH_SOURCE form does not report it as unresolvable" \
  "$(printf '%s\n' "${violations}" | grep 'cannot resolve')"

# A source line this check cannot resolve must be reported, never quietly skipped: a guard that inspects
# nothing and says nothing is indistinguishable from a guard that found nothing wrong.
cat > "${TMP}/sources-unresolvable.sh" <<'EOF'
#!/bin/sh
LIB_DIR=/somewhere
. "${LIB_DIR}/mystery.sh"
EOF
assert_contains "a source path the check cannot resolve is reported" \
  "$(posix_parse_violations "${TMP}/sources-unresolvable.sh")" "cannot resolve"

# A helper named but absent is a violation too, not a silent skip.
cat > "${TMP}/sources-missing.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib/not-there.sh"
EOF
assert_contains "a sourced helper that does not exist is reported" \
  "$(posix_parse_violations "${TMP}/sources-missing.sh")" "does not exist"

# And the real thing: every runner the app actually launches.
real=()
while IFS= read -r -d '' f; do real+=("$f"); done \
  < <(find "${REPO_ROOT}/mac/scripts" -name '*.sh' ! -name '*.test.sh' -print0 | sort -z)
assert_empty "every real #!/bin/sh runner under mac/scripts parses under sh" \
  "$(posix_parse_violations "${real[@]}")"

# The assertion above passes just as happily if helper resolution silently stopped working, so pin that
# the real runners really do reach their real helpers. prep-run.sh sources scout-parallel.sh, the file
# #1597 put significant new code into, and it is the reason this issue exists.
resolved="$(sourced_helper_paths "${REPO_ROOT}/mac/scripts/prep-run.sh" "${REPO_ROOT}/mac/scripts")"
assert_contains "prep-run.sh's helpers resolve to real files on disk" \
  "${resolved}" "mac/scripts/lib/scout-parallel.sh"
assert_contains "prep-run.sh's helper list reaches runner-setup.sh too" \
  "${resolved}" "mac/scripts/lib/runner-setup.sh"

# #1710: a guard that finds no scripts to check must say so, not report that every script parses.
#
# The check resolves its subject with a `find` over a hardcoded directory, and the whole class this
# issue is about is a check whose subject silently resolves to nothing and whose "no violations
# found" then reads exactly like "everything is fine". Here that sentence would be "every #!/bin/sh
# script under mac/scripts parses under sh", said about no scripts at all.
EMPTY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/runner-posix-empty.XXXXXX")"
OUTPUT="$(REPO_ROOT_OVERRIDE="${EMPTY_DIR}" "${SCRIPT_DIR}/check-runner-posix.sh" 2>&1)"
EXIT=$?
if [[ "${EXIT}" -eq 0 ]]; then
  echo "FAIL - a run that finds no scripts reports success"
  echo "  it said: ${OUTPUT}"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - a run that finds no scripts to check fails instead of reporting them all clean"
fi
assert_contains "the refusal names the directory it searched" "${OUTPUT}" "${EMPTY_DIR}"
rm -rf "${EMPTY_DIR}"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all check-runner-posix checks passed"
