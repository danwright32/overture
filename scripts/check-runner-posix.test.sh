#!/usr/bin/env bash
set -uo pipefail

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

TMP="$(mktemp -d)"
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

# And the real thing: every runner the app actually launches.
real=()
while IFS= read -r -d '' f; do real+=("$f"); done \
  < <(find "${REPO_ROOT}/mac/scripts" -name '*.sh' ! -name '*.test.sh' -print0 | sort -z)
assert_empty "every real #!/bin/sh runner under mac/scripts parses under sh" \
  "$(posix_parse_violations "${real[@]}")"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all check-runner-posix checks passed"
