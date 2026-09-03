#!/usr/bin/env bash
# Whether a test fixture sized against the live store has quietly fallen behind it (#3426).
#
# WHY. Two cost guards size their corpus with a number measured against the live store once and never
# moved: `QueueRenderPassCostTests` and `QueueRebuildCostTests`. The store grows every time the scout
# runs, so both were exercising a store between a fifth and a third smaller than the one that ships, and
# NEITHER SAID SO. That fails in the direction that hides a problem rather than inventing one, which is
# why nothing reported it: the tests stay green while protecting a smaller world (L354).
#
# A number a person has to remember to update is a rule living only in prose (L27), and a figure with a
# date beside it reads as more trustworthy the older it gets (L316). So this measures.
#
# WHAT IT SCANS is DERIVED from the source, not from a list kept here (L96): any declaration tagged
#
#     // LIVE-SHAPE: <dimension>
#
# on the line above it joins the check automatically. What is kept here is only the definition of each
# dimension, which is the one thing a source scan cannot supply.
#
# FOUR OUTCOMES, and they are four because folding any pair loses something real (L11, L98):
#
#   0  every tagged declaration is at or above the live figure, within tolerance.
#   1  one or more have fallen materially below. ADVISORY: it names the dimension, both numbers and the
#      file, and does NOT fail the run, because the store grows nightly and a gate that fires on ordinary
#      growth has its threshold raised until it catches nothing (L36, L93).
#   2  UNMEASURED. A store that is PRESENT and could not be read, a tag naming a dimension this cannot
#      measure, or a scan that found no declarations at all. Each is a failed measurement rather than a
#      clean one, and this is the one outcome that fails the run.
#   3  no live store on this machine at all. The ordinary state on a clone, in CI and in an agent
#      worktree, so it can never be a refusal; kept apart from 0 because a run that measured nothing
#      must not read as one that measured and was happy.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/scratch.sh
. "${SCRIPT_DIR}/lib/scratch.sh"

LIVE_STORE="${OVERTURE_LIVE_STORE:-${HOME}/Library/Application Support/Overture/Overture.store}"
DECL_ROOT="${OVERTURE_CORPUS_DECL_ROOT:-${SCRIPT_DIR}/../mac/OvertureTests}"

# How far below the live figure a declaration may sit before it is reported. The store grows every night,
# so this is not zero: what the check exists to catch is a fixture protecting a MATERIALLY smaller world,
# not one a few rows behind. Set from the drift that prompted #3426, where the two guards sat 21% and 36%
# below, so anything of that order is caught well before it gets there.
TOLERANCE_PERCENT="${OVERTURE_CORPUS_DRIFT_TOLERANCE:-10}"

