#!/usr/bin/env bash
set -uo pipefail

# Coverage for check-release-compiles.sh's four outcomes, driven through STUBBED xcodebuild and flock so
# no case takes the real build lock or spends a real build. Each stub sits in a PATH built for the case,
# and the missing-tool case builds its PATH from named tools only, because /usr/bin/xcodebuild is on
# every Mac and a PATH that merely lists a stub first would never exercise the refusal (L143).
#
# The real-build proof lives in the PR that added the check: it failed on main at feae6f60 naming
# SourcesView.swift:202 and :238, and passed once those calls were guarded.

# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-release-compiles.sh"
FAILURES=0
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# A PATH holding only the named tools, linked from wherever this machine keeps them.
make_path() {
  local dir="$1" tool
  shift
  mkdir -p "${dir}"
  for tool in "$@"; do
    ln -sf "$(command -v "${tool}")" "${dir}/${tool}"
  done
}

# The flock stub drops the lock path and runs the rest, recording that it was asked for the lock.
# The xcodebuild stub records its arguments, leaves a built product behind (so the removal is
# observable), and ends the way STUB_MODE says.
make_stubs() {
  local dir="$1"
  cat > "${dir}/flock" <<'EOF'
#!/usr/bin/env bash
echo "$1" > "${STUB_RECORD}.lock"
shift
exec "$@"
EOF
  cat > "${dir}/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "${STUB_RECORD}.args"
[[ -d "${STUB_DIR_LOCK}" ]] && echo held > "${STUB_RECORD}.dirlock"
dd=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-derivedDataPath" ]] && dd="$2"
  shift
done
mkdir -p "${dd}/Build/Products/Release/Overture.app"
case "${STUB_MODE}" in
  pass)
    echo "** BUILD SUCCEEDED **"
    exit 0 ;;
  compile-error)
    for arch in arm64 arm64-summary; do
      echo "/repo/mac/Overture/UI/SourcesView.swift:202:13: error: cannot find 'QueueRenderCounter' in scope"
    done
    echo "** BUILD FAILED **"
    exit 65 ;;
  other-failure)
    echo "xcodebuild: error: Could not resolve package dependencies"
    exit 74 ;;
esac
EOF
  cat > "${dir}/lsregister" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_RECORD}.lsregister"
EOF
  chmod +x "${dir}/flock" "${dir}/xcodebuild" "${dir}/lsregister"
}

BASE_TOOLS=(bash dirname rm mktemp grep sort tail mkdir cat date mv sleep)

run_case() {
  local mode="$1" bin="${WORK}/${1}-bin"
  make_path "${bin}" "${BASE_TOOLS[@]}"
  make_stubs "${bin}"
  STUB_MODE="${mode}" STUB_RECORD="${WORK}/${mode}" PATH="${bin}" \
    STUB_DIR_LOCK="${WORK}/${mode}-dirlock" OVERTURE_DIR_LOCK="${WORK}/${mode}-dirlock" \
    LSREGISTER="${bin}/lsregister" \
    OVERTURE_FILE_LOCK="${WORK}/the.lock" OVERTURE_RELEASE_CHECK_DERIVED_DATA="${WORK}/${mode}-dd" \
    bash "${SCRIPT}" 2>&1
}

# --- it compiled ---------------------------------------------------------------------------------------
out="$(run_case pass)"; status=$?
assert_eq "a clean Release build exits 0" "0" "${status}"
assert_contains "and says so" "${out}" "Release compiles."
args="$(cat "${WORK}/pass.args")"
assert_contains "it builds the Release configuration, the one the installer builds" "${args}" "-configuration Release"
assert_contains "under a bundle identifier that is not the installed app's" "${args}" "PRODUCT_BUNDLE_IDENTIFIER=com.danwright.overture.releasecheck"
assert_contains "and a URL scheme that is not the installed app's" "${args}" "OVERTURE_URL_SCHEME=overture-releasecheck"
assert_eq "it waits on the same lock as the Mac suite" "${WORK}/the.lock" "$(cat "${WORK}/pass.lock")"
assert_eq "it also holds Downbeat's cross-app lock while it builds, as the Mac suite does" \
  "held" "$(cat "${WORK}/pass.dirlock" 2>/dev/null)"
if [[ -e "${WORK}/pass-dirlock" ]]; then
  fail "and releases that lock when it is done"
