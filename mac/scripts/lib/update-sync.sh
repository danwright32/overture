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
# is identical. The question is "can MAIN fast-forward, and may I move the checkout onto it".

# overture_update_verdict DIRTY ON_MAIN HEAD_IS_UPSTREAM MAIN_CAN_FAST_FORWARD
#   Each argument is yes/no. Prints one of:
#     ready                    already on the shipped commit, just build
#     sync                     move to main and fast-forward it, then build
#     refuse:work-in-progress  somebody is working in here; touch nothing
#     refuse:diverged          local main holds commits the remote does not; needs a person
#
# Dirty is checked FIRST and beats everything, including a checkout that is otherwise ready: the safe
# answer must not depend on which of several true things gets checked first.
overture_update_verdict() {
  local dirty="${1:-no}" on_main="${2:-no}" head_is_upstream="${3:-no}" can_ff="${4:-no}"
  [ "${dirty}" = "yes" ] && { printf 'refuse:work-in-progress\n'; return 0; }
  [ "${on_main}" = "yes" ] && [ "${head_is_upstream}" = "yes" ] && { printf 'ready\n'; return 0; }
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
      printf '%s\n' "Overture did not update: there is unsaved work in progress in the code folder, and updating would disturb it. Ask Claude to finish or put aside that work, then press Update again."
      ;;
    refuse:diverged)
      printf '%s\n' "Overture did not update: the code folder holds work that never reached the shared copy, so it cannot be brought up to date on its own. Ask Claude to sort it out, then press Update again."
      ;;
    *) printf '\n' ;;
  esac
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
    printf '%s\n' "Overture did not update: it could not reach the shared copy of the code to see what has shipped. Check the network and press Update again." >&2
    return 1
  fi

  local dirty=no on_main=no head_is_upstream=no can_ff=no
  [ -n "$(git -C "${repo}" status --porcelain 2>/dev/null)" ] && dirty=yes
  [ "$(git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] && on_main=yes
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
    *)
      overture_update_reason "${verdict}" >&2
      return 1
      ;;
  esac

  # The move itself, and it must not be able to half-happen: if either step fails the checkout is left
  # where it is and the installer is told not to build, rather than building something nobody chose.
  if ! git -C "${repo}" checkout --quiet main 2>/dev/null; then
    printf '%s\n' "Overture did not update: it could not switch the code folder to the shared copy. Ask Claude to look." >&2
    return 1
  fi
  if ! git -C "${repo}" merge --ff-only --quiet origin/main 2>/dev/null; then
    printf '%s\n' "Overture did not update: it could not bring the code folder up to what has shipped. Ask Claude to look." >&2
    return 1
  fi
  return 0
}
