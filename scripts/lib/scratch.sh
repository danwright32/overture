#!/bin/sh
# shellcheck shell=sh
#
# Where a script's scratch goes (#3258).
#
# WHY THIS EXISTS. On macOS `mktemp -d` and `mktemp -t NAME` IGNORE `TMPDIR` unless the path is spelled
# out in the template. #3249 measured that and converted the 81 fixtures, so their scratch lands where
# `scripts/run-shell-fixtures.sh`'s leak check can see it. The PRODUCTION scripts were not converted:
# they still wrote to the shared per-user temp folder, which macOS clears only at boot, and which no
# check in this repository can see into.
#
# WHAT THE MEASUREMENT ACTUALLY SAID, because it changes what this is for. Measured 2026-08-30 on this
# Mac after 16 days of uptime, the shared folder held 52,515 entries and ZERO of them matched any shape
# these scripts make: they clean up after themselves. So this is not reclaiming disk, and saying it were
# would be a claim nobody checked. It is about VISIBILITY: a script that writes where nothing can look
# leaks silently the day its cleanup stops working, and #3065 measured that exact habit on the Swift
# side at roughly 52 directories per suite run before anybody noticed.
#
# POSIX sh, because `mac/scripts/**` is under `scripts/check-runner-posix.sh` and sources this.

# A scratch DIRECTORY that honours TMPDIR. The template is spelled out on purpose: that is the whole
# mechanism, and a bare `mktemp -d` here would silently do the thing this file exists to stop.
overture_scratch_dir() {
  mktemp -d "${TMPDIR:-/tmp}/${1:-overture}.XXXXXX"
}

# A scratch FILE that honours TMPDIR, same rule.
overture_scratch_file() {
  mktemp "${TMPDIR:-/tmp}/${1:-overture}.XXXXXX"
}