else
  pass "and releases that lock when it is done"
fi
assert_contains "the throwaway app is unregistered from macOS before it is deleted, so no stale registration is left" \
  "$(cat "${WORK}/pass.lsregister" 2>/dev/null)" "-u ${WORK}/pass-dd/Build/Products/Release/Overture.app"
if [[ -d "${WORK}/pass-dd/Build/Products" ]]; then
  fail "the built app is removed after a pass, so no stray Release-configuration bundle is left to register"
else
  pass "the built app is removed after a pass, so no stray Release-configuration bundle is left to register"
fi

# --- it did not compile: the compiler's own errors, each once --------------------------------------
out="$(run_case compile-error)"; status=$?
assert_eq "a compile error exits 1" "1" "${status}"
assert_contains "and names the file and line" "${out}" "SourcesView.swift:202:13: error: cannot find 'QueueRenderCounter' in scope"
count="$(grep -c "QueueRenderCounter' in scope" <<< "${out}")"
assert_eq "an error xcodebuild repeats is shown once" "1" "${count}"
assert_contains "and says what the usual cause is" "${out}" "#if DEBUG"
assert_contains "it is unregistered after a failure too" \
  "$(cat "${WORK}/compile-error.lsregister" 2>/dev/null)" "-u ${WORK}/compile-error-dd/Build/Products/Release/Overture.app"
if [[ -e "${WORK}/compile-error-dirlock" ]]; then
  fail "Downbeat's lock is released after a failure too"
else
  pass "Downbeat's lock is released after a failure too"
fi
if [[ -d "${WORK}/compile-error-dd/Build/Products" ]]; then
  fail "the built product is removed after a failure too"
else
  pass "the built product is removed after a failure too"
fi

# --- it failed with no compiler error: the log tail, not an empty message ---------------------------
out="$(run_case other-failure)"; status=$?
assert_eq "a failure that is not a compile error still exits 1" "1" "${status}"
assert_contains "and shows what xcodebuild said instead" "${out}" "Could not resolve package dependencies"

# --- it waits its turn behind an earlier queued run (downbeat#524) ----------------------------------------
# This check takes the machine wide lock through the Mac suite's own take_dir_lock, so it queues in
# arrival order too. A live waiter that arrived earlier holds the turn even with the lock FREE, and this
# PATH is the named tools list, which is what the queue must still work under.
bin="${WORK}/queued-bin"
make_path "${bin}" "${BASE_TOOLS[@]}"
make_stubs "${bin}"
sleep 120 & earlier=$!
mkdir -p "${WORK}/queued-dirlock.queue"
printf '%s %s\n' "${earlier}" "$(/bin/ps -o lstart= -p "${earlier}" | sed 's/^ *//; s/ *$//')" \
  > "${WORK}/queued-dirlock.queue/00000000001.000000.${earlier}"
out="$(STUB_MODE=pass STUB_RECORD="${WORK}/queued" PATH="${bin}" \
  STUB_DIR_LOCK="${WORK}/queued-dirlock" OVERTURE_DIR_LOCK="${WORK}/queued-dirlock" \
  OVERTURE_DIR_LOCK_TIMEOUT=2 OVERTURE_DIR_LOCK_POLL=1 LSREGISTER="${bin}/lsregister" \
  OVERTURE_FILE_LOCK="${WORK}/the.lock" OVERTURE_RELEASE_CHECK_DERIVED_DATA="${WORK}/queued-dd" \
  bash "${SCRIPT}" 2>&1)"; status=$?
assert_eq "behind an earlier queued run it gives up rather than taking a free lock" "3" "${status}"
assert_contains "and says it was queued" "${out}" "queued behind 1 earlier run(s)"
if [[ -e "${WORK}/queued.args" ]]; then
  fail "and it never built" "xcodebuild ran: $(cat "${WORK}/queued.args")"
else
  pass "and it never built"
fi
assert_eq "and it left the queue on the way out, leaving only the earlier ticket" \
  "00000000001.000000.${earlier}" "$(ls "${WORK}/queued-dirlock.queue")"
kill "${earlier}" 2>/dev/null; wait "${earlier}" 2>/dev/null

