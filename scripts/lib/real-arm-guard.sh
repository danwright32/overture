#!/usr/bin/env bash
# #4328: refuse any commit that carries a REAL-ARM file, on the push path and over history.
#
# WHAT A REAL-ARM FILE IS. The landing oracle's real arm (mac/OvertureTests/LandingOracle.swift) records what
# a scout landing leaves in a store built from Dan's real data, hashed field by field. It lives on this Mac,
# outside every checkout, and must never reach GitHub: this repository is PUBLIC (L222, L155). Every such
# file's FIRST LINE is exactly the marker `real_arm_marker` prints, and nothing else counts: the marker
# inside a line, in a comment, in a doc or in a fixture's source is never a match. So this file, the Swift
# side and the fixture all BUILD the marker from two halves, and none of them holds a line that IS it
# (L245, L673): the guard's own commit, and every later edit to the probe or the plan's docs, push cleanly.
#
# WHY HISTORY AND NOT THE TREE (L489). A file added in one commit and deleted in the next is gone from the
# tree and still readable in the pushed history forever. So the check walks EVERY commit being pushed and
# reads every file each one added or modified. `scripts/test-all.sh` keeps a tree scan by the same rule
# (`real_arm_tree_violations`) as a second layer, and CI scans every commit in a pull request's range
# (`scripts/real-arm-scan.sh`), because a local hook can be skipped with --no-verify.
#
# FAILS CLOSED (L42, L490). Unlike the push-target guard beside it, a question this cannot answer (a git
# call that fails, a commit it cannot read) is a refusal by name, never a pass: this protects people, not a
# workflow. The pre-push hook refuses by name when this file itself is missing.
#
# Sourced, never executed. Every function prints its findings on stdout and returns 0 when it measured, 2
# when it could not, with the reason on stderr.

real_arm_marker() {
  printf '%s%s\n' "OVERTURE-REAL-ARM" ": never commit"
}

# real_arm_blob_is_marked <blob sha>: 0 when the blob's first line is the marker, 1 when not, 2 when the
# blob cannot be read. Reads at most 64 bytes, so a large binary costs nothing, and a marker line followed
# by a carriage return (a file written with CRLF) still counts as the marker.
real_arm_blob_is_marked() {
  local blob="$1" first="" marker
  marker="$(real_arm_marker)"
  git cat-file -e "${blob}" 2>/dev/null || return 2
  # A command substitution rather than `read < <(...)`: bash 3.2 does not reap a process substitution per
  # call, and over a repository's worth of files the shell dies part way (status 133, #4389).
  first="$(git cat-file blob "${blob}" 2>/dev/null | head -c 64)" || true
  first="${first%%$'\n'*}"
  first="${first%$'\r'}"
  [ "${first}" = "${marker}" ]
}

# real_arm_commit_violations <commit>: one "<commit> <path>" line per file the commit ADDED, COPIED,
# RENAMED, MODIFIED or retyped whose first line is the marker. A merge is read against each parent.
real_arm_commit_violations() {
  local commit="$1" path blob
  local list=(git diff-tree -r -z -m --root --no-commit-id --name-only --diff-filter=ACMRT "${commit}")
  # Asked once for its STATUS, because a NUL separated listing cannot be held in a variable (bash drops the
  # NULs) and a process substitution's status is lost; then read again for the paths.
  if ! "${list[@]}" >/dev/null 2>&1; then
    echo "real-arm-guard: could not list the files commit ${commit} changes" >&2
    return 2
  fi
  while IFS= read -r -d '' path; do
    [ -n "${path}" ] || continue
    # `<commit>:<path>` names the entry; everything after the colon is the PATH, so no peel suffix can go
    # on it. A gitlink (a submodule entry) has no blob to read and cannot be a real-arm file.
    blob="$(git rev-parse --verify -q "${commit}:${path}" 2>/dev/null)" || {
      echo "real-arm-guard: could not resolve ${path} in commit ${commit}" >&2
      exit 2
    }
    [ "$(git cat-file -t "${blob}" 2>/dev/null)" = "blob" ] || continue
    real_arm_blob_is_marked "${blob}"
    case $? in
      0) echo "${commit} ${path}" ;;
      1) ;;
      # `exit`, not `return`: this loop is the left side of a pipeline, so it is its own subshell.
      *) echo "real-arm-guard: could not read ${path} in commit ${commit}" >&2; exit 2 ;;
    esac
  done < <("${list[@]}" 2>/dev/null) | sort -u
  return "${PIPESTATUS[0]}"
}

