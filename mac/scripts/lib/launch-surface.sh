#!/usr/bin/env bash
# #1120: the arguments that surface the resident Overture window on `overture` (build-install.sh --launch).
#
# The window is surfaced by the app's overture://show deep link (RootView.onOpenURL, #282). The hazard is
# HOW the URL is delivered. A bare `open overture://show` hands the scheme to LaunchServices, which routes
# it to whichever registered com.danwright.overture bundle it picks; a stray Release copy (say a build that
# died after producing the bundle but before install-dedupe removed it, #1119) could catch the launch and
# spawn a second instance the store's single-writer lock then refuses ("Overture's data is unavailable").
#
# `open -a <installed-app>` PINS the delivery to the installed bundle by path, so the scheme can never be
# routed to a stray copy: the URL is delivered to the exact /Applications bundle the login agent runs, and
# to its already-running instance when present (never a duplicate). It is impossible-by-construction rather
# than relying on the one known stray source having been cleaned up.
#
# Emits one argument per line so a caller reads them into an array without word-splitting a spaced path.
overture_launch_open_args() {
  local installed_app="$1"
  printf '%s\n' "-a" "${installed_app}" "overture://show"
}
