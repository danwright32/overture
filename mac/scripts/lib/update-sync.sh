#!/usr/bin/env bash
# Bringing the checkout up to what has shipped, before the installer builds it.
#
# The Update button used to install whatever commit happened to be checked out, so it could not fix a
# copy that was behind BECAUSE the checkout was behind. Dan hit the loop on 2026-08-04: he pressed
# Update, the app quit, the installer rebuilt the same commit, the app came back, and the panel said
# "1m behind" again. The checkout was parked on a feature branch whose content had already been
# squash-merged, so it was a minute older than main while carrying identical code.
#
# "What has shipped" is always origin/main (record-shipped-commit.sh reads the remote deliberately) and
# "what is installed" is always the local HEAD, so any checkout not sitting on current main reads as
# behind forever.
#
# Note what the question is NOT. It cannot be "can this branch fast-forward to main", because a squash
# merge makes a new commit: the branch commit is not an ancestor of the main commit even when the code
# is identical.
#
# #2923 SETTLED WHAT IT IS, and narrowed it. This used to answer "move the checkout onto main" for a
# checkout standing anywhere else, and on 2026-08-17 it did exactly that to a working checkout in the
# middle of a session, off an in-progress feature branch. Nothing asked for it and nothing said it had
# happened. The cost is not the inconvenience: a full scripts/test-all.sh run made straight afterwards
# verified main while everyone believed it verified the branch, and that pass was written into a PR body
# as evidence for code it had never compiled (L98, L70). A `git push -u origin <branch>` then pushed
# main's HEAD at the feature branch's name, refused only by luck of the ref ordering.
#
# So the question is now "may MAIN fast-forward onto its own remote", and nothing else. The only move
# left is one that changes no branch, which is why no session can be redirected by it. A checkout
# standing anywhere else is REFUSED and told so, and putting it back on main is a person's decision
# (AGENTS.md already asks a session to leave the checkout on main when it finishes, which is the right
# place for that convention: the end of a session, not the middle of one).
#
# What that deliberately gives up is the automatic rescue of Dan's 2026-08-04 loop, a checkout parked on
# an already-squash-merged branch. It is given up because the two states cannot be told apart cheaply
# and honestly: a squashed branch's commits are not ancestors of main and not patch-equal to it either,
# so "already shipped" needs gh, and even a branch carrying nothing of its own is one a session may be
# standing in. The loop it leaves behind is loud rather than silent, which is the difference that
# mattered: a refusal naming the branch, in the Terminal and in the app's own panel.

# overture_update_verdict DIRTY ON_MAIN HEAD_IS_UPSTREAM MAIN_CAN_FAST_FORWARD
#   Each argument is yes/no. Prints one of:
#     ready                    already on the shipped commit, just build
#     sync                     fast-forward main onto its own remote, then build
#     refuse:work-in-progress  somebody is working in here; touch nothing
#     refuse:not-on-main       HEAD is on some other branch (or detached); moving it is not this
#                              script's to make (#2923)
#     refuse:diverged          local main holds commits the remote does not; needs a person
#
# Dirty is checked FIRST and beats everything, including a checkout that is otherwise ready: the safe
# answer must not depend on which of several true things gets checked first. not-on-main is checked
# before the fast-forward question for the same reason, and it is a DISTINCT refusal rather than a
# second use of one of the others, because it names a different state and a different remedy (L11).
overture_update_verdict() {
  local dirty="${1:-no}" on_main="${2:-no}" head_is_upstream="${3:-no}" can_ff="${4:-no}"
  [ "${dirty}" = "yes" ] && { printf 'refuse:work-in-progress\n'; return 0; }
  [ "${on_main}" = "yes" ] && [ "${head_is_upstream}" = "yes" ] && { printf 'ready\n'; return 0; }
  [ "${on_main}" = "yes" ] || { printf 'refuse:not-on-main\n'; return 0; }
  [ "${can_ff}" = "yes" ] && { printf 'sync\n'; return 0; }
  printf 'refuse:diverged\n'
  return 0
}

# overture_update_reason VERDICT
#   The sentence for a refusal. Read in a Terminal window by somebody who does not work in terminals,
#   so it says what happened and what to do rather than naming a git concept.
overture_update_reason() {
  case "${1:-}" in
    refuse:work-in-progress)
      printf '%s\n' "There is unsaved work in progress in the code folder, and updating would disturb it. Ask Claude to finish or put aside that work, then press Update again."
      ;;
    refuse:not-on-main)
      printf '%s\n' "The code folder is standing on a piece of work in progress rather than on the shared copy, and moving it would redirect whatever is being worked on there. Ask Claude to put the code folder back on the shared copy, then press Update again."
      ;;
    refuse:diverged)
      printf '%s\n' "The code folder holds work that never reached the shared copy, so it cannot be brought up to date on its own. Ask Claude to sort it out, then press Update again."
      ;;
    *) printf '\n' ;;
  esac
}

