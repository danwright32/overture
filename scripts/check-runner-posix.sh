#!/usr/bin/env bash
set -uo pipefail

# #1596 follow-up: every script the app launches must PARSE under the shell that will actually run it.
#
# The app launches its detached runners with /bin/sh (DetachedRunner.swift: executableURL is /bin/sh,
# arguments are ["-c", "'<script>' >/dev/null 2>&1 &"]), and each runner declares `#!/bin/sh`. On macOS
# /bin/sh is bash in POSIX mode, where several bash conveniences are simply absent: process substitution
# `cmd > >(...)`, `[[ ]]`, arrays, `local` in some forms.
#
# On 2026-07-27 a `> >(tee_run_events ...)` was added to prep-run.sh to capture the run's event stream.
# `bash -n` passed, the Swift suite passed, the shell unit tests passed, and the change merged. The first
# real run died instantly with "syntax error near unexpected token `>`", because none of those checks ran
# the script through the shell that launches it. The failure was loud and cost nothing, but only because
# it happened to be a reachability check rather than a night of drafting.
#
# So: any script declaring a /bin/sh shebang is parsed with `sh -n`. Parsing only, never executing.
#
# Usage: scripts/check-runner-posix.sh [file ...]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pure-ish: given a list of files, echo one line per offender. Empty output means clean.
posix_parse_violations() {
  local files=("$@") file shebang
  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    shebang="$(head -1 "${file}")"
    # Only scripts that CLAIM /bin/sh are held to it. A script with a bash shebang may use bash.
    case "${shebang}" in
      "#!/bin/sh"|"#!/bin/sh "*) ;;
      *) continue ;;
    esac
    if ! sh -n "${file}" 2>/dev/null; then
      echo "${file}: declares #!/bin/sh but does not parse under sh (run: sh -n '${file}')"
    fi
  done
}

main() {
  local files=()
  if [[ $# -gt 0 ]]; then
    files=("$@")
  else
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find "${REPO_ROOT}/mac/scripts" -name '*.sh' ! -name '*.test.sh' -print0 | sort -z)
  fi

  local violations
  violations="$(posix_parse_violations "${files[@]}")"
  if [[ -n "${violations}" ]]; then
    echo "check-runner-posix: BLOCK: a script the app launches with /bin/sh will not parse there." >&2
    echo "${violations}" >&2
    echo "" >&2
    echo "  bash -n is NOT enough for these: the app runs them through /bin/sh, which on macOS is" >&2
    echo "  bash in POSIX mode. Process substitution, [[ ]] and arrays are unavailable there." >&2
    exit 1
  fi
  echo "OK: every #!/bin/sh script under mac/scripts parses under sh."
}

# Only run main when executed, so the test can source this file for posix_parse_violations.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
