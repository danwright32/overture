#!/usr/bin/env bash
# Decisions about the user's keychain SEARCH LIST (#2611). Pure functions only, except that two of
# them ask the filesystem whether a path exists, which is the whole question being asked.
#
# WHY this is careful out of proportion to its size. The search list is a persistent OS level
# resource outside the checkout, shared by every tool on this Mac that resolves an identity, and the
# only way to change it is to write the WHOLE list back. So a reading that comes back empty for any
# reason other than an empty list would, written back, leave the user with no keychains at all. Every
# question here therefore answers in the direction of leaving the list alone.
#
# What it is for: `security list-keychains` on this Mac held an entry pointing at
# /private/var/folders/.../T/tmp.uIH2OYGQWw/throwaway.keychain-db, a directory long since gone.
# Nothing is broken by it (an entry whose file is missing is skipped, and all four real signing
# identities still resolve), which is why the issue is p3. It matters because it is state that makes
# the next diagnosis harder in the one area that has already produced #1425, #1525, #1526 and #2537,
# every one of which was somebody trying to work out what the keychain actually held.

# Every path in a `security list-keychains` listing, one per line, in the order it was in. The
# listing indents each entry and wraps it in quotes.
#
# Order is preserved deliberately and is not cosmetic: the search list is consulted in order, so a
# rewrite that reshuffled it would change which keychain answers an identity lookup first.
keychain_search_list_paths() {
  local listing="$1" line
  [[ -n "${listing}" ]] || return 0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    line="${line#\"}"
    line="${line%\"}"
    [[ -n "${line}" ]] && printf '%s\n' "${line}"
  done <<< "${listing}"
  return 0
}

# Of the paths handed in, those whose file is GONE from disk.
#
# The rule is narrow on purpose, and mirrors the one #2585 reclaims DerivedData by: an entry whose
# file no longer exists can never be resolved by anything, so dropping it costs nobody an identity.
# That is a far safer question than which entries look like they belong, which is a judgement about
# somebody else's tooling.
keychain_paths_missing() {
  local paths="$1" path
  [[ -n "${paths}" ]] || return 0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    [[ -e "${path}" ]] || printf '%s\n' "${path}"
  done <<< "${paths}"
  return 0
}

# The complement: everything that is still there, in the order it was in. This is what gets written
# back, so it is derived from the same list by the same rule rather than assembled separately.
keychain_paths_present() {
  local paths="$1" path
  [[ -n "${paths}" ]] || return 0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    [[ -e "${path}" ]] && printf '%s\n' "${path}"
  done <<< "${paths}"
  return 0
}

# keychain_rewrite_verdict <paths to keep> <paths that are gone>. One word: rewrite, nothing-to-do,
# or refuse.
#
# "refuse" is the one that earns this function. Writing the list back is the only way to change it,
# and an empty set of survivors is what an unreadable listing, a `security` that failed, and a
# genuinely empty list all look like. Two of those three must not lead to setting the user's search
# list to nothing, so none of them do (L42: a control that exists to protect something fails closed).
#
# "nothing-to-do" is separate from "rewrite" because a tool that writes a persistent OS resource it
# did not need to touch is worse than one that does nothing, and afterwards the two are
# indistinguishable.
keychain_rewrite_verdict() {
  local keep="$1" gone="$2"
  local keep_count gone_count
  keep_count="$(printf '%s' "${keep}" | grep -c . || true)"
  gone_count="$(printf '%s' "${gone}" | grep -c . || true)"

  [[ "${keep_count}" -gt 0 ]] || { echo "refuse"; return 0; }
  [[ "${gone_count}" -gt 0 ]] || { echo "nothing-to-do"; return 0; }
  echo "rewrite"
}