# Set alongside every refusal, so the caller can hand the SAME sentence to the app (#2188) instead of
# composing a second copy that drifts from what the Terminal window printed.
OVERTURE_UPDATE_REASON=""

# overture_update_refuse REASON
#   Says it did not update, says why, and remembers the why.
#
# The two surfaces carry one sentence each rather than both carrying the whole thing. A Terminal window
# has no title, so it needs the standing line; the app's panel is headed "Overture could not update", so
# a reason that began "Overture did not update" would be the same fact twice on one screen, which is the
# restatement #843 exists for.
overture_update_refuse() {
  OVERTURE_UPDATE_REASON="${1:-}"
  printf 'Overture did not update.\n%s\n' "${OVERTURE_UPDATE_REASON}" >&2
}

# overture_bring_checkout_current REPO
#   Fetches, decides, and acts. Returns 0 when the checkout is standing on the shipped commit (whether
#   it had to move or was already there), and non-zero after printing a reason when it refused.
#
# Refusing is a real outcome, not a fallback: it leaves the checkout exactly as it found it, which is
# what makes it safe to run unattended while somebody may be working in the same folder.
overture_bring_checkout_current() {
  local repo="${1:-}"
  [ -n "${repo}" ] || return 1

  if ! git -C "${repo}" fetch --quiet origin main 2>/dev/null; then
    # Fail loud. A silent build on stale code is how the loop looked from the outside.
    overture_update_refuse "It could not reach the shared copy of the code to see what has shipped. Check the network and press Update again."
    return 1
  fi

  local dirty=no on_main=no head_is_upstream=no can_ff=no here
  [ -n "$(git -C "${repo}" status --porcelain 2>/dev/null)" ] && dirty=yes
  # Read once and kept, because the refusal below has to NAME it. A skipped move that leaves no trace
  # is the whole of #2923: the branch switch was found days later, from the reflog, and only because an
  # unrelated later step happened to fail.
  here="$(git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  [ "${here}" = "main" ] && on_main=yes
  [ "$(git -C "${repo}" rev-parse HEAD 2>/dev/null)" = "$(git -C "${repo}" rev-parse origin/main 2>/dev/null)" ] \
    && head_is_upstream=yes
  # Whether LOCAL main can fast-forward onto the remote, which is the only move that never loses a
  # commit. A local main that has never been created yet (a fresh clone standing elsewhere) counts as
  # fast-forwardable: there is nothing of its own to lose.
  if ! git -C "${repo}" rev-parse --verify --quiet main >/dev/null 2>&1; then
    can_ff=yes
  elif git -C "${repo}" merge-base --is-ancestor main origin/main 2>/dev/null; then
    can_ff=yes
  fi

  local verdict
  verdict="$(overture_update_verdict "${dirty}" "${on_main}" "${head_is_upstream}" "${can_ff}")"
  case "${verdict}" in
    ready) return 0 ;;
    sync) : ;;
    refuse:not-on-main)
      # Said in the Terminal in the terms whoever is working here needs, on top of the plain sentence
      # the app's panel gets: which branch was left alone, and that nothing about the checkout moved.
      # #2923's damage came entirely from a move nobody could see afterwards.
      # A detached HEAD gets said in words rather than as the literal "HEAD" git prints for it, which
      # would read as a branch of that name to anyone who does not work in git.
      local standing_on="${here}"
      if [ -z "${standing_on}" ] || [ "${standing_on}" = "HEAD" ]; then
        standing_on="a single commit with no branch"
      fi
      printf 'Nothing was moved: the code folder is on %s, not main.\n' "${standing_on}" >&2
      overture_update_refuse "$(overture_update_reason "${verdict}")"
      return 1
      ;;
    *)
      overture_update_refuse "$(overture_update_reason "${verdict}")"
      return 1
      ;;
  esac

  # The move itself, and note what it is NOT since #2923: HEAD is already on main by the time this runs,
  # so this fast-forwards one branch onto its own remote and never carries the checkout off anything.
  # It must not be able to half-happen: if it fails the checkout is left where it is and the installer
  # is told not to build, rather than building something nobody chose.
  if ! git -C "${repo}" merge --ff-only --quiet origin/main 2>/dev/null; then
    overture_update_refuse "It could not bring the code folder up to what has shipped. Ask Claude to look."
    return 1
  fi
  return 0
}
