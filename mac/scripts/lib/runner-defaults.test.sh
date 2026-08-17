#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary (#2501).
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# Coverage for runner-defaults.sh (#2838): the install-time half of "the runner paths derive from one
# root". The app's half is RunnerScriptsTests.swift.
#
# `defaults` is STUBBED, on PATH ahead of the real one, so nothing here writes to a real preferences
# domain (L2). What each case asserts is what the function would have written.

FAILURES=0
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../../.." && pwd)"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/runner-defaults-2838.XXXXXX")" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/defaults" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${WORK}/defaults-written"
STUB
chmod +x "${WORK}/bin/defaults"
export PATH="${WORK}/bin:${PATH}"

# shellcheck source=./runner-defaults.sh
source "${LIB_DIR}/runner-defaults.sh"

# A checkout that has the three scripts, at a path holding a SPACE, because the one this repo lives in
# does and that is the whole reason the issue exists.
FAKE_REPO="${WORK}/Photography Assets/Overture"
mkdir -p "${FAKE_REPO}/mac/scripts"
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  printf '#!/bin/sh\n' > "${FAKE_REPO}/mac/scripts/${script}"
done

: > "${WORK}/defaults-written"
OUTPUT="$(write_runner_defaults "com.example.overture.test" "${FAKE_REPO}" 2>&1)"
WRITTEN="$(cat "${WORK}/defaults-written")"

assert_contains "the prep runner is pointed at this checkout" "${WRITTEN}" \
  "com.example.overture.test prepRunnerScriptPath ${FAKE_REPO}/mac/scripts/prep-run.sh"
assert_contains "so is the reply-classify runner" "${WRITTEN}" \
  "com.example.overture.test replyClassifyRunnerScriptPath ${FAKE_REPO}/mac/scripts/reply-classify-run.sh"
assert_contains "and the scout-extract runner" "${WRITTEN}" \
  "com.example.overture.test scoutExtractRunnerScriptPath ${FAKE_REPO}/mac/scripts/scout-extract-run.sh"
assert_eq "exactly three keys are written, so nothing else is touched" \
  "3" "$(grep -c . <<< "${WRITTEN}")"
assert_contains "and it says which checkout it pointed at" "${OUTPUT}" "${FAKE_REPO}"

# It writes into the domain it is GIVEN. Debug and Release are different preferences domains, and the
# whole reason the Debug keys had to be set separately is that one command cannot configure both.
: > "${WORK}/defaults-written"
write_runner_defaults "com.example.overture.debug" "${FAKE_REPO}" >/dev/null 2>&1
assert_contains "the Debug domain gets its own entries" "$(cat "${WORK}/defaults-written")" \
  "com.example.overture.debug prepRunnerScriptPath"
assert_not_contains "and the Release one is not touched by that call" \
  "$(cat "${WORK}/defaults-written")" "com.example.overture "

# A path to a script that is not there is REFUSED rather than recorded. Storing one is exactly the state
# this change exists to stop producing, so writing it here would be the defect wearing the fix's clothes.
: > "${WORK}/defaults-written"
rm "${FAKE_REPO}/mac/scripts/reply-classify-run.sh"
MISSING_OUTPUT="$(write_runner_defaults "com.example.overture.test" "${FAKE_REPO}" 2>&1)"
MISSING_WRITTEN="$(cat "${WORK}/defaults-written")"
assert_not_contains "a missing script is not recorded" "${MISSING_WRITTEN}" "replyClassifyRunnerScriptPath"
assert_contains "and it says which one it could not point at" "${MISSING_OUTPUT}" "reply-classify-run.sh"
assert_contains "the two that ARE there are still written" "${MISSING_WRITTEN}" "prepRunnerScriptPath"
printf '#!/bin/sh\n' > "${FAKE_REPO}/mac/scripts/reply-classify-run.sh"

# Neither argument may be guessed at: a domain or a root this cannot know is a refusal, never a write
# against some default.
: > "${WORK}/defaults-written"
write_runner_defaults "" "${FAKE_REPO}" >/dev/null 2>&1
assert_eq "an empty bundle id is refused" "1" "$?"
write_runner_defaults "com.example.overture.test" "" >/dev/null 2>&1
assert_eq "an empty repo root is refused" "1" "$?"
assert_empty "and neither wrote anything" "$(cat "${WORK}/defaults-written")"

# --- the registry cannot drift from the app's own (L96) ---
#
# The key-to-script pairs above are the APP's: RunnerScripts.Runner owns both halves. A hand-written
# copy only ever configures what somebody remembered, and a runner added there and forgotten here is
# invisible, because the feature simply never runs. So the two lists are compared rather than trusted.
SWIFT_SOURCE="$(cat "${REPO_ROOT}/mac/Overture/Domain/RunnerScripts.swift")"
LIB_SOURCE="$(cat "${LIB_DIR}/runner-defaults.sh")"

SWIFT_KEYS="$(grep -oE 'return "[a-zA-Z]+RunnerScriptPath"' <<< "${SWIFT_SOURCE}" | sed 's/return "//; s/"//' | sort)"
LIB_KEYS="$(grep -oE '^[a-zA-Z]+RunnerScriptPath' <<< "${LIB_SOURCE}" | sort)"
assert_eq "every defaults key the app reads is one this writes" "${SWIFT_KEYS}" "${LIB_KEYS}"

SWIFT_SCRIPTS="$(grep -oE 'return "[a-z-]+\.sh"' <<< "${SWIFT_SOURCE}" | sed 's/return "//; s/"//' | sort)"
LIB_SCRIPTS="$(grep -oE '[a-z-]+-run\.sh' <<< "${LIB_SOURCE}" | sort -u)"
assert_eq "and every script name it names is one the app looks for" "${SWIFT_SCRIPTS}" "${LIB_SCRIPTS}"

# The layout is the app's too. A `mac/scripts` here against something else there would put the paths in
# the right shape and the wrong place.
assert_contains "the app builds its paths as mac/scripts/<script>" "${SWIFT_SOURCE}" 'appendingPathComponent("mac")'
assert_contains "and so does this" "${LIB_SOURCE}" '/mac/scripts/'

# --- the two callers actually call it (a guard and its wiring are two claims) ---
assert_contains "build-install.sh points the Release domain at its own checkout" \
  "$(cat "${REPO_ROOT}/mac/build-install.sh")" 'write_runner_defaults "com.danwright.overture"'
assert_contains "run-debug.sh points the Debug domain at its own checkout" \
  "$(cat "${REPO_ROOT}/mac/scripts/run-debug.sh")" 'write_runner_defaults "${DEBUG_BUNDLE_ID}"'

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} runner-defaults.sh fixture(s) failed."
  exit 1
fi
echo "All runner-defaults.sh fixtures passed."
