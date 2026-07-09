#!/usr/bin/env bash
set -uo pipefail

# Coverage for lib/runner-setup.sh, the shared setup boilerplate extracted from prep-run.sh and
# reply-classify-run.sh (#552): support-dir resolution, the early-guard structure (queue check,
# claude binary resolution), and log redirection. This file lands FIRST, failing, before
# runner-setup.sh exists, per TDD.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# --- SUPPORT resolution ---

actual="$(OVERTURE_SUPPORT_DIR= HOME=/fake/home bash -c '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; echo "$SUPPORT"')"
assert_equals "SUPPORT falls back to \$HOME/Library/Application Support/Overture when unset" \
  "/fake/home/Library/Application Support/Overture" "${actual}"

actual="$(OVERTURE_SUPPORT_DIR="${TMP_ROOT}/handoff" bash -c '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; echo "$SUPPORT"')"
assert_equals "SUPPORT honors \$OVERTURE_SUPPORT_DIR when set" "${TMP_ROOT}/handoff" "${actual}"

# --- require_queue ---

mkdir -p "${TMP_ROOT}/queue-dir"
: > "${TMP_ROOT}/queue-dir/queue.json"

out="$(bash -c '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; require_queue "'"${TMP_ROOT}"'/queue-dir/queue.json" "prep"; echo survived' 2>&1)"
assert_contains "require_queue does not exit when the queue file exists" "${out}" "survived"

out="$(bash -c '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; require_queue "'"${TMP_ROOT}"'/queue-dir/missing.json" "reply-classify"; echo survived' 2>&1)"
assert_contains "require_queue reports the missing path and label" "${out}" \
  "no reply-classify queue at ${TMP_ROOT}/queue-dir/missing.json"
if [[ "${out}" == *"survived"* ]]; then
  echo "FAIL - require_queue must exit 1 on a missing queue, not continue"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - require_queue exits 1 on a missing queue instead of continuing"
fi

# --- resolve_claude ---

mkdir -p "${TMP_ROOT}/fake-bin"
cat > "${TMP_ROOT}/fake-bin/claude" <<'EOS'
#!/bin/sh
echo fake-claude
EOS
chmod +x "${TMP_ROOT}/fake-bin/claude"

mkdir -p "${TMP_ROOT}/home-without-local-claude"
actual="$(PATH="${TMP_ROOT}/fake-bin:/usr/bin:/bin" HOME="${TMP_ROOT}/home-without-local-claude" bash -c \
  '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; resolve_claude; echo "$CLAUDE"')"
assert_equals "resolve_claude finds claude via PATH lookup" "${TMP_ROOT}/fake-bin/claude" "${actual}"

mkdir -p "${TMP_ROOT}/empty-home"
out="$(PATH="/usr/bin:/bin" HOME="${TMP_ROOT}/empty-home" bash -c '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; resolve_claude; echo survived' 2>&1)"
assert_contains "resolve_claude reports when no claude binary is found anywhere" "${out}" "claude CLI not found"
if [[ "${out}" == *"survived"* ]]; then
  echo "FAIL - resolve_claude must exit 1 when no claude binary is found, not continue"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - resolve_claude exits 1 when no claude binary is found"
fi

# --- open_run_log ---

out="$(OVERTURE_SUPPORT_DIR="${TMP_ROOT}/nested/support" bash -c \
  '. "'"${SCRIPT_DIR}"'/runner-setup.sh"; open_run_log "test-run.log"; echo "logged line"')"
LOG_FILE="${TMP_ROOT}/nested/support/test-run.log"
if [[ -f "${LOG_FILE}" ]]; then
  assert_contains "open_run_log redirects subsequent stdout into the log file (creating the support dir first)" \
    "$(cat "${LOG_FILE}")" "logged line"
else
  echo "FAIL - open_run_log did not create ${LOG_FILE}"
  FAILURES=$((FAILURES + 1))
fi
assert_equals "open_run_log's own stdout is not leaked to the caller's stdout" "" "${out}"

echo "---"
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "all runner-setup.sh assertions passed"
  exit 0
else
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
