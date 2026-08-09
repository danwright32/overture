#!/usr/bin/env bash
# #2291: which branch a push is GOING TO, decided as a pure function so the pre-push hook has something a
# fixture can drive.
#
# On 2026-08-07 a whole issue's work landed directly on main, past the pull request flow this repo uses for
# everything. Both existing pre-push gates passed, because neither asks the question this one asks, and the
# only visible sign was "HEAD -> main" in the push output. Every other control here assumes work arrives by
# PR: the pbxproj freshness check inside both merge scripts, the CI gate, review itself. The one path that
# bypasses all of them was the one with no guard, and committing to a local main is perfectly legal, so
# nothing could warn until the push had already happened.

# Echo one line per pushed ref that targets the protected branch. Empty output means the push is fine.
#
# Reads git's pre-push stdin verbatim, which is one line per ref being pushed:
#
#     <local ref> <local sha> <remote ref> <remote sha>
#
# The REMOTE ref is what decides it, never the local one: `git push origin HEAD:main` from a feature branch
# and `git push` from a local main are the same event to the remote, and a local branch that happens to be
# called main going somewhere else is an ordinary push.
#
# A deletion arrives as an all-zero LOCAL sha on the same ref rather than as a different ref, so a guard
# keyed on the ref alone would wave through the most destructive push of all. It is reported in its own
# words, because "you are pushing to main" would not describe what is about to happen.
protected_push_violations() {
  local protected="$1"
  local zero="0000000000000000000000000000000000000000"
  local local_ref local_sha remote_ref remote_sha

  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${remote_ref:-}" ] || continue
    [ "${remote_ref}" = "refs/heads/${protected}" ] || continue

    if [ "${local_sha}" = "${zero}" ]; then
      echo "DELETING ${remote_ref} on the remote"
    else
      echo "${local_ref} -> ${remote_ref}"
    fi
  done
}
