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

# --- #1711: a run whose environment carries no HOME ---
#
# Every runner declares `set -eu`, so a bare $HOME inside this file killed the whole script with
# "runner-setup.sh: line 26: HOME: unbound variable" before it had opened its run log. That is the
# traceless early death #485 exists to prevent: the app sends the invocation's stdout and stderr to
# /dev/null, so the shell's own error reaches nobody and the run is indistinguishable from one that
# ran and found nothing. What follows pins the runner's own message in place of the shell's.

assert_lacks() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected NOT to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

out="$(env -u HOME -u OVERTURE_SUPPORT_DIR bash -c 'set -eu; . "'"${SCRIPT_DIR}"'/runner-setup.sh"; echo survived' 2>&1)"
assert_contains "no HOME and no OVERTURE_SUPPORT_DIR: names both things that are missing" \
  "${out}" "neither OVERTURE_SUPPORT_DIR nor HOME is set"
assert_contains "no HOME and no OVERTURE_SUPPORT_DIR: says what to do about it" \
  "${out}" "Set HOME to the account's home folder"
assert_lacks "no HOME and no OVERTURE_SUPPORT_DIR: the refusal is the runner's own, not the shell's" \
  "${out}" "unbound variable"
assert_lacks "no HOME and no OVERTURE_SUPPORT_DIR: the run stops rather than carrying on" \
  "${out}" "survived"

# The app always passes OVERTURE_SUPPORT_DIR, so an absent HOME must not stop a run that was told
# where its handoff folder is. HOME is only needed for the fallback.
actual="$(env -u HOME OVERTURE_SUPPORT_DIR="${TMP_ROOT}/handoff" bash -c \
  'set -eu; . "'"${SCRIPT_DIR}"'/runner-setup.sh"; echo "$SUPPORT"' 2>&1)"
assert_equals "no HOME but OVERTURE_SUPPORT_DIR given: SUPPORT resolves and the run continues" \
  "${TMP_ROOT}/handoff" "${actual}"

actual="$(env -u HOME PATH="${TMP_ROOT}/fake-bin:/usr/bin:/bin" OVERTURE_SUPPORT_DIR="${TMP_ROOT}/handoff" bash -c \
  'set -eu; . "'"${SCRIPT_DIR}"'/runner-setup.sh"; resolve_claude; echo "$CLAUDE"' 2>&1)"
assert_equals "no HOME: resolve_claude still finds claude through PATH" \
  "${TMP_ROOT}/fake-bin/claude" "${actual}"

out="$(env -u HOME PATH="/usr/bin:/bin" OVERTURE_SUPPORT_DIR="${TMP_ROOT}/handoff" bash -c \
  'set -eu; . "'"${SCRIPT_DIR}"'/runner-setup.sh"; resolve_claude; echo survived' 2>&1)"
assert_contains "no HOME and no claude anywhere: still reports the missing binary" \
  "${out}" "claude CLI not found"
assert_contains "no HOME and no claude anywhere: says the home install path went unsearched" \
  "${out}" "HOME is not set in this run's environment"
assert_lacks "no HOME and no claude anywhere: no raw shell error" "${out}" "unbound variable"
assert_lacks "no HOME and no claude anywhere: the run stops rather than carrying on" "${out}" "survived"

echo "---"
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "all runner-setup.sh assertions passed"
  exit 0
else
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
