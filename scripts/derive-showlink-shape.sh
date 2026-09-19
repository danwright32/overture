#!/usr/bin/env bash
set -euo pipefail

# Re-derives milestone 62's grouping figures from a store, so that a number quoted in a plan, an issue
# body or a PR can be re-taken by whoever reads it instead of being trusted (#3772).
#
# WHY THIS EXISTS. The Phase 2 plan (discussion #3771) quotes about forty measured figures, and the gate
# on it (#3772) found three that were wrong and several more that had simply aged: a group the plan sent
# somebody to screenshot on the queue turned out to be five dismissed rows, and two of three delete-site
# line numbers moved within nine days. A figure nobody can re-take is a figure nobody can correct, and
# this repository has already paid for that (L107, L418). So every figure in that correction round came
# out of this command, and the command ships beside it.
#
# WHAT IT IS NOT. It is an APPROXIMATION of the shipped rule and says so on every run. The real fold is
# Swift, TitleNormalization.normalizeForKey(Prospect.canonicalize(_)) for the title and
# canonicalize(VenueNormalization.normalizeForKey(_)) for the venue, in that order and no other
# (Prospect.swift:1651 to :1655), and no SQLite expression or rewrite of it here reproduces either. What
# this does instead is read the folded title and folded venue back OUT of each row's own stored
# ZNATURALKEY, which ScoutService wrote THROUGH that Swift fold. So the buckets are the shipped ones even
# though no Swift runs, and what remains approximate is only the clustering inside a bucket.
#
# WHERE IT DISAGREES WITH THE SHIPPED RULE, measured 2026-09-19 once ShowLink existed to compare
# against. On the QUEUE the two agree exactly: 596 rows, 6 groups, largest 2, 3 refused pairs. Over the
# whole store they do not, and ShowLink finds 19 groups against this command's 16. Both differences are
# this command's blind spots and neither is fixable here:
#   - ShowLink recomputes the fold from the row's CURRENT scout-anchored fields, while this reads the
#     fold as it was STORED in ZNATURALKEY when the row was last written. 6 rows carry a scoutVenue
#     differing from their venue.
#   - ShowLink unions Dan's DROPPED nights into the night set, because a group joined through a night he
#     then drops must not split back into fragments. 41 rows carry at least one dropped night, 112 in
#     total, and no SQL expression can decode them.
# So where the two disagree, ShowLinkCorpusShapeTests is right and this is not. Quote this for a figure
# nobody can otherwise re-take; never quote it as a statement of what the app does.
#
# THE POPULATIONS ARE THE POINT. #3772's claim 3 was that Phase 3 sent somebody to screenshot a group
# that is not on the surface it named. So this prints the shape of FOUR populations separately, never one
# blended number: the queue (rows the queue shows), all future rows whatever their stage, the archive
# (dismissed), and the whole store. A single figure over "the store" is what hid that defect.
#
# EXIT CODES. 0 derived. 2 UNMEASURED, a store is there and could not be read. 3 there is no store on
# this machine, which is the ordinary state in CI, in a fresh clone and in an agent worktree. 2 and 3 are
# kept apart from each other and from 0 because a run that measured nothing must never print a figure
# that reads like a measurement (L98, L11); on those paths this prints no figures at all.
#
# Usage: scripts/derive-showlink-shape.sh [--store PATH] [--asof YYYY-MM-DD]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/scratch.sh
. "${SCRIPT_DIR}/lib/scratch.sh"

LIVE_STORE="${HOME}/Library/Application Support/Overture/Overture.store"
STORE=""
ASOF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --store) STORE="${2:-}"; shift 2 ;;
    --asof) ASOF="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "${STORE}" ]] || STORE="${LIVE_STORE}"
[[ -n "${ASOF}" ]] || ASOF="$(date +%Y-%m-%d)"

if [[ ! -f "${STORE}" ]]; then
  echo "NO LIVE STORE at ${STORE}"
  echo "Nothing was measured. This is the ordinary state in CI, in a fresh clone and in a worktree."
  exit 3
fi

# The .store file alone is not the store: recent writes live in the -wal beside it, so a read of the file
# on its own answers about a past the app has already moved on from. And the live store is never opened
# directly even read-only, because SQLite rewrites the -shm alongside it when it does (L474).
COPY_DIR="$(overture_scratch_dir showlink-shape)" || {
  echo "UNMEASURED: no scratch directory could be made, so the store was never copied."
  exit 2
}
trap 'rm -rf "${COPY_DIR}"' EXIT
for ext in "" "-wal" "-shm"; do
  [[ -f "${STORE}${ext}" ]] && cp "${STORE}${ext}" "${COPY_DIR}/live.store${ext}"
