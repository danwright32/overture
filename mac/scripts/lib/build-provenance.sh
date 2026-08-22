#!/bin/sh
# shellcheck shell=sh
#
# #2553: did the build being installed come from main, or from an unmerged branch?
#
# The freshness panel compared the installed bundle's commit DATE against the newest shipped commit's
# date. A build made from a branch AFTER the latest commit on main is newer than everything on main, so
# it reported "up to date" in exactly the words a correct install uses. Hit 2026-08-11: the app in
# /Applications had been replaced at 21:22 while several agents were running, and there was no way from
# the repo to tell whether it came from main or from somebody's branch. It turned out to be Dan pressing
# Update, confirmed by ASKING him, which is not a check.
#
# It is worth a check because the live app holds the real store. An unmerged build running against it is
# the one state nobody would notice, since the panel actively says everything is current.
#
# The installer is the only place that can answer this: it runs git, and the app deliberately cannot.
#
# In its own file, with its own fixture, because `mac/build-install.sh` has none and a rule written
# inline there could only ever be proved by doing a real install.

# build_provenance <repo-root>
#
# Prints exactly one of `main`, `branch` or `unknown`. Never fails, so a caller under `set -e` cannot be
# stopped by it: a build that cannot be classified must still install.
#
# `unknown` is a real answer and not a failure. It covers a checkout with no origin, a remote that cannot
# be reached, and anything that is not a repository, and each of those must never be reported as
# `branch`: an accusation made from an index that is merely incomplete would tell Dan his ordinary
# install came from an unmerged branch, and re-installing would not clear it (L119).
#
# Judged on ANCESTRY, never on the branch name. Work that has shipped is shipped whatever ref happens to
# be checked out, and a name-based rule would put a warning in front of Dan on every ordinary install
# made from a checkout standing on an already merged branch, which this repo's own tidy script says is
# the common leftover state.
build_provenance() {
  _bp_repo="${1:-}"
  [ -n "${_bp_repo}" ] || { echo unknown; return 0; }

  # The LOCAL ref is asked first, and answering `main` from it needs no network at all.
  #
  # That is sound in one direction only, which is the whole reason for the order: a stale `origin/main`
  # can only ever be MISSING commits, so a yes from it is still a true yes (the commit really is on
  # main), while a no from it may be nothing but staleness. So the cheap answer is taken when it is
  # affirmative, and the network is reached for only when this is about to ACCUSE.
  #
  # It also means an ordinary install on a machine that is offline, or one whose remote has moved, still
  # gets a real answer rather than `unknown`, which is the common case here: Dan presses Update, which
  # has already brought the checkout to origin/main.
  if git -C "${_bp_repo}" merge-base --is-ancestor HEAD origin/main >/dev/null 2>&1; then
    echo main
    return 0
  fi

  # Not an ancestor of what is known locally. Before saying so, refresh, for L119's reason: a checkout
  # that has not fetched since the merge would otherwise report a commit that HAS shipped as a branch
  # build, and re-installing would not clear it.
  #
  # The stall caps are there because this runs in the middle of an install: a fetch that hangs would
  # hang the install, and this answer is never worth that. A fetch that fails for any reason at all
  # (offline, no remote, no such repo, capped out) is an answer of `unknown`, never an accusation.
  if ! GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 \
       git -C "${_bp_repo}" fetch --quiet origin main >/dev/null 2>&1; then
    echo unknown
    return 0
  fi

  # Three outcomes, not two. `--is-ancestor` exits 0 for yes and 1 for no, and anything else is git
  # failing to answer at all (a missing ref, a corrupt object), which is not a no.
  git -C "${_bp_repo}" merge-base --is-ancestor HEAD origin/main >/dev/null 2>&1
  case "$?" in
    0) echo main ;;
    1) echo branch ;;
    *) echo unknown ;;
  esac
  return 0
}
