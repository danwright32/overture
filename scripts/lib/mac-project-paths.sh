# Shared predicate for "does this set of changed paths touch anything that feeds xcodegen's generated
# mac/Overture.xcodeproj/project.pbxproj?". Any path under mac/ counts EXCEPT mac/scripts/ and mac/build/,
# which never affect the generated project (a new .swift under mac/Overture does, with no project.yml
# edit, since xcodegen globs the source tree). Sourced by both merge-when-green.sh (verify freshness
# before merging, #1368 Decision 2) and the post-merge hook (regenerate after a merge, #1251 Phase 3), so
# the rule lives in exactly one place. Pure over a newline-separated path list, so it is testable without
# git or gh.

paths_touch_mac_project() {
  local paths="$1"
  if grep -vE '^mac/(scripts|build)/' <<< "${paths}" | grep -qE '^mac/'; then
    echo "yes"
  fi
}