# --- stopping it while it waits STOPS it (L473) ---------------------------------------------------------
# A trap on INT or TERM that only cleans up lets the script carry on round the wait loop, rejoining the
# queue at the back, and would let it build after releasing the lock. Its pid is read off its own ticket.
mkdir -p "${WORK}/stopped-dirlock"; echo "other:$$" > "${WORK}/stopped-dirlock/owner"
STUB_MODE=pass STUB_RECORD="${WORK}/stopped" PATH="${bin}" \
  STUB_DIR_LOCK="${WORK}/stopped-dirlock" OVERTURE_DIR_LOCK="${WORK}/stopped-dirlock" \
  OVERTURE_DIR_LOCK_TIMEOUT=30 OVERTURE_DIR_LOCK_POLL=1 LSREGISTER="${bin}/lsregister" \
  OVERTURE_FILE_LOCK="${WORK}/the.lock" OVERTURE_RELEASE_CHECK_DERIVED_DATA="${WORK}/stopped-dd" \
  bash "${SCRIPT}" > "${WORK}/stopped.out" 2>&1 &
stopped=$!
waited=0
while [[ -z "$(ls "${WORK}/stopped-dirlock.queue" 2>/dev/null)" ]] && [[ "${waited}" -lt 300 ]]; do
  sleep 0.05; waited=$((waited + 1))
done
assert_eq "it queued, so this case measured a stop while waiting" "${stopped}" \
  "$(ls "${WORK}/stopped-dirlock.queue" 2>/dev/null | sed 's/.*\.//')"
kill -TERM "${stopped}" 2>/dev/null
waited=0
while kill -0 "${stopped}" 2>/dev/null && [[ "${waited}" -lt 100 ]]; do sleep 0.05; waited=$((waited + 1)); done
assert_eq "a stopped check ends" "ended" "$(kill -0 "${stopped}" 2>/dev/null && echo still-running || echo ended)"
kill -KILL "${stopped}" 2>/dev/null; wait "${stopped}" 2>/dev/null; status=$?
assert_eq "with TERM's status" "143" "${status}"
assert_eq "and leaves the queue" "" "$(ls "${WORK}/stopped-dirlock.queue" 2>/dev/null)"
assert_eq "and leaves the holder's lock alone" "other:$$" "$(cat "${WORK}/stopped-dirlock/owner" 2>/dev/null)"
if [[ -e "${WORK}/stopped.args" ]]; then fail "and never built"; else pass "and never built"; fi

# --- nothing measured ---------------------------------------------------------------------------------
bin="${WORK}/no-xcodebuild-bin"
make_path "${bin}" "${BASE_TOOLS[@]}"
make_stubs "${bin}"
rm -f "${bin}/xcodebuild"
out="$(PATH="${bin}" STUB_MODE=pass STUB_RECORD="${WORK}/none" bash "${SCRIPT}" 2>&1)"; status=$?
assert_eq "no xcodebuild is UNMEASURED (exit 2), never a pass" "2" "${status}"
assert_contains "and names what was missing" "${out}" "xcodebuild is not on PATH"

# --- wired into scripts/test-all.sh, after the suite, and able to fail the run -------------------------
# Read with comments stripped, so prose ABOUT the check cannot answer for a call to it (L103).
TEST_ALL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/test-all.sh"
code="$(sed -e 's/^[[:space:]]*#.*$//' "${TEST_ALL}")"
suite_line="$(grep -n 'stream_and_wait "' <<< "${code}" | head -1 | cut -d: -f1)"
call_line="$(grep -n 'if ! "${REPO_ROOT}/mac/scripts/check-release-compiles.sh"' <<< "${code}" | head -1 | cut -d: -f1)"
if [[ -n "${call_line}" && -n "${suite_line}" && "${call_line}" -gt "${suite_line}" ]]; then
  pass "test-all.sh runs the check once the Mac suite has released the build lock"
else
  fail "test-all.sh runs the check once the Mac suite has released the build lock" \
    "call at line '${call_line}', suite wait at line '${suite_line}'"
fi
failure_line="$(sed -n "$((call_line + 1))p" <<< "${code}")"
assert_contains "and a red check fails the run" "${failure_line}" \
  'TEST_ALL_CHEAP_FAILURES+=("mac/scripts/check-release-compiles.sh")'

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All check-release-compiles.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} check-release-compiles.sh fixture(s) failed."
  exit 1
fi
