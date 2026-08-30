#!/usr/bin/env bash

# #2946: rebuild the three GENERATED copy documents against the tree a merge actually produced, so a
# branch is not refused over a file nobody decided.
#
# WHY. `docs/copy-inventory.md`, `docs/outbound-copy.md` and `docs/copy-surfaces.md` are generated from
# the app's source and checked in, rebuilt against whatever `main` looked like when a branch last ran its
# suite. The instant any change adding a Dan-facing sentence merges, every other open branch holding those
# files is stale and its own suite goes red on `CopyInventoryTests.theCheckedInInventoryIsUpToDate`. The
# refusal is correct and is NOT weakened here. What it costs is that the rebuild carries no decision:
# neither side's text is anybody's to write. Measured 2026-08-18 across ten issues: three extra full suite
# runs, roughly fifteen minutes on a Mac that runs one at a time, plus two hand rebuilds.
#
# WHY THIS IS SAFE, which is the part to understand before changing it. It is #2812's argument for
# `project.pbxproj`, and it needs one extra step because there is no per-ref gate to lean on.
#
#   1. It can only ever record a rebuild OF A MERGE RESULT. It runs after the combine, in the verify
#      worktree, on a tree that exists nowhere else and is pushed nowhere.
#   2. A branch whose author changed the app's wording and did NOT regenerate could not have had a green
#      local run: `scripts/test-all.sh` is mandatory before a push and `CopyInventoryTests` is in it. So
#      the per-branch gate this leans on already exists, upstream, and is not being moved or softened.
#      The only staleness that can survive to here is staleness ANOTHER branch caused, which is exactly
#      what #2946 is about.
#   3. The freshness gate keeps its teeth afterwards: the full suite runs on the combined tree with these
#      documents already rebuilt, so a rebuild that somehow produced the wrong thing still goes red.
#
# What it deliberately does NOT do is cover the cold read. Reading the new sentences in the diff is the
# AUTHOR's step (AGENTS.md), on their own branch, where the change is theirs. This only settles the lines
# that moved because somebody else's sentence landed first.
#
# It is sourced, never executed.

# The three generated documents, held as a list so the commit below can REFUSE anything else rather than
# recording whatever it happens to find staged, on `commit_merge_regeneration`'s rule.
COPY_DOC_PATHS=("docs/copy-inventory.md" "docs/outbound-copy.md" "docs/copy-surfaces.md")

# The suites that generate them. Scoped rather than a whole run, because the full suite runs immediately
# afterwards anyway and would otherwise be paid for twice.
COPY_DOC_SUITES=(
  "-only-testing:OvertureTests/CopyInventoryTests"
  "-only-testing:OvertureTests/OutboundCopyTests"
  "-only-testing:OvertureTests/CopySurfacesTests"
)

# rebuild_copy_docs <dir>: regenerates the three documents in <dir> and commits them if they moved.
#
# 0 = nothing to do, or rebuilt and committed. 1 = refused, having said why.
#
# The scoped run's EXIT STATUS is deliberately not the verdict, and that is not laziness. Those suites
# FAIL by design when they regenerate: #1994 made a stale run name the sentences that moved rather than
# quietly rewriting the repo, and the regeneration flag does not change that. So a red run here is the
# ordinary case. What is read instead is whether the documents actually MOVED, which is the question
# being asked, and anything else the run was unhappy about is judged by the full suite that follows, on
# the same tree, seconds later. A build that failed outright therefore reaches a person as a failing
# suite rather than as silence (L98).
# #3258: scratch that honours TMPDIR, so a leak is visible to the checks that look there. Resolved from
# this file's own path rather than from a caller's variable, because this is a library and its callers
# do not all define one.
# shellcheck source=./scratch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch.sh"

rebuild_copy_docs() {
  local dir="$1"
  local log
  log="$(overture_scratch_file copy-docs-rebuild)"

  TEST_RUNNER_REGENERATE_COPY_INVENTORY=1 \
    "${dir}/mac/scripts/run-tests-locked.sh" "${COPY_DOC_SUITES[@]}" > "${log}" 2>&1 || true

  local changed
  changed="$(git -C "${dir}" status --porcelain -- "${COPY_DOC_PATHS[@]}")"
  if [[ -z "${changed}" ]]; then
    echo "Copy documents already match the combined tree; nothing rebuilt."
    rm -f "${log}"
    return 0
  fi

  # Anything ELSE the run left MODIFIED means something other than the generators wrote to this worktree,
  # and a blind commit would record it while looking exactly like a correct one.
  #
  # TRACKED changes only (`--untracked-files=no`), which is deliberate rather than lax. Only the three
  # paths below are ever staged, so an untracked stray cannot be swept into the commit whatever this
  # says; treating one as a refusal would instead block a merge over a log file a test run happened to
  # drop, which is a gate that fires on the ordinary case (L93). A tracked file that MOVED is the thing
  # worth stopping for, and that is what this asks.
  local other exclude=()
  local owned
  for owned in "${COPY_DOC_PATHS[@]}"; do exclude+=(":(exclude)${owned}"); done
  other="$(git -C "${dir}" status --porcelain --untracked-files=no -- . "${exclude[@]}")"
  if [[ -n "${other}" ]]; then
    echo "The copy rebuild left files it does not own modified in the verify worktree:" >&2
    printf '%s\n' "${other}" >&2
    echo "  It owns only: ${COPY_DOC_PATHS[*]}" >&2
    echo "  Refusing to commit. Nothing was merged." >&2
    echo "  The rebuild's log is at ${log}." >&2
    return 1
  fi

  echo "Rebuilt the copy documents against the combined tree:"
  git -C "${dir}" --no-pager diff --stat -- "${COPY_DOC_PATHS[@]}" | sed 's/^/  /'
  git -C "${dir}" add -- "${COPY_DOC_PATHS[@]}"
  git -C "${dir}" -c user.name="Overture verify" -c user.email="verify@localhost" \
    commit -q -m "Rebuild the generated copy documents for the combined tree (verify worktree only)"
  rm -f "${log}"
  return 0
}
