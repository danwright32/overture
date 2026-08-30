# Shared predicate for "does this set of changed paths touch anything that feeds xcodegen's generated
# mac/Overture.xcodeproj/project.pbxproj?". Any path under mac/ counts EXCEPT mac/scripts/ and mac/build/,
# which never affect the generated project (a new .swift under mac/Overture does, with no project.yml
# edit, since xcodegen globs the source tree). Sourced by both merge-when-green.sh (verify freshness
# before merging, #1368 Decision 2) and the post-merge hook (regenerate after a merge, #1251 Phase 3), so
# the rule lives in exactly one place. Pure over a newline-separated path list, so it is testable without
# git or gh.

paths_touch_mac_project() {
  local paths="$1"
  # #3275: the filtering is done first, into a variable, rather than piped into a `grep -q`. The
  # producer there is the first grep, and it takes SIGPIPE the moment the second one matches early,
  # which under `set -o pipefail` becomes the condition's answer: an early match reads as no match
  # (L183). A herestring closes it because a herestring has no producer to kill.
  local app_paths
  app_paths="$(grep -vE '^mac/(scripts|build)/' <<< "${paths}" || true)"
  if grep -qE '^mac/' <<< "${app_paths}"; then
    echo "yes"
  fi
}
