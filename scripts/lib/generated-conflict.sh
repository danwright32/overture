#!/usr/bin/env bash

# Telling a collision GitHub's plain text merge reports apart from one a person has to resolve (#3210).
#
# GitHub computes a PR's `mergeable` flag with a plain text merge and cannot see this repo's
# `.gitattributes` merge driver, so a PR whose ONLY collisions are the generated files reports as
# CONFLICTING while this Mac merges it cleanly. Measured 2026-08-28 on PR #3196: GitHub said
# CONFLICTING, `git merge-tree` resolved both files through scripts/lib/merge-generated.sh and exited
# 0, and the branch had to be updated by hand and re-verified, a full extra suite cycle, to get GitHub
# to change its mind. It is not a rare shape: any two branches that touch the app's wording or its
# file list collide on exactly those files by construction, which is why the driver exists at all.
#
# WHY THIS ASKS GIT RATHER THAN COMPARING A PATH LIST, which is the part worth reading before changing
# it. A list of "paths the driver owns" is a second definition of what this repo can resolve, kept by
# hand beside the real one, and it would be wrong in the direction that matters: the driver is
# registered PER CLONE by scripts/install-git-hooks.sh, because `merge.<name>.driver` lives in the git
# config, which is not tracked. On a clone that skipped the installer the same collision really does
# conflict, and a path list would wave through a merge about to stop half way. Running the merge is
# the only thing that answers for the machine it is running on (L70), and it costs one in-memory
# merge with no worktree.
#
# It is a TRIAL, not the merge. Nothing here writes to a worktree or to any ref; `--write-tree` leaves
# an unreferenced tree object behind and git's ordinary gc reclaims it. The real combine still happens
# later in the verify worktree and still refuses on its own conflict, so a wrong RESOLVED here costs a
# refusal further along rather than a bad merge.

# Three outcomes, never two. A trial merge that could not RUN and one that ran and found nothing to
# resolve leave the same empty list of conflicted files, and reading the first as the second is the
# emptiest possible failure passing as the cleanest possible pass (L98, L11).
TRIAL_MERGE_RESOLVED=0
TRIAL_MERGE_CONFLICTS=1
TRIAL_MERGE_UNMEASURED=2

# trial_merge_conflicts <base-ref> <branch-ref> [repo-dir]
#
# Merges the two refs in memory, with this clone's own drivers, and answers with one of the three
# codes above. On TRIAL_MERGE_CONFLICTS it prints the still-conflicted paths on stdout, one per line,
# so a refusal can name them instead of leaving the reader to guess which collision was the real one.
# On TRIAL_MERGE_UNMEASURED it prints git's own words on stderr, because the reason it could not
# measure is the whole content of that outcome.
trial_merge_conflicts() {
  local base="$1" branch="$2" dir="${3:-.}"
  local out status paths

  out="$(git -C "${dir}" merge-tree --write-tree "${base}" "${branch}" 2>&1)"
  status=$?

  if [[ "${status}" -eq 0 ]]; then
    return "${TRIAL_MERGE_RESOLVED}"
  fi

  # A NONZERO STATUS IS NOT A CONFLICT ON ITS OWN, which is the trap here and was caught by this
  # helper's own fixture. Measured on git 2.51.1: `merge-tree --write-tree side-a no-such-branch`
  # exits 1, exactly as a genuinely conflicted merge does, having printed `not something we can
  # merge`. Read by status alone, a question git REFUSED comes back as a conflict with no files in
  # it, and the caller then refuses a mergeable PR while naming nothing (L98, L11).
  # What separates them is evidence rather than a code: a merge that really ran writes the OID of the
  # tree it produced, whatever it then found, and a refusal writes only its complaint. The OID is
  # looked for on any LINE rather than on the first one, because a merge driver that resolved a file
  # speaks before git prints it, which is precisely the case this whole helper exists for.
  if ! printf '%s\n' "${out}" | grep -qE '^[0-9a-f]{40}$'; then
    printf '%s\n' "${out}" >&2
    return "${TRIAL_MERGE_UNMEASURED}"
  fi

  # The "conflicted file info" block git prints after the tree OID: `<mode> <oid> <stage>\t<path>`,
  # one line per stage, so the same path arrives up to three times. Paths the driver resolved are
  # absent from it, which is exactly the distinction being drawn.
  paths="$(printf '%s\n' "${out}" \
    | grep -E "^[0-7]{6} [0-9a-f]+ [123]${TAB_CHARACTER}" \
    | cut -f2 \
    | sort -u)" || paths=""
  [[ -n "${paths}" ]] && printf '%s\n' "${paths}"
  return "${TRIAL_MERGE_CONFLICTS}"
}

