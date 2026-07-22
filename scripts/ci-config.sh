# Shared by every scripts/*.sh that talks to this repo's GitHub API. Source it rather than
# hardcoding the repo or account separately, so the two copies can never drift out of sync.

REPO="danwright32/overture"
GH_IDENTITY="danwright32"

# The xcodegen version check-pbxproj-fresh.sh (#1368) treats as the source of truth for a fresh
# mac/Overture.xcodeproj/project.pbxproj. xcodegen output can differ byte-for-byte between versions while
# being equivalent, so the freshness gate refuses to judge staleness under a different version and says so
# with its own distinct "cannot verify" message. Bump this in the same commit as an intentional xcodegen
# upgrade (and regenerate the project), so a mismatch always means a machine to fix, never a silent drift.
XCODEGEN_PINNED_VERSION="2.45.3"

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
}