# The one thing a source scan cannot supply: what each dimension MEANS against the store. A tag naming
# anything not here is refused rather than skipped, because a silently ignored tag is a declaration
# nobody is checking while it reads as covered (L100).
sql_for_dimension() {
  case "$1" in
    prospects)  echo "select count(*) from ZPROSPECT;" ;;
    presenters) echo "select count(distinct ZPRESENTER) from ZPROSPECT where ZPRESENTER is not null and ZPRESENTER <> '';" ;;
    venues)     echo "select count(distinct ZVENUE) from ZPROSPECT where ZVENUE is not null and ZVENUE <> '';" ;;
    groupNames) echo "select count(distinct ZGROUPNAME) from ZPROSPECT where ZGROUPNAME is not null and ZGROUPNAME <> '';" ;;
    sources)    echo "select count(*) from ZWATCHEDSOURCE;" ;;
    untriaged)  echo "select count(*) from ZPROSPECT where ZSTATUSRAW = 'new';" ;;
    # #2048: the contact and draft shape, which is what the per-card work scales with. The cost fixture
    # held 1,139 prospects and NOT ONE recipient before this, so every per-contact path short-circuited
    # on its first line and a lint counter pinned against it would have read zero (L90, L101).
    recipients) echo "select count(*) from ZRECIPIENT;" ;;
    prospectsWithAContact)
                echo "select count(distinct ZPROSPECT) from ZRECIPIENT where ZPROSPECT is not null;" ;;
    pendingRecipients)
                echo "select count(*) from ZRECIPIENT where ZSENDSTATERAW = 'pending';" ;;
    # The lint's real input: DraftCheck is reached only through a non-empty effectiveBody, and the body
    # lives on the prospect, so this is the dimension the draft-lint counter scales with.
    prospectsWithADraftBody)
                echo "select count(*) from ZPROSPECT where ZDRAFTBODY is not null and ZDRAFTBODY <> '';" ;;
    # #3506: the INTERSECTION, which is what the draft lint actually scales with and what no other
    # dimension here can see. `Recipient.draftLintBlockers` reaches DraftCheck only through a non-empty
    # effectiveBody, and QueueItem.init asks that of the PENDING recipients, so a fixture matching every
    # dimension above can still exercise five times the real lint load (L48, L354).
    pendingRecipientsWithADraftBody)
                echo "select count(*) from ZRECIPIENT r left join ZPROSPECT p on r.ZPROSPECT = p.Z_PK where r.ZSENDSTATERAW = 'pending' and coalesce(nullif(r.ZOVERRIDEBODY,''), nullif(p.ZDRAFTBODY,'')) is not null;" ;;
    recipientsOnDraftBodyRows)
                echo "select count(*) from ZRECIPIENT r join ZPROSPECT p on r.ZPROSPECT = p.Z_PK where p.ZDRAFTBODY is not null and p.ZDRAFTBODY <> '';" ;;
    *)          return 1 ;;
  esac
}

if [ ! -f "${LIVE_STORE}" ]; then
  echo "check-fixture-corpus-drift: no live store at ${LIVE_STORE}, so nothing was measured."
  echo "  That is the ordinary state on a clone, in CI and in an agent worktree. It is reported rather"
  echo "  than passed silently, because a run that measured nothing is not a run that found nothing."
  exit 3
fi

# --- read the live store, through a WAL-inclusive copy ------------------------------------------------
#
# The `.store` file alone is not the store: recent writes live in the `-wal` beside it, so a read of the
# bare file reports a state that was true at the last checkpoint. Copied rather than opened, so nothing
# here can touch the file Dan's app is using. Measured 2026-09-02 at 0.06 to 0.09s for the copy and the
# count together, which is what makes it affordable on the mandatory pre-push gate.
COPY_DIR="$(overture_scratch_dir corpus-drift)" || COPY_DIR=""
# Checked for EMPTINESS as well as for a failed status, and the trap is armed only afterwards. `mktemp -d`
# either prints a path or exits non-zero, so an empty value with a zero status is theoretical rather than
# something seen; it is guarded because of what it would DO, not because of how likely it is. With
# COPY_DIR empty the copy below writes to `/live.store`, at the root of the filesystem, and the teardown
# runs `rm -rf ""`. A blank value must never be what drives a path that copies and deletes (L5).
if [ -z "${COPY_DIR}" ] || [ ! -d "${COPY_DIR}" ]; then
  echo "UNMEASURED: could not make a scratch directory to copy the store into, so nothing was measured."
  exit 2
fi
trap 'rm -rf "${COPY_DIR}"' EXIT
for ext in "" "-wal" "-shm"; do
  [ -f "${LIVE_STORE}${ext}" ] && cp "${LIVE_STORE}${ext}" "${COPY_DIR}/live.store${ext}"
done
if [ ! -f "${COPY_DIR}/live.store" ]; then
  echo "UNMEASURED: the live store at ${LIVE_STORE} could not be copied, so nothing was measured."
  echo "            That is not the same as a machine without one."
  exit 2
fi

live_count() {
  local sql; sql="$(sql_for_dimension "$1")" || return 1
  sqlite3 "${COPY_DIR}/live.store" "${sql}" 2>/dev/null | grep -E '^[0-9]+$' || true
}

