#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# #1808: the shape of `shipped-commit.json` is a contract the Swift app decodes (BuildFreshness), so it
# is pinned here rather than only being produced. A field renamed on this side and not the other leaves
# the app permanently unable to tell how old it is, which it reports honestly but which nobody would
# connect back to a shell edit.
#
# Exercises the pure composer only. Nothing here runs git, fetches, or writes into Application Support.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./record-shipped-commit.sh
source "${SCRIPT_DIR}/record-shipped-commit.sh"
set +e

FAILURES=0

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
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
    echo "  actual:              ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# The exact bytes the app decodes: the three field names and an ISO 8601 date. Written out in full
# rather than checked field by field, so a stray key or a changed shape fails here.
assert_eq "the record is the shape BuildFreshness decodes" \
  "$(shipped_commit_json "abc123" "2026-08-03T23:06:00-04:00")" \
  '{"version":1,"commit":"abc123","commitDate":"2026-08-03T23:06:00-04:00"}'

# The date carries its offset rather than being flattened to a local-looking string, because the app
# decodes with .iso8601 and a date with no zone is a decode failure, which reads as "cannot tell".
assert_contains "the date keeps its timezone offset" \
  "$(shipped_commit_json "abc123" "2026-08-03T23:06:00-04:00")" \
  "-04:00"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All record-shipped-commit.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} record-shipped-commit.sh fixture(s) failed." >&2
exit 1
