# Shared by every scripts/*.sh that talks to this repo's GitHub API. Source it rather than
# hardcoding the repo or account separately, so the two copies can never drift out of sync.

REPO="danwright32/overture"
GH_IDENTITY="danwright32"

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
}
