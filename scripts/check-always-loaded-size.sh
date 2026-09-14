#!/usr/bin/env bash
set -uo pipefail

# Says when a file Claude Code loads AUTOMATICALLY into every session is running out of room (#3640).
#
# AGENTS.md reached 152,967 characters against a 150,000 character ceiling. Nothing in this
# repository measured it, and nothing could have: what reported the crossing was a warning Dan
# happened to have on screen. The failure past that ceiling is the shape worth knowing before
# reading anything below: the rules do not fail, they stop ARRIVING, and a rule that never arrived
# is indistinguishable from one that was followed (L429). Every contributor adds a paragraph and
# none of them can see the total, so the growth is nobody's decision.
#
# ADVISORY ONLY, and it can never fail a run, for the reason scripts/check-branch-backlog.sh already
# rides along under: a large instructions file is not a defect in the change being pushed, and a
# gate here would be overridden every time and then ignored (L36, L93).
#
# The corpus is DERIVED rather than listed. It starts at the two files Claude Code loads by name and
# FOLLOWS the `@path` imports out of them, because an imported file is loaded exactly as
# automatically as the file importing it and shares its ceiling. A registry would cover only what
# somebody remembered to add (L96).
#
# Usage: scripts/check-always-loaded-size.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the fixture drives the real script against a THROWAWAY directory. A fixture reading
# this checkout's own AGENTS.md would assert about whatever that file happened to be that day (L2).
REPO_ROOT="${ALWAYS_LOADED_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# The ceiling Claude Code enforces on a project instructions file.
LIMIT="${ALWAYS_LOADED_LIMIT:-150000}"
# Warn at four fifths of it. Chosen so the notice arrives with time to act rather than at a round
# number: AGENTS.md grew about 2,500 characters a day over the week it crossed, which from four
# fifths is roughly twelve days of warning.
WARN_AT="${ALWAYS_LOADED_WARN_AT:-$(( LIMIT * 80 / 100 ))}"

# The files loaded by name, before imports are followed.
ROOTS="CLAUDE.md
AGENTS.md"

# Every always-loaded file, relative to REPO_ROOT, one per line: the roots above plus whatever they
# import, transitively, each named once. Written with newline-delimited strings rather than arrays
# and `mapfile` because this Mac's bash is 3.2, where `mapfile` does not exist and an empty array
# under `set -u` is an error.
always_loaded_files() {
  local pending found current imported

  # Every entry carries its own trailing newline, so appending one to a non-empty queue cannot fuse
  # it onto the entry in front of it. It did: "AGENTS.md" plus "AGENTS.md" became one path named
  # "AGENTS.mdAGENTS.md", which does not exist, so the file this whole check is about was silently
  # dropped from the corpus and the run printed nothing at all (L251).
  pending="${ROOTS}"$'\n'
  found=""

  while [[ -n "${pending}" ]]; do
    current="${pending%%$'\n'*}"
    if [[ "${current}" == "${pending}" ]]; then pending=""; else pending="${pending#*$'\n'}"; fi
    [[ -n "${current}" ]] || continue

    case $'\n'"${found}"$'\n' in *$'\n'"${current}"$'\n'*) continue ;; esac
    [[ -e "${REPO_ROOT}/${current}" ]] || continue
    found="${found}${current}"$'\n'

    # An unreadable file is reported by the caller, not skipped here; it simply imports nothing we
    # can see, which is a smaller claim than pretending it holds no imports.
    [[ -r "${REPO_ROOT}/${current}" ]] || continue
    # -E rather than a BRE with \+, which BSD and GNU grep read differently with no error either
    # way, so the pattern quietly stops matching on one of them (L434).
    while IFS= read -r imported; do
      imported="${imported#@}"
      [[ -n "${imported}" ]] && pending="${pending}${imported}"$'\n'
    done < <(grep -oE '^@[^[:space:]]+' "${REPO_ROOT}/${current}" 2>/dev/null)
  done

  printf '%s' "${found}"
}

main() {
  local files file size measured=0 spoke=0

  files="$(always_loaded_files)"

  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue

    # A size that could not be read is not a size of zero. Letting wc's failure fall through would
    # report the largest possible problem as the smallest possible one (L98, L11).
    if ! size="$(wc -c < "${REPO_ROOT}/${file}" 2>/dev/null)"; then
      echo "check-always-loaded-size: could not measure ${file}, so its size is unknown."
      spoke=1
      continue
    fi
    size="${size//[[:space:]]/}"
    measured=$(( measured + 1 ))

    if [[ "${size}" -ge "${LIMIT}" ]]; then
      echo "check-always-loaded-size: ${file} is ${size} characters, OVER the ${LIMIT} character ceiling. Past it the rules stop arriving rather than failing. Move bodies into docs/agents/ and leave a pointer (#3640)."
      spoke=1
    elif [[ "${size}" -ge "${WARN_AT}" ]]; then
      echo "check-always-loaded-size: ${file} is ${size} characters against a ${LIMIT} character ceiling. Add new rules to docs/agents/ rather than here (#3640)."
      spoke=1
    fi
  done <<< "${files}"

  # An empty directory and a directory of small files leave the same silence, so the one case that
  # measured nothing says so rather than passing quietly (L98).
  if [[ "${measured}" -eq 0 && "${spoke}" -eq 0 ]]; then
    echo "check-always-loaded-size: UNMEASURED, no always-loaded instructions file was found under ${REPO_ROOT}."
  fi

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
