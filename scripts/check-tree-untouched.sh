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
    # TAB separated, so the PATH is one field however many spaces are in it. #2843 reads the path
    # back out of these lines to say which of three things happened to it, and splitting on spaces
    # would mis-read exactly the untracked file with a space in its name that a run is most likely
    # to leave behind.
    if [[ -f "${dir}/${path}" ]]; then
      printf '%s\t%s\t%s\n' "${status}" "${path}" "$(shasum -a 256 "${dir}/${path}" | cut -d' ' -f1)"
    else
      printf '%s\t%s\t%s\n' "${status}" "${path}" "(not a regular file)"
    fi
  done | sort
}

record() {
  local dir="$1" snapshot="$2"
  tree_state "${dir}" "${snapshot}" > "${snapshot}"
}

# The three ways a snapshot line can differ, split apart so the failure can say what it MEASURED
# instead of naming a culprit (#2843).
#
# It used to say "these edits were made by the suite, not by you" for every difference, which it has
# no way of knowing. On 2026-08-16 a person committed their own work in another checkout sharing this
# repository while a run was in flight: twenty modified paths became clean, the comparison saw the
# tree change, and the message sent an agent 26 minutes into a suite defect that did not exist, with
# a remedy (an opt-in variable) for a problem it did not have (L111). It fires precisely when several
# things touch the repository at once, which is now the ordinary working mode here, so a false
# accusation teaches people to disregard a check that is otherwise load-bearing (L36).
#
# Two of the three CAN be told apart, and the third genuinely cannot, which is itself worth saying:
#   clean -> changed   the suite writing, and the only case the opt-in advice is true of
#   changed -> clean   a commit, stash or checkout, or a run restoring a file over uncommitted work
#   changed -> changed different content on an already-modified path, which both look identical in
#
# Every difference still FAILS. What changed is the claim, not the verdict: the tree not being as the
# run found it is the measured fact, and each of the three is worth somebody looking at.
#
# Compared by PATH, the second TAB separated field of each line, so a status change with identical
# content (staging an already-modified file) is a difference like any other.
paths_of() {
  awk -F'\t' 'NF { print $2 }' <<< "$1" | sort -u
}

line_for() {
  awk -F'\t' -v want="$2" '$2 == want { print }' <<< "$1"
}

paths_only_in() {
  comm -23 <(paths_of "$1") <(paths_of "$2")
}

paths_changed_in_both() {
  local before="$1" after="$2" shared path
  shared="$(comm -12 <(paths_of "${before}") <(paths_of "${after}"))"
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if [[ "$(line_for "${before}" "${path}")" != "$(line_for "${after}" "${path}")" ]]; then
      echo "${path}"
    fi
  done <<< "${shared}"
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
  echo "check-tree-untouched: the working tree is not as this run found it." >&2

  local written cleaned ambiguous
  written="$(paths_only_in "${after}" "$(cat "${snapshot}")")"
  cleaned="$(paths_only_in "$(cat "${snapshot}")" "${after}")"
  ambiguous="$(paths_changed_in_both "$(cat "${snapshot}")" "${after}")"

  # Each bucket says what it MEASURED and no more, and only the first of the three is evidence the
  # suite wrote anything, so only the first carries the opt-in advice (#2843, L11).
  if [[ -n "${written}" ]]; then
    echo "" >&2
    echo "WENT FROM CLEAN TO CHANGED during the run, which is what the suite writing looks like:" >&2
    sed 's/^/  /' <<< "${written}" >&2
    echo "" >&2
    echo "These are indistinguishable from your own work: a git add -A would commit them. Look before" >&2
    echo "you stage anything. If a run is MEANT to rewrite a checked-in file, it needs its own opt-in" >&2
    echo "variable and a line here saying the check was skipped, the way the copy inventory" >&2
    echo "regeneration does." >&2
  fi

  if [[ -n "${cleaned}" ]]; then
    echo "" >&2
    echo "WERE UNCOMMITTED BEFORE THE RUN AND ARE CLEAN NOW:" >&2
    sed 's/^/  /' <<< "${cleaned}" >&2
    echo "" >&2
    echo "The suite does not do this by writing. It is what a commit, a stash or a checkout looks like," >&2
    echo "including one made in ANOTHER worktree sharing this repository while the run was going. Check" >&2
    echo "there first. The one way a RUN produces it is a step restoring a file over your uncommitted" >&2
    echo "work, so if nobody committed, that is what to look for." >&2
  fi

  if [[ -n "${ambiguous}" ]]; then
    echo "" >&2
    echo "WERE ALREADY UNCOMMITTED BEFORE THE RUN AND HAVE CHANGED AGAIN:" >&2
    sed 's/^/  /' <<< "${ambiguous}" >&2
    echo "" >&2
    echo "This check cannot tell whether the run wrote these or you did: both leave a modified file" >&2
    echo "modified. Compare them against what you meant to have there." >&2
  fi

  echo "" >&2
  diff <(cat "${snapshot}") <(echo "${after}") | head -60 >&2
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
