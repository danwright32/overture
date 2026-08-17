#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2611: something in this repo's tooling put a THROWAWAY keychain into the user's REAL keychain
# search list, which is a persistent OS level resource outside the checkout, and nothing removed the
# entry when the temp directory went away. Measured 2026-08-13, `security list-keychains` held:
#
#     /private/var/folders/.../T/tmp.uIH2OYGQWw/throwaway.keychain-db
#
# and that directory was long gone. Nothing is broken by it (an entry pointing at a missing file is
# skipped, and all four real signing identities still resolve), which is why it is p3. It matters
# because it is state that makes the next diagnosis harder in exactly the area that has already
# produced #1425, #1525, #1526 and #2537, every one of which was somebody trying to work out what
# the keychain actually held.
#
# The rule this removes by is narrow on purpose and mirrors #2585's: an entry whose FILE is gone can
# never be resolved by anything, so dropping it costs nobody an identity, and that is a far safer
# question than which entries look like they belong. Every path that still exists is kept, in the
# order it was in.
#
# Driven against real files in a throwaway directory rather than against this Mac's own search list:
# a fixture that read the live list would assert about whatever this Mac happened to hold, and one
# that WROTE it would be the very defect this issue is about (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./lib/keychain-search-list.sh
source "${SCRIPT_DIR}/lib/keychain-search-list.sh"

FAILURES=0

# `security list-keychains` indents each entry and wraps it in quotes. Real shape, from the reading
# above, with this Mac's own paths replaced by the fixture's so nothing here depends on them.
WORK_DIR="$(mktemp -d)"
LOGIN_KC="${WORK_DIR}/login.keychain-db"
SIGNING_KC="${WORK_DIR}/overture-signing.keychain-db"
SYSTEM_KC="${WORK_DIR}/System.keychain"
GONE_KC="${WORK_DIR}/tmp.uIH2OYGQWw/throwaway.keychain-db"
: > "${LOGIN_KC}"
: > "${SIGNING_KC}"
: > "${SYSTEM_KC}"

LIST_OUTPUT="    \"${LOGIN_KC}\"
    \"${SIGNING_KC}\"
    \"${GONE_KC}\"
    \"${SYSTEM_KC}\""

assert_equals "each entry is read out of the quoted, indented listing" \
  "${LOGIN_KC}
${SIGNING_KC}
${GONE_KC}
${SYSTEM_KC}" \
  "$(keychain_search_list_paths "${LIST_OUTPUT}")"

assert_equals "the entry whose file is gone is the one named as stale" \
  "${GONE_KC}" \
  "$(keychain_paths_missing "$(keychain_search_list_paths "${LIST_OUTPUT}")")"

# What it must PRESERVE, not only what it must catch (L104), and in the ORDER it was in: the search
# list is consulted in order, so rewriting it is a chance to reshuffle which keychain answers first.
assert_equals "every entry that still exists is kept, in the order it was in" \
  "${LOGIN_KC}
${SIGNING_KC}
${SYSTEM_KC}" \
  "$(keychain_paths_present "$(keychain_search_list_paths "${LIST_OUTPUT}")")"

CLEAN_LIST="    \"${LOGIN_KC}\"
    \"${SYSTEM_KC}\""
assert_empty "a list with nothing stale in it names nothing" \
  "$(keychain_paths_missing "$(keychain_search_list_paths "${CLEAN_LIST}")")"

# The refusal that matters. This writes a persistent OS resource, and a list it could not read comes
# back as no paths at all, which would look exactly like "every entry is stale" and would set the
# user's search list to nothing. Failing closed here means leaving the list alone (L42).
assert_empty "an unreadable listing yields no paths at all" \
  "$(keychain_search_list_paths "")"

assert_equals "and a rewrite that would empty the search list is refused, not performed" \
  "refuse" \
  "$(keychain_rewrite_verdict "" "${LOGIN_KC}")"

assert_equals "a rewrite that drops nothing is not worth performing either" \
  "nothing-to-do" \
  "$(keychain_rewrite_verdict "${LOGIN_KC}
${SYSTEM_KC}" "")"

assert_equals "and one that drops a gone entry while keeping a real one goes ahead" \
  "rewrite" \
  "$(keychain_rewrite_verdict "${LOGIN_KC}
${SYSTEM_KC}" "${GONE_KC}")"

