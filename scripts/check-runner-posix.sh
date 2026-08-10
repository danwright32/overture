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
# #1619: and so is every helper it SOURCES, transitively. A sourced file is executed by whichever shell
# sourced it, so its own shebang decides nothing at all: the runners declare `#!/bin/sh` and source
# helpers under mac/scripts/lib/ that declare `#!/usr/bin/env bash`, and bash-only syntax in one of those
# dies at run time exactly as if it had been written in the runner itself. Reading the helper alone gives
# the opposite impression, which is why this needs a guard rather than care. #1597 put significant new
# code into one of those helpers, having been prompted by this same class of failure.
#
# Usage: scripts/check-runner-posix.sh [file ...]

# REPO_ROOT_OVERRIDE is a test seam (#1710): it lets a fixture point this check at a tree with no
# runners in it, which is the only way to watch the empty-subject refusal below actually fire.
REPO_ROOT="${REPO_ROOT_OVERRIDE:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

# Echo one line per file that `file` sources, resolved the way the shell will resolve it at run time.
#
# Two forms appear in this repo, and they anchor to DIFFERENT directories, which is the whole reason this
# resolves paths rather than pattern-matching names:
#
#   . "$(dirname "$0")/lib/<name>.sh"            the runners' form. `$0` stays the ROOT runner inside a
#                                                sourced file, so this anchors to the root's directory
#                                                however deep the sourcing goes: hence root_dir.
#   . "$(dirname "${BASH_SOURCE[0]}")/<name>.sh" one helper reaching a sibling helper (scout-tools.sh).
#                                                BASH_SOURCE[0] is the file doing the sourcing, so this
#                                                anchors to the CURRENT file's directory.
#
# A source line in a form this cannot resolve is echoed with a leading "?" rather than dropped, so the
# caller can report it. Silently skipping what it cannot read is how a guard ends up inspecting nothing
# and reporting that as clean.
sourced_helper_paths() {
  local file="$1" root_dir="$2" line rel file_dir
  file_dir="$(cd "$(dirname "${file}")" && pwd)"
  while IFS= read -r line; do
    # The substitutions are delimited with % because the patterns themselves contain an alternation.
    rel="$(printf '%s\n' "${line}" \
      | sed -nE 's%^[[:space:]]*(\.|source)[[:space:]]+"[$][(]dirname "[$]0"[)]/([^"]*)".*%\2%p')"
    if [[ -n "${rel}" ]]; then
      printf '%s\n' "${root_dir}/${rel}"
      continue
    fi
    rel="$(printf '%s\n' "${line}" \
      | sed -nE 's%^[[:space:]]*(\.|source)[[:space:]]+"[$][(]dirname "[$][{]BASH_SOURCE\[0\][}]"[)]/([^"]*)".*%\2%p')"
    if [[ -n "${rel}" ]]; then
      printf '%s\n' "${file_dir}/${rel}"
      continue
    fi
    printf '?%s\n' "${line}"
  done < <(grep -E '^[[:space:]]*(\.|source)[[:space:]]' "${file}" 2>/dev/null)
}

# Pure-ish: given a list of files, echo one line per offender. Empty output means clean.
posix_parse_violations() {
  local files=("$@") file shebang root_dir current helper index
  local -a queue
  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    shebang="$(head -1 "${file}")"
    # Only scripts that CLAIM /bin/sh are held to it. A script with a bash shebang may use bash.
    case "${shebang}" in
      "#!/bin/sh"|"#!/bin/sh "*) ;;
      *) continue ;;
    esac

    root_dir="$(cd "$(dirname "${file}")" && pwd)"
    queue=("${file}")
    index=0
    while [[ ${index} -lt ${#queue[@]} ]]; do
      current="${queue[${index}]}"
      index=$((index + 1))

      if [[ ! -f "${current}" ]]; then
        echo "${file}: sources '${current}', which does not exist"
        continue
      fi
      if ! sh -n "${current}" 2>/dev/null; then
        if [[ "${current}" == "${file}" ]]; then
          echo "${current}: declares #!/bin/sh but does not parse under sh (run: sh -n '${current}')"
        else
          echo "${current}: sourced by ${file}, which runs under /bin/sh, but does not parse under sh (run: sh -n '${current}')"
        fi
      fi

      while IFS= read -r helper; do
        [[ -n "${helper}" ]] || continue
        if [[ "${helper}" == '?'* ]]; then
          echo "${file}: cannot resolve the helper sourced by ${current} at:${helper#?}"
          continue
        fi
        # A file already queued for this root is not queued twice, so a cycle cannot spin.
        case " ${queue[*]} " in *" ${helper} "*) continue ;; esac
        queue+=("${helper}")
      done < <(sourced_helper_paths "${current}" "${root_dir}")
    done
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

  # #1710: no scripts found is a broken path, not a clean tree. Without this, a reorganisation that
  # moves mac/scripts leaves this printing "every #!/bin/sh script parses under sh" about no scripts
  # at all, and that sentence is indistinguishable from the one it prints when it really checked them.
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "check-runner-posix: BLOCK: found no runner scripts to check under ${REPO_ROOT}/mac/scripts." >&2
    echo "  Nothing was verified. That is not the same as nothing being wrong." >&2
    exit 1
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
  echo "OK: every #!/bin/sh script under mac/scripts, and every helper it sources, parses under sh."
}

# Only run main when executed, so the test can source this file for posix_parse_violations.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
