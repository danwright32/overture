#!/usr/bin/env bash
set -euo pipefail

# Guards against a second near-copy source-health recorder drifting apart from the consolidated one
# (#1073). The same defect shape recurred three times: two almost-identical functions that record a
# watched source's health drifted, and each recurrence was silent (the path nobody updated kept
# compiling and running, it just stopped writing one field, and no test failed):
#
#   #987  recordCheck and recordSuccess disagreed on the #891 readable/unreadable counts.
#   #1001 filed the duplication; the fold, counts, placement and warmup were consolidated onto the
#         ONE shared WatchedSource.recordSuccessfulRead the two ingest doors both call.
#   #1005 the #986 placement detector had been wired into only ONE of the pair.
#
# The consolidation put every source-health field write in ONE place. This check makes that hold at
# push time: it scans the two ingest files where those recorders live and fails if MORE THAN ONE
# function in them DIRECTLY assigns the source-health field cluster (readable/unreadable, placement,
# and the feed-health fold/warmup). Everything else must delegate to WatchedSource.recordSuccessfulRead
# rather than inline a second copy that can silently stop writing one field.
#
# Scoped narrowly to these two files ON PURPOSE (not a whole-repo scan): they are where the recurrence
# happened, WatchedSource.recordSuccessfulRead is the single owner they both call, and a narrow scope
# keeps false positives near zero. One legitimate direct writer is allowed: recordPartialCheck, which
# CANNOT delegate because it deliberately writes only a subset (a partial read must not run the health
# fold or the warmup counter). The point of #1073 is that a SECOND one must be seen, not silent.
#
# The pure comparison (health_recorder_funcs) is covered by check-health-recorder-drift.test.sh, which
# drives it against throwaway text so it runs anywhere including CI.
#
# Usage: scripts/check-health-recorder-drift.sh [file ...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The distinctive fingerprint of a source-health recorder: the fields WatchedSource.recordSuccessfulRead
# writes that no other function has any business assigning directly. Deliberately NOT the generic
# lifecycle fields (lastCheckedAt, health, lastFailure, hasUnreadChanges): those legitimately appear in
# fail(), recordConfirmedEmpty() and others, so counting them would false-alarm. These nine are the
# readable/unreadable counts (#891), the placement detector (#986), and the feed-health fold plus warmup
# counter (#150/#152/#801) that are exactly what drifted before.
HEALTH_RECORDER_FIELDS=(
  lastReadableCount
  lastUnreadableCount
  lastUnreadableTitleCount
  hadPlacedBeforeLastRun
  lastPlacedCount
  baselineFeedCount
  degradedStreak
  lastDegradedCount
  successfulCheckCount
)

# How many DISTINCT cluster fields a function must directly assign to count as a recorder body. A real
# recorder writes the readable/unreadable/placement group together (recordPartialCheck writes five); a
# function that merely touches one or two of these for an unrelated reason is not a near-copy. Three is
# high enough to ignore incidental touches and low enough to catch a genuine copy.
HEALTH_RECORDER_THRESHOLD=3

# Given Swift source text ($1), prints the name of every function in it that DIRECTLY assigns at least
# HEALTH_RECORDER_THRESHOLD distinct cluster fields (one name per line, sorted), and returns how many
# such functions there are. Pure: takes text, touches no files, so the test drives it with throwaway
# content. An assignment is `something.field = ...` or `something.field += ...`; a read
# (`source?.field ?? 0`), a labeled argument (`field: ...`), a comparison (`field > 0`) and a full-line
# comment are all deliberately NOT assignments and must not count.
health_recorder_funcs() {
  local text="$1"
  local line field current="(top level)" pairs=""

  while IFS= read -r line; do
    # Full-line comments never assign anything, even when they name a field to explain what a function
    # deliberately does NOT write (recordPartialCheck's docblock does exactly this).
    if [[ "${line}" =~ ^[[:space:]]*// ]]; then
      continue
    fi
    # A function boundary: attribute every later assignment to this name until the next one.
    if [[ "${line}" =~ func[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
      current="${BASH_REMATCH[1]}"
      continue
    fi
    for field in "${HEALTH_RECORDER_FIELDS[@]}"; do
      # `.field` then optional whitespace, an optional `+` (for `+=`), a single `=`, then a non-`=`
      # (or end of line). The trailing non-`=` is what excludes `==`, so a comparison never counts.
      if [[ "${line}" =~ \.${field}[[:space:]]*[+]?=([^=]|$) ]]; then
        pairs+="${current}	${field}"$'\n'
      fi
    done
  done <<< "${text}"

  # No assignments at all (ScoutService.swift delegates entirely) is the common, healthy case: emit
  # nothing and return clean rather than letting an empty pipeline's nonzero status trip `set -e`.
  if [[ -z "${pairs}" ]]; then
    return 0
  fi

  # sort -u dedupes the func/field pairs (a field assigned twice counts once); awk then counts DISTINCT
  # fields per function and emits only those at or over the threshold. The lone trailing empty line from
  # the accumulator has no field and can never reach the threshold, so it is ignored.
  printf '%s' "${pairs}" \
    | sort -u \
    | awk -F'\t' -v threshold="${HEALTH_RECORDER_THRESHOLD}" \
        '$1 != "" { count[$1]++ } END { for (fn in count) if (count[fn] >= threshold) print fn }' \
    | sort
  return 0
}

main() {
  local files=("$@")
  if [[ "${#files[@]}" -eq 0 ]]; then
    files=(
      "${REPO_ROOT}/mac/Overture/Integration/ScoutService.swift"
      "${REPO_ROOT}/mac/Overture/Integration/ScoutExtractIngest.swift"
    )
  fi

  local qualifying=() file names name
  for file in "${files[@]}"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: file not found at ${file}" >&2
      exit 2
    fi
    names="$(health_recorder_funcs "$(cat "${file}")")"
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      qualifying+=("$(basename "${file}"): ${name}")
    done <<< "${names}"
  done

  if [[ "${#qualifying[@]}" -le 1 ]]; then
    echo "OK: at most one direct source-health recorder across the scout ingest files; the rest delegate to WatchedSource.recordSuccessfulRead."
    exit 0
  fi

  echo "DRIFT RISK: more than one function directly writes the source-health field cluster:"
  for name in "${qualifying[@]}"; do
    echo "  ${name}"
  done
  echo
  echo "This is the #987/#1001/#1005 shape: two near-copy recorders that will silently drift when one"
  echo "stops writing a field. Consolidate onto WatchedSource.recordSuccessfulRead so a single owner writes"
  echo "the readable/unreadable counts, the placement detector, and the feed-health fold. If a second"
  echo "PARTIAL recorder is genuinely required, allow it consciously by updating this guard."
  exit 1
}

# Sourceable without running (the test sources this to drive health_recorder_funcs directly). Mirrors
# the convention in check-brand-voice-drift.sh, merge-when-green.sh and check-pr-ci.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
