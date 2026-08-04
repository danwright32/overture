#!/usr/bin/env bash
set -euo pipefail

# What the panel's Update button runs (2026-08-04).
#
# Pressing Update means "get me the code that has shipped". Running mac/build-install.sh by hand means
# "build what is here". Those are different jobs and this is the difference: bring the checkout up to
# what has shipped, and only then hand over to the installer.
#
# It exists as its own script rather than a flag inside build-install.sh for a mechanical reason: bash
# reads a script as it runs it, so a script that switches its own checkout's branch partway through can
# have the rest of its own text change under it. Here the switching finishes before the installer is
# started at all, and the installer runs as a fresh process reading the updated file from the top.
#
# Why Dan needed it: he pressed Update, the app quit, the installer rebuilt the SAME commit the app was
# already running, the app came back, and the panel said "1m behind" again. The checkout was parked on a
# feature branch whose content had already been squash-merged, so nothing in the update path could ever
# resolve it.
#
# Wrapped in a function called on the last line, deliberately: bash has then read the whole file before
# any of it runs, so this script cannot change under its own feet either.

main() {
  local script_dir mac_dir repo_root installer
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mac_dir="$(cd "${script_dir}/.." && pwd)"

  # shellcheck source=scripts/lib/update-sync.sh
  source "${script_dir}/lib/update-sync.sh"

  # Overridable so the fixtures can drive this against a throwaway repository and a recording installer,
  # instead of Dan's checkout and a real 90-second build (L2).
  repo_root="${OVERTURE_REPO_ROOT:-$(cd "${mac_dir}/.." && pwd)}"
  installer="${OVERTURE_INSTALL_CMD:-${mac_dir}/build-install.sh}"

  echo "==> Bringing the code up to what has shipped"
  if ! overture_bring_checkout_current "${repo_root}"; then
    # The reason has already been printed by the line above. Not installing is the POINT: building a
    # checkout that could not be brought up to date is what made the update loop, because it reinstalled
    # the same commit and the panel went on being right about it.
    echo "Nothing was installed, so Overture is unchanged." >&2
    return 1
  fi

  echo "==> Installing"
  "${installer}" --launch
}

main "$@"
