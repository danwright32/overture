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
  # shellcheck source=scripts/lib/update-result.sh
  source "${script_dir}/lib/update-result.sh"

  # Before anything is decided (#2188). The app is watching for the outcome of the press that started
  # this run, and a run that dies where nothing can catch it has to be distinguishable from one that
  # never started at all: those are different problems and only one of them is worth waiting on.
  overture_update_record_running

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
    # And the app is told, in the words just printed, rather than being left to read a silence as
    # success (#2188). Dan does not work in a terminal, and this window is the only place the refusal
    # existed.
    overture_update_record_failed "${OVERTURE_UPDATE_REASON}"
    return 1
  fi

  echo "==> Installing"
  # The install is part of the update, so a build that fails is an update that failed. Left unguarded it
  # would leave the record saying "running" for good, and the app would sit waiting on a run that had
  # already died: exactly the silence this exists to end, one step further along.
  if ! "${installer}" --launch; then
    echo "Nothing was installed, so Overture is unchanged." >&2
    overture_update_record_failed "Overture did not update: the install did not finish. Ask Claude to look."
    return 1
  fi

  # Success clears the record rather than recording a success. There is nothing to say: the app is
  # being replaced and relaunched, and its new installed-build.json is the report.
  overture_update_clear_result
}

main "$@"
