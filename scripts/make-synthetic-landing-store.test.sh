#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #4338 (A10): the wrapper that writes a synthetic store. Its whole value is where it will NOT write: never the
# live Release folder, never the default Debug one, never over a store already there. And a run that wrote
# nothing must never read as a store written (L98). Driven through its runner seam with a fake writer and a
# stand in Application Support folder, never the real suite and never the real folders (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/make-synthetic-landing-store.sh"

FAILURES=0
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT
APPSUP="${WORK}/Application Support"
mkdir -p "${APPSUP}/Overture" "${APPSUP}/Overture-Debug" "${WORK}/scratch store"
CALLS="${WORK}/calls"

# A fake writer: records that it ran and where, writes a store and a report unless told not to, exits $2.
RUNNERS=0
make_runner() {
  local writes="$1" code="$2" runner
  RUNNERS=$((RUNNERS + 1))
  runner="${WORK}/runner-${RUNNERS}"
  cat > "${runner}" <<EOF
#!/usr/bin/env bash
echo "ran \$* into \${TEST_RUNNER_OVERTURE_SYNTHETIC_STORE_OUT}" >> "${CALLS}"
if [ "${writes}" = "yes" ]; then
  : > "\${TEST_RUNNER_OVERTURE_SYNTHETIC_STORE_OUT}/Overture.store"
  printf 'sources 39\nshows 1350\nlanding records 17\n' > "\${TEST_RUNNER_OVERTURE_SYNTHETIC_STORE_OUT}/synthetic-store-report.txt"
fi
exit ${code}
EOF
  chmod +x "${runner}"
  echo "${runner}"
}

run_script() {
  local runner="$1"; shift
  local out code
  out="$(OVERTURE_SYNTHETIC_STORE_RUNNER="${runner}" OVERTURE_SYNTHETIC_STORE_APP_SUPPORT="${APPSUP}" \
    "${SCRIPT}" "$@" 2>&1)"
  code=$?
  printf '%s\nexit=%s\n' "${out}" "${code}"
}

GOOD="$(make_runner yes 0)"

# The refusals, each before the writer is ever run.
: > "${CALLS}"
LIVE_RUN="$(run_script "${GOOD}" "${APPSUP}/Overture")"
assert_contains "REFUSES the live Release folder" "${LIVE_RUN}" "exit=1"
DEBUG_RUN="$(run_script "${GOOD}" "${APPSUP}/Overture-Debug")"
assert_contains "REFUSES the default Debug folder" "${DEBUG_RUN}" "exit=1"
ABOVE_RUN="$(run_script "${GOOD}" "${APPSUP}")"
assert_contains "refuses the folder holding both" "${ABOVE_RUN}" "exit=1"
assert_equals "and never runs the writer for any of them" "" "$(cat "${CALLS}")"

# A store written: the writer ran once, into the named folder, and the way to open it is printed.
SCRATCH_REAL="$(cd "${WORK}/scratch store" && pwd -P)"
GOOD_RUN="$(run_script "${GOOD}" "${WORK}/scratch store")"
assert_contains "a named scratch folder is written" "${GOOD_RUN}" "exit=0"
assert_contains "through the one opt-in writer, into that folder" "$(cat "${CALLS}")" \
  "ran -only-testing:OvertureTests/SyntheticLandingStoreWriter into ${SCRATCH_REAL}"
assert_contains "with what it wrote" "${GOOD_RUN}" "shows 1350"
assert_contains "and how to open it" "${GOOD_RUN}" "mac/scripts/run-debug.sh --store-folder \"${SCRATCH_REAL}\""

# Never over a store already there.
: > "${CALLS}"
AGAIN_RUN="$(run_script "${GOOD}" "${WORK}/scratch store")"
assert_contains "a folder already holding a store is refused" "${AGAIN_RUN}" "already holds a store"
assert_contains "and exits 1" "${AGAIN_RUN}" "exit=1"
assert_equals "without running the writer" "" "$(cat "${CALLS}")"

# A writer that failed, or passed and wrote nothing, is unmeasured, never a store written.
mkdir -p "${WORK}/second" "${WORK}/third"
FAILED_RUN="$(run_script "$(make_runner no 65)" "${WORK}/second")"
assert_contains "a failed writer is unmeasured" "${FAILED_RUN}" "UNMEASURED: the writer run failed"
assert_contains "and exits 2" "${FAILED_RUN}" "exit=2"
SILENT_RUN="$(run_script "$(make_runner no 0)" "${WORK}/third")"
assert_contains "a green run that wrote no store is unmeasured too" "${SILENT_RUN}" "wrote no store"
assert_contains "and exits 2" "${SILENT_RUN}" "exit=2"

USAGE_RUN="$(run_script "${GOOD}")"
assert_contains "no folder is a usage error" "${USAGE_RUN}" "exit=64"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All make-synthetic-landing-store.sh fixtures passed."
