#!/usr/bin/env bash
set -uo pipefail

# #2318: a test run must leave the working tree exactly as it found it.
#
# #1994 fixed ONE test that rewrote a checked-in file during any run, including runs never meant to
# change anything. Nothing established it was the only one. The danger is not the write, it is that
# the result is indistinguishable from a person's own edit, so review cannot catch it and the author
# has no reason to look: in #1994's own incident a `fatalError` string, added purely to break the app
# on purpose, ended up in the checked-in list of what Overture says to Dan, where a `git add -A`
# would have shipped it.
#
# This has to observe the whole run from OUTSIDE it, which is why it is a step in test-all.sh rather
# than a Swift test: a test cannot watch what its own suite does to the repo after it finishes.
#
# It compares CONTENT before and after, not "is the tree clean". Nobody runs the suite on a pristine
# checkout, so a check that only means something on one would mean nothing on almost every real run,
# and it would fail for the ordinary reason (uncommitted work) rather than the real one. Comparing
# before against after blames the run for exactly what the run did, and nothing else.
#
# Usage: check-tree-untouched.sh record <repo-dir> <snapshot-file>
#        check-tree-untouched.sh compare <repo-dir> <snapshot-file>

usage() {
  echo "Usage: $(basename "$0") record|compare <repo-dir> <snapshot-file>" >&2
  exit 2
}

# What the tree looks like right now: one line per path, carrying that path's status AND a hash of
# its contents.
#
# Both halves are needed, and so is the per-path SHAPE. Status alone cannot see a run rewriting a
# file that was already modified before it started, because the status line reads the same either
# way, and that is precisely the tree most people run the suite on. A bulk content diff can see it
# but reports it as changed hunks, so the failure shows the words that moved and never names the
# file they moved in, which is the one thing the reader needs (L80). A line per path gives both: any
# difference at all names its own file.
#
# The snapshot file itself is excluded when it happens to sit inside the tree, or this check reports
# its own working note as something the run left behind, and fails every clean run.
tree_state() {
  local dir="$1" snapshot="${2:-}"
  local own=""
  case "${snapshot}" in "${dir}/"*) own="${snapshot#"${dir}"/}" ;; esac
  git -C "${dir}" status --porcelain -uall -z | while IFS= read -r -d '' entry; do
    local status="${entry:0:2}"
    local path="${entry:3}"
    # A rename's porcelain entry is followed by its own NUL-separated source path, which is not a
    # path in its own right and must not be read as the next entry.
    if [[ "${status}" == R* || "${status}" == C* ]]; then IFS= read -r -d '' _source; fi
    if [[ -n "${own}" && "${path}" == "${own}" ]]; then continue; fi
    if [[ -f "${dir}/${path}" ]]; then
      echo "${status} ${path} $(shasum -a 256 "${dir}/${path}" | cut -d' ' -f1)"
    else
      echo "${status} ${path} (not a regular file)"
    fi
  done | sort
}

record() {
  local dir="$1" snapshot="$2"
  tree_state "${dir}" "${snapshot}" > "${snapshot}"
}

compare() {
  local dir="$1" snapshot="$2"
  if [[ ! -f "${snapshot}" ]]; then
    echo "check-tree-untouched: no snapshot at ${snapshot}, so nothing was measured." >&2
    echo "The run's effect on the working tree is UNKNOWN, which is not the same as none." >&2
    return 1
  fi

  local after
  after="$(tree_state "${dir}" "${snapshot}")"
  if [[ "${after}" == "$(cat "${snapshot}")" ]]; then
    return 0
  fi

  echo "" >&2
  echo "check-tree-untouched: the test run CHANGED the working tree." >&2
  echo "" >&2
  echo "These edits were made by the suite, not by you, and they are indistinguishable from your own" >&2
  echo "work: a git add -A would commit them. Look before you stage anything." >&2
  echo "" >&2
  diff <(cat "${snapshot}") <(echo "${after}") | head -60 >&2
  echo "" >&2
  echo "If a run is MEANT to rewrite a checked-in file, it needs its own opt-in variable and a line" >&2
  echo "here saying the check was skipped, the way the copy inventory regeneration does." >&2
  return 1
}

main() {
  [[ $# -eq 3 ]] || usage
  local mode="$1" dir="$2" snapshot="$3"
  case "${mode}" in
    record) record "${dir}" "${snapshot}" ;;
    compare) compare "${dir}" "${snapshot}" ;;
    *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