done

python3 - "${COPY_DIR}/live.store" "${ASOF}" <<'PY'
import plistlib
import re
import sqlite3
import sys
from datetime import date, timedelta

DB, ASOF = sys.argv[1], sys.argv[2]

# The hosts where the first path segment after /showdetails/ was MEASURED to be stable across every
# night of a run and opaque (not derived from the title). It is an allowlist rather than a pattern
# because the measurement is the licence: on tixr the same-looking segment is the title slugified plus a
# per-performance integer, so admitting it would let open-mic-8814 and open-mic-9102 join two different
# shows, which is #1847 arriving inside its own fix.
TOKEN_HOSTS = ("venuetix.com",)
TOKEN_PATH = re.compile(r"https?://([^/]+)/showdetails/([^/?#]+)")


def unarchive_strings(blob):
    """Every string inside an NSKeyedArchiver NSArray blob, or None where the blob could not be read.

    runNights and runSourceURLs are [String] and SwiftData stores them as archived blobs, so no SQL
    expression can read them and this is the only way in.

    None and [] are kept apart deliberately. An EMPTY list is a row that genuinely lists no nights, and
    falling back to its performanceDate ... runEndDate span is correct. A blob that would not DECODE is
    a row whose nights this command could not read, and spanning it silently would compute a group
    count over different data from the one the reader believes they are being given (L215). Every
    caller counts the Nones and the run prints the total.
    """
    if not blob:
        return []
    try:
        plist = plistlib.loads(blob)
    except Exception:
        return None
    objects = plist.get("$objects", [])

    def resolve(value):
        return objects[value.data] if isinstance(value, plistlib.UID) else value

    try:
        root = resolve(plist.get("$top", {}).get("root"))
    except (IndexError, AttributeError):
        return None
    if not isinstance(root, dict) or "NS.objects" not in root:
        return None
    return [v for v in (resolve(i) for i in root["NS.objects"]) if isinstance(v, str)]


def key_fields(natural_key):
    """The folded title and folded venue ScoutService wrote, read back out of the row's own key.

    The key is "foldedTitle|openingNight|foldedVenue" and the venue is taken as everything after the
    second separator, because a folded venue may itself contain one. None where the key is absent or
    is not that shape, which is counted and reported rather than dropping the row quietly: a row
    missing from every population changes every figure here and would say nothing.
    """
    if not natural_key:
        return None
    parts = natural_key.split("|")
    if len(parts) < 3:
        return None
    return parts[0], "|".join(parts[2:])


def span(performance_date, run_end_date):
    """The inclusive performanceDate ... runEndDate night set, for rows whose runNights is empty."""
    if not performance_date:
        return set()
    try:
        opening = date.fromisoformat(performance_date)
    except ValueError:
        return set()
    if not run_end_date:
        return {performance_date}
    try:
        closing = date.fromisoformat(run_end_date)
    except ValueError:
        return {performance_date}
    if closing < opening:
        return {performance_date}
    return {(opening + timedelta(days=n)).isoformat() for n in range((closing - opening).days + 1)}


def tokens_for(listing_url, run_urls):
    found = set()
    for url in ([listing_url] if listing_url else []) + list(run_urls):
        match = TOKEN_PATH.search(url or "")
        if match and any(match.group(1).endswith(host) for host in TOKEN_HOSTS):
            found.add(match.group(2))
    return found


try:
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    raw = db.execute(
        "select Z_PK, ZNATURALKEY, ZSTATUSRAW, ZPERFORMANCEDATE, ZRUNENDDATE, ZRUNNIGHTS,"
        " ZRUNSOURCEURLS, ZSOURCELISTINGURL from ZPROSPECT"
    ).fetchall()
except Exception as error:
    print(f"UNMEASURED: the store is there and could not be read ({error})")
    print("No figures are printed, because an unreadable store is not an empty one.")
    sys.exit(2)

