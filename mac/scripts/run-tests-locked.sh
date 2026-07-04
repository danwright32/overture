#!/usr/bin/env bash
set -euo pipefail

# Runs the Mac app's tests under an exclusive flock, so a CI run on the self-hosted
# runner and a local or Claude session run never execute xcodebuild at the same time on
# this Mac (overlapping xcodebuild test runs otherwise produce a false TEST FAILED from a
# daemon timeout, not a real regression). Part of #478 (milestone 12), Phase 3 (#505).
#
# The lock file lives outside any repo checkout, at one fixed path: the CI job's checkout
# is wiped before every job, while a human or Claude session runs from the real checkout
# at a different absolute path, so only a fixed shared path makes the two actually
# contend for the same lock instead of each locking a separate file. Exits with
# xcodebuild's own exit code, so a caller sees a real pass or fail, not this wrapper
# always succeeding.

LOCK_FILE="/tmp/overture-mac-tests.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

command -v flock >/dev/null || { echo "flock not found; install it with: brew install flock" >&2; exit 1; }

cd "${MAC_DIR}"
exec flock "${LOCK_FILE}" xcodebuild -scheme Overture -destination 'platform=macOS' test