echo
# --- the wiring, which is the separate claim (L3) -------------------------------------------
#
# Every assertion above passes while the script still writes the wrong list, or writes none at all.
# `security` is stubbed on PATH and records every invocation, so what the run WOULD have written to
# the real search list is asserted directly rather than inferred from a message.

run_prune_with_stub_security() {
  local list_output="$1"
  shift
  local bin_dir out code calls

  bin_dir="$(mktemp -d)"
  cat > "${bin_dir}/security" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${bin_dir}/security-calls"
case "\$*" in
  *-s*) exit 0 ;;
esac
cat <<'LIST_OUTPUT'
${list_output}
LIST_OUTPUT
exit 0
STUB
  chmod +x "${bin_dir}/security"

  out="$(PATH="${bin_dir}:${PATH}" "${SCRIPT_DIR}/prune-stale-keychains.sh" "$@" 2>&1)"
  code=$?
  calls="$(cat "${bin_dir}/security-calls" 2>/dev/null || true)"
  rm -rf "${bin_dir}"
  printf '%s\ncalls<<%s>>\nexit=%s\n' "${out}" "${calls}" "${code}"
}

STALE_RUN="$(run_prune_with_stub_security "${LIST_OUTPUT}")"

assert_contains "the run names the stale entry it found" \
  "${STALE_RUN}" "${GONE_KC}"

# THE assertion. The command it issues is what actually changes the machine, so it is checked as a
# whole: the three surviving paths, in order, and the missing one absent.
assert_contains "and rewrites the search list to exactly the entries that still exist" \
  "${STALE_RUN}" "list-keychains -d user -s ${LOGIN_KC} ${SIGNING_KC} ${SYSTEM_KC}"

assert_not_contains "so the entry pointing at a directory that is gone is not written back" \
  "${STALE_RUN}" "-s ${LOGIN_KC} ${SIGNING_KC} ${GONE_KC}"

assert_contains "and the run succeeds" "${STALE_RUN}" "exit=0"

CLEAN_RUN="$(run_prune_with_stub_security "${CLEAN_LIST}")"

assert_contains "a search list with nothing stale in it says so" \
  "${CLEAN_RUN}" "nothing stale"

# A tool that rewrites a persistent OS resource it did not need to touch is a worse tool than one
# that does nothing. Asserted on the CALL, because "wrote the same list back" and "left it alone"
# read identically afterwards (L11).
assert_not_contains "and writes nothing at all, rather than writing the same list back" \
  "${CLEAN_RUN}" "-s "

DRY_RUN="$(run_prune_with_stub_security "${LIST_OUTPUT}" --dry-run)"

assert_contains "a dry run still names what it found" "${DRY_RUN}" "${GONE_KC}"

assert_not_contains "but writes nothing" "${DRY_RUN}" "-s "

echo
# --- the class, not the instance (#2611 step 3) ----------------------------------------------
#
# The entry predates the seam #2537 added, and today's setup-signing-identity.test.sh stubs
# `overture_setup_prepare_keychain`, which is the function that writes the search list. So no fixture
# here is the culprit now. This is what stops one becoming it: a test that needs its own keychain
# passes it by `--keychain` scope, and never puts it in the user's list.
#
# The pattern is BUILT rather than written, so this guard does not match its own needle sitting in
# its own file, which would make it green forever whatever the rest of the repo did.
SEARCH_LIST_WRITE="list-keychains -d user -""s"
OFFENDERS="$(grep -rl --include='*.test.sh' -- "${SEARCH_LIST_WRITE}" \
  "${REPO_ROOT}/scripts" "${REPO_ROOT}/mac/scripts" 2>/dev/null \
  | grep -v 'prune-stale-keychains.test.sh' || true)"

# The guard is only worth having if it can see a fixture that does this, and the file it exempts is
# the one place the phrase legitimately appears, so prove the search reaches the exempted file at all
# rather than trusting that it looked (L1: a filter that matched nothing reads exactly like a clean
# repo).
assert_contains "and the search really does reach fixtures, including the one it exempts" \
  "$(grep -rl --include='*.test.sh' -- "${SEARCH_LIST_WRITE}" \
    "${REPO_ROOT}/scripts" "${REPO_ROOT}/mac/scripts" 2>/dev/null || true)" \
  "prune-stale-keychains.test.sh"

assert_empty "no test fixture writes the user's real keychain search list" "${OFFENDERS}"

rm -rf "${WORK_DIR}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All prune-stale-keychains.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} prune-stale-keychains.sh fixture(s) failed." >&2
exit 1
