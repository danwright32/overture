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
# It watches TWO halves, and they have different verdicts (#3161).
#
# The tracked and untracked half FAILS, as it always has. The IGNORED half only REPORTS. Until #3161
# there was no ignored half at all: `git status --porcelain -uall` lists tracked and untracked paths
# and not ignored ones, so a run that wrote a gitignored file into the repository was invisible to the
# guard whose whole job is noticing that a run changed the tree, and ignored paths are the likeliest
# place for a scratch or state file to land. Measured 2026-08-23 while building #2991: a fixture drove
# the real run-tests-locked.sh and its measuring case wrote `.overture-live-corpus-seen` into the
# repository root, recording that both live-store invariants had examined rows on a day the live store
# held none of either. This check passed clean; a person found it by reading the file by hand.
#
# That same file is why the ignored half cannot refuse. An ordinary run writes it legitimately every
# time the invariants really do measure something, so a rule that failed on it would fire on the
# ordinary case and be switched off within a day (L93). Putting the list in front of a person is the
# whole of what was missing.
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
# Reads ONE `git status --porcelain -z` listing and emits a snapshot line per entry it keeps: that
# path's status, the path, and a hash of its contents.
#
# Both halves of the snapshot go through here so the line format, the rename handling and the
# exclusion of the snapshot file itself cannot drift apart between them.
#
# `keep` is "ignored" or "tracked", and the two are exclusive: every entry belongs to exactly one
# half, so nothing can be counted twice or fall between them.
porcelain_state() {
  local dir="$1" own="$2" keep="$3"
  shift 3
  git -C "${dir}" status --porcelain -z "$@" | while IFS= read -r -d '' entry; do
    local status="${entry:0:2}"
    local path="${entry:3}"
    # A rename's porcelain entry is followed by its own NUL-separated source path, which is not a
    # path in its own right and must not be read as the next entry.
    if [[ "${status}" == R* || "${status}" == C* ]]; then IFS= read -r -d '' _source; fi
    if [[ "${keep}" == "ignored" ]]; then
      [[ "${status}" == "!!" ]] || continue
    else
      [[ "${status}" == "!!" ]] && continue
    fi
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
  done
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
#
# The ignored half is read with `-unormal` and NOT `-uall`, which is what keeps this cheap. With
# `-uall` git expands every ignored DIRECTORY into its every file: measured on this repository
# 2026-08-24, 9,690 entries that way against 12 collapsed, nearly all of it Xcode build output and
# node_modules that every run is supposed to write. Collapsed, an ignored directory is a single entry
# whose contents read "(not a regular file)", so churn inside one is invisible here. What that gives
# up is a stray file written into a directory that is ALREADY ignored; what it keeps is the case that
# matters, a stray ignored file in a directory that is not, which is still listed on its own.
tree_state() {
  local dir="$1" snapshot="${2:-}"
  local own=""
  case "${snapshot}" in "${dir}/"*) own="${snapshot#"${dir}"/}" ;; esac
  {
    porcelain_state "${dir}" "${own}" tracked -uall
    porcelain_state "${dir}" "${own}" ignored -unormal --ignored
  } | sort
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

# The tracked and untracked half of a difference: still three buckets, still a failure (#2843).
report_tracked() {
  local before="$1" after="$2"
  echo "" >&2
  echo "check-tree-untouched: the working tree is not as this run found it." >&2

  local written cleaned ambiguous
  written="$(paths_only_in "${after}" "${before}")"
  cleaned="$(paths_only_in "${before}" "${after}")"
  ambiguous="$(paths_changed_in_both "${before}" "${after}")"

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
  diff <(echo "${before}") <(echo "${after}") | head -60 >&2
}

# The IGNORED half of a difference (#3161): named, and never a verdict.
#
# Three kinds, kept apart for the same reason the tracked side keeps its three apart: they have
# different causes, and a reader who cannot tell a file the run CREATED from one it deleted has to go
# and find out by hand, which is exactly the step this exists to remove.
report_ignored() {
  local before="$1" after="$2"
  local appeared gone rewritten
  appeared="$(paths_only_in "${after}" "${before}")"
  gone="$(paths_only_in "${before}" "${after}")"
  rewritten="$(paths_changed_in_both "${before}" "${after}")"

  echo "" >&2
  echo "IGNORED PATHS THIS RUN CHANGED. A report, and NOT a failure: the verdict is the tracked half" >&2
  echo "alone." >&2
  [[ -n "${appeared}" ]] && sed 's|^|  appeared:  |' <<< "${appeared}" >&2
  [[ -n "${rewritten}" ]] && sed 's|^|  rewritten: |' <<< "${rewritten}" >&2
  [[ -n "${gone}" ]] && sed 's|^|  gone:      |' <<< "${gone}" >&2
  echo "" >&2
  echo "git status does not list ignored paths, so before #3161 a run could write one of these into" >&2
  echo "the repository and this check saw nothing, which is the likeliest place for a scratch or state" >&2
  echo "file to land. Some of them a run writes legitimately, which is why this reports rather than" >&2
  echo "refuses. Read the list and ask of each whether THIS run was meant to write it." >&2
  return 0
}

compare() {
  local dir="$1" snapshot="$2"
  if [[ ! -f "${snapshot}" ]]; then
    echo "check-tree-untouched: no snapshot at ${snapshot}, so nothing was measured." >&2
    echo "The run's effect on the working tree is UNKNOWN, which is not the same as none." >&2
    return 1
  fi

  local after before
  after="$(tree_state "${dir}" "${snapshot}")"
  before="$(cat "${snapshot}")"
  if [[ "${after}" == "${before}" ]]; then
    return 0
  fi

  # Split by half before anything is judged. A difference in the ignored half must not reach the
  # tracked half's wording, which asserts things that are only true there ("a git add -A would commit
  # them" is false of a gitignored path), and must not move the verdict.
  local tracked_before tracked_after ignored_before ignored_after
  tracked_before="$(grep -v '^!!' <<< "${before}" || true)"
  tracked_after="$(grep -v '^!!' <<< "${after}" || true)"
  ignored_before="$(grep '^!!' <<< "${before}" || true)"
  ignored_after="$(grep '^!!' <<< "${after}" || true)"

  local verdict=0
  if [[ "${tracked_after}" != "${tracked_before}" ]]; then
    report_tracked "${tracked_before}" "${tracked_after}"
    verdict=1
  fi

  if [[ "${ignored_after}" != "${ignored_before}" ]]; then
    report_ignored "${ignored_before}" "${ignored_after}"
  fi

  return "${verdict}"
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