# real_arm_range_violations <rev-list arguments...>: every violation in every commit the arguments select.
# Selecting NO commit at all is refused rather than passed (L98): it is what a wrong range looks like.
real_arm_range_violations() {
  local commits commit status
  commits="$(git rev-list "$@" 2>/dev/null)"
  status=$?
  if [ "${status}" -ne 0 ]; then
    echo "real-arm-guard: git rev-list $* failed, so the commits could not be enumerated" >&2
    return 2
  fi
  if [ -z "${commits}" ]; then
    echo "real-arm-guard: git rev-list $* selected no commits, so nothing was checked" >&2
    return 2
  fi
  while IFS= read -r commit; do
    real_arm_commit_violations "${commit}" || return 2
  done <<< "${commits}"
  return 0
}

# real_arm_push_violations <remote name>: reads git's pre-push stdin (<local ref> <local sha> <remote ref>
# <remote sha>, one line per ref) and checks every commit each ref would add to the remote. A ref whose
# remote side is known locally is the range remote..local; a new branch, or a remote sha this clone has
# never seen, is every commit reachable from local and from no remote-tracking ref. A deletion carries no
# commits and is skipped.
real_arm_push_violations() {
  local remote="$1" zero="0000000000000000000000000000000000000000"
  local local_ref local_sha remote_ref remote_sha
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    [ "${local_sha}" = "${zero}" ] && continue
    if [ "${remote_sha}" != "${zero}" ] && git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
      if ! git cat-file -e "${local_sha}^{commit}" 2>/dev/null; then
        echo "real-arm-guard: ${local_ref} points at ${local_sha}, which this clone cannot read" >&2
        return 2
      fi
      # Nothing new (a no-op, or a rewind to an older commit) carries no commits to check, which is not
      # the same as a range that selected nothing by mistake.
      if [ -z "$(git rev-list -n 1 "${remote_sha}..${local_sha}" 2>/dev/null)" ]; then
        continue
      fi
      real_arm_range_violations "${remote_sha}..${local_sha}" || return 2
    else
      local new
      if ! new="$(git rev-list "${local_sha}" --not --remotes="${remote}" 2>/dev/null)"; then
        echo "real-arm-guard: could not enumerate the commits ${local_ref} would add to ${remote}" >&2
        return 2
      fi
      [ -n "${new}" ] || continue
      real_arm_range_violations "${local_sha}" --not --remotes="${remote}" || return 2
    fi
  done
  return 0
}

# real_arm_tree_violations <repo dir>: every tracked file, and every untracked one git is not ignoring,
# whose first line is the marker. The second layer, for scripts/test-all.sh: it sees a file before it is
# ever committed, and it cannot see history, which the push and CI layers can.
real_arm_tree_violations() {
  local repo="$1" path marker first
  local list=(git -C "${repo}" ls-files -z --cached --others --exclude-standard)
  marker="$(real_arm_marker)"
  if ! "${list[@]}" >/dev/null 2>&1; then
    echo "real-arm-guard: could not list the files in ${repo}" >&2
    return 2
  fi
  while IFS= read -r -d '' path; do
    [ -f "${repo}/${path}" ] || continue
    first=""
    first="$(head -c 64 "${repo}/${path}" 2>/dev/null)" || true
    first="${first%%$'\n'*}"
    first="${first%$'\r'}"
    [ "${first}" = "${marker}" ] && echo "${path}"
  done < <("${list[@]}" 2>/dev/null)
  return 0
}

# The words a refusal prints, in one place for the hook, the scan and the tree check.
real_arm_refusal_text() {
  echo "  A real-arm file holds Dan's real data, hashed, and its first line marks it: it must never be"
  echo "  pushed, even in a commit a later one deletes, because this repository is public and history"
  echo "  keeps every commit. Rewrite the branch so no commit adds it (for example git rebase -i, dropping"
  echo "  or editing the commit named above), keep the file outside every checkout, and push again."
}