rows = []
unreadable_keys = 0
unreadable_night_lists = 0
unreadable_url_lists = 0
for pk, natural_key, status, performance_date, run_end, nights_blob, urls_blob, listing in raw:
    fields = key_fields(natural_key)
    if fields is None:
        unreadable_keys += 1
        continue
    folded_title, folded_venue = fields

    decoded_nights = unarchive_strings(nights_blob)
    if decoded_nights is None:
        unreadable_night_lists += 1
        decoded_nights = []
    decoded_urls = unarchive_strings(urls_blob)
    if decoded_urls is None:
        unreadable_url_lists += 1
        decoded_urls = []

    rows.append({
        "pk": pk,
        "title": folded_title,
        "venue": folded_venue,
        "status": status,
        "performanceDate": performance_date,
        "runEndDate": run_end,
        "nights": set(decoded_nights) or span(performance_date, run_end),
        "tokens": tokens_for(listing, decoded_urls),
    })

# A venue that stamps ONE token across its whole season would otherwise fuse the season into one card.
# So a token appearing under more than one folded title at one venue key is discarded outright, for
# every row holding it. It is deliberately a cheap deterministic rule rather than a judgement: it costs
# nothing while no venue does this, and refuses the failure on the day one starts.
seen_titles = {}
for row in rows:
    for token in row["tokens"]:
        seen_titles.setdefault((token, row["venue"]), set()).add(row["title"])
poisoned = {token for (token, _venue), titles in seen_titles.items() if len(titles) > 1}
for row in rows:
    row["tokens"] = row["tokens"] - poisoned


def cluster(members, use_tokens):
    """Groups inside one bucket, plus the pairs refused, by night-set intersection and token equality."""
    parent = {m["pk"]: m["pk"] for m in members}

    def find(pk):
        while parent[pk] != pk:
            parent[pk] = parent[parent[pk]]
            pk = parent[pk]
        return pk

    considered = []
    for index, left in enumerate(members):
        for right in members[index + 1:]:
            joined = bool(left["nights"] & right["nights"])
            if use_tokens and not joined:
                joined = bool(left["tokens"] & right["tokens"])
            if joined:
                parent[find(left["pk"])] = find(right["pk"])
            else:
                considered.append((left, right))

    groups = {}
    for member in members:
        groups.setdefault(find(member["pk"]), []).append(member)
    # A pair is only a near miss if the closure did not join it anyway through a third row.
    refused = [(a, b) for a, b in considered if find(a["pk"]) != find(b["pk"])]
    return list(groups.values()), refused


def shape(population, use_tokens=True):
    buckets = {}
    for row in population:
        buckets.setdefault((row["title"], row["venue"]), []).append(row)
    groups, refused = [], []
    for members in buckets.values():
        if len(members) == 1:
            continue
        found, missed = cluster(members, use_tokens)
        groups.extend(g for g in found if len(g) > 1)
        refused.extend(missed)
    return groups, refused


def report(name, population):
    groups, refused = shape(population, use_tokens=True)
    without_tokens, _ = shape(population, use_tokens=False)
    print(f"population={name}")
    print(f"  rows= {len(population)}")
    print(f"  groups= {len(groups)}")
    print(f"  joined= {sum(len(g) for g in groups)}")
    print(f"  largest= {max((len(g) for g in groups), default=0)}")
    print(f"  nearMisses= {len(refused)}")
    print(f"  tokenOnlyGroups= {len(groups) - len(without_tokens)}")
    for group in sorted(groups, key=len, reverse=True)[:3]:
        pks = ",".join(str(m["pk"]) for m in sorted(group, key=lambda m: m["pk"]))
        print(f"  largestGroupMembers= [{len(group)}] {group[0]['title'][:44]} :: pk {pks}")


def is_future(row):
    return max(row["performanceDate"] or "", row["runEndDate"] or "") >= ASOF


future = [r for r in rows if is_future(r)]
print(f"asof={ASOF} storeRows={len(rows)} discardedTokens={len(poisoned)}"
      f" unreadableKeys={unreadable_keys} unreadableNightLists={unreadable_night_lists}"
      f" unreadableUrlLists={unreadable_url_lists}")
if unreadable_keys or unreadable_night_lists or unreadable_url_lists:
    print("WARNING: some rows could not be read in full, so every figure below is over less than the"
          " store holds. An unreadable row is not an empty one.")
print("approximate= buckets are the shipped fold read back out of ZNATURALKEY; clustering is not Swift")
report("queue", [r for r in future if r["status"] != "dismissed"])
report("future", future)
report("archive", [r for r in rows if r["status"] == "dismissed"])
report("store", rows)
PY