# A literal tab, built rather than typed, so the grep pattern above cannot be silently reflowed into
# spaces by an editor or a copy through a terminal.
TAB_CHARACTER="$(printf '\t')"

# fetch_trial_merge_refs <branch> [repo-dir]: brings the two refs the trial merge needs up to date.
# Named and extracted so a fixture can drive the decision below without a real network round trip,
# and so a failed fetch is a refusal with its own reason rather than a trial merge over stale refs.
fetch_trial_merge_refs() {
  local branch="$1" dir="${2:-.}"
  git -C "${dir}" fetch --quiet origin main "${branch}"
}

# check_mergeable_locally <mergeable> <pr-number> <branch> [repo-dir]
#
# The mergeability question as the LOCAL merge paths have to ask it. It still REFUSES every
# CONFLICTING PR, and the reason is worth reading before anyone tries to make it carry on.
#
# GitHub will not merge a PR it reports as CONFLICTING, whatever this Mac can resolve, so carrying on
# would buy a full suite run and then fail at the merge, which is strictly worse than refusing in two
# seconds. The evidence is the incident #3210 was filed from: PR #3196's own commit list carries
# `Merge remote-tracking branch 'origin/main'` AND `Regenerate project.pbxproj after merging main`,
# both pushed to the branch, before GitHub would take it. Doing that automatically means pushing a
# regenerated generated file to somebody's branch, which is exactly the property #2812's reasoning
# leans on NOT being true today ("a tree that exists only inside the verify worktree and is pushed
# nowhere"), so it is a decision of its own rather than a detail of this one. It is filed separately.
#
# What this does instead is tell the reader which of the two situations they are in, in seconds, and
# name the remedy when it is the mechanical one. Three outcomes, three sentences, because a reader who
# cannot tell them apart is exactly where #3210 started (L11).
check_mergeable_locally() {
  local mergeable="$1" pr="$2" branch="$3" dir="${4:-.}"
  [[ "${mergeable}" == "CONFLICTING" ]] || return 0

  echo "Unmergeable: PR #${pr} reports as CONFLICTING against its base branch, so GitHub will not merge it." >&2

  if ! fetch_trial_merge_refs "${branch}" "${dir}"; then
    echo "Which KIND of collision it is could not be measured: fetching origin main and ${branch} failed," >&2
    echo "so nothing here has looked at the files. Rerun once the fetch works to find out." >&2
    return 1
  fi

  local conflicted status
  conflicted="$(trial_merge_conflicts "origin/main" "origin/${branch}" "${dir}")"
  status=$?

  if [[ "${status}" -eq "${TRIAL_MERGE_RESOLVED}" ]]; then
    echo "This is the cheap kind. GitHub computes that flag with a plain text merge and cannot see this" >&2
    echo "repo's .gitattributes merge driver, and a trial merge of origin/main into ${branch} here" >&2
    echo "resolved EVERY collision, so there is nothing for a person to read or decide. Any two branches" >&2
    echo "touching the app's wording or its file list collide this way by construction." >&2
    echo "Bring the branch up to main and push, and GitHub changes its mind:" >&2
    echo "  git checkout ${branch} && git merge origin/main" >&2
    echo "  scripts/test-all.sh   # regenerates and judges the generated files on the combined tree" >&2
    echo "  git push" >&2
    return 1
  fi

  if [[ "${status}" -eq "${TRIAL_MERGE_CONFLICTS}" ]]; then
    if [[ -n "${conflicted}" ]]; then
      echo "This is the real kind. These files collide and nothing here can resolve them:" >&2
      printf '  %s\n' ${conflicted} >&2
    else
      echo "This is the real kind: the trial merge conflicted, but named no file, which is worth reading" >&2
      echo "before assuming a cause. Run 'git merge-tree --write-tree origin/main origin/${branch}' to see it." >&2
    fi
    echo "Resolve it on the branch, push, then rerun." >&2
    return 1
  fi

  echo "Which KIND of collision it is could not be measured: git refused the trial merge rather than" >&2
  echo "answering it, and its own words are above. Nothing here has looked at the files." >&2
  return 1
}