# --- find every tagged declaration --------------------------------------------------------------------
#
# The tag is on the line ABOVE the declaration, so the number is read from the line that follows it. Any
# file under the scanned root joins by carrying the tag; nothing is listed here.
# Read per file with awk, so the filename comes from awk's own FILENAME rather than from parsing grep's
# context format. That format interleaves `path:line:` for a match with `path-line-` for the line after
# it, and a scratch directory called `overture-fixture-12345-ab` matches the second shape, so the first
# version of this reported the temp directory as the file the declaration lived in.
DECLS=""
while IFS= read -r swift_file; do
  [ -n "${swift_file}" ] || continue
  found="$(awk '
    /LIVE-SHAPE:/ {
      dim = $0
      sub(/^.*LIVE-SHAPE:[[:space:]]*/, "", dim)
      sub(/[[:space:]].*$/, "", dim)
      pending = dim
      next
    }
    pending != "" {
      if (match($0, /=[[:space:]]*[0-9]+/)) {
        value = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", value)
        if (value != "") printf "%s\t%s\t%s\n", pending, value, FILENAME
      }
      pending = ""
    }' "${swift_file}" 2>/dev/null)"
  [ -n "${found}" ] && DECLS="${DECLS}${found}"$'\n'
done <<< "$(find "${DECL_ROOT}" -name '*.swift' -type f 2>/dev/null | sort)"
DECLS="$(printf '%s' "${DECLS}" | grep -v '^[[:space:]]*$' || true)"

DECL_COUNT="$(printf '%s\n' "${DECLS}" | grep -c . || true)"
if [ "${DECL_COUNT}" -eq 0 ]; then
  echo "UNMEASURED: no declaration under ${DECL_ROOT} carries a LIVE-SHAPE tag, so this compared nothing."
  echo "            A scan that found nothing and a tree whose figures are all current leave the same"
  echo "            empty result, and the emptiest possible failure must not read as the cleanest pass."
  exit 2
fi

# --- compare -------------------------------------------------------------------------------------------
DRIFTED=""
UNKNOWN=""
REPORTED=""
while IFS=$'\t' read -r dim declared file; do
  [ -n "${dim}" ] || continue
  if ! sql_for_dimension "${dim}" >/dev/null 2>&1; then
    UNKNOWN="${UNKNOWN}    ${dim}  (tagged in ${file##*/})"$'\n'
    continue
  fi
  live="$(live_count "${dim}")"
  if [ -z "${live}" ]; then
    UNKNOWN="${UNKNOWN}    ${dim}  (could not be counted on the live store)"$'\n'
    continue
  fi
  floor="$(awk -v l="${live}" -v t="${TOLERANCE_PERCENT}" 'BEGIN { printf "%d", l * (100 - t) / 100 }')"
  REPORTED="${REPORTED}    ${dim}: fixture ${declared}, live ${live}  (${file##*/})"$'\n'
  if [ "${declared}" -lt "${floor}" ]; then
    DRIFTED="${DRIFTED}    ${dim}: the fixture says ${declared}, the live store holds ${live}  (${file##*/})"$'\n'
  fi
done <<< "${DECLS}"

if [ -n "${UNKNOWN}" ]; then
  echo "UNMEASURED: a LIVE-SHAPE tag names something this cannot measure, so it was not checked:"
  printf '%s' "${UNKNOWN}"
  echo "            Add it to sql_for_dimension, or fix the tag. A tag that is silently ignored is a"
  echo "            declaration nobody is checking while it reads as covered."
  exit 2
fi

echo "check-fixture-corpus-drift: ${DECL_COUNT} tagged declaration(s) against the live store"
printf '%s' "${REPORTED}"

if [ -z "${DRIFTED}" ]; then
  echo "  All within tolerance (no more than ${TOLERANCE_PERCENT}% below the live figure)."
  exit 0
fi

echo
echo "  DRIFTED. These are more than ${TOLERANCE_PERCENT}% below the store that actually ships:"
printf '%s' "${DRIFTED}"
echo "  The guard stays green the whole time this is true, because it is exercising a smaller world"
echo "  rather than failing. Re-measure and update the declaration and its recorded date together."
echo "  Advisory, so this does NOT fail the run: the store grows every night and a gate that fires on"
echo "  ordinary growth gets its threshold raised until it catches nothing. Widen it for one run with"
echo "  OVERTURE_CORPUS_DRIFT_TOLERANCE=<percent>."
exit 1
