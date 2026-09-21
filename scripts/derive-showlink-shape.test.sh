#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty, fixture_scratch_dir (#2501).
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# Coverage for derive-showlink-shape.sh, the command that re-derives milestone 62's grouping figures
# from a store (#3772). It is driven against THROWAWAY SQLite stores this fixture builds, never against
# Dan's live one, so it runs anywhere including CI and an agent worktree, and so each case can pin one
# rule of the grouping in isolation.
#
# The two load-bearing cases are `no store` and `unreadable store`. Every figure this command prints is
# quoted in a discussion, an issue body or a PR, so a run that measured NOTHING must never print a zero
# that reads like a measurement (L98, L11). If either stops being separable from a real derivation of an
# empty store, this fixture goes red.
#
# The next most load-bearing is `disjoint nights are refused`: it is the Tuudr counter-example (pk 78
# against pk 1348, one folded title, one venue, 20 days apart, no shared night), which the milestone's
# whole safety argument says must NEVER auto-join.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVE="${SCRIPT_DIR}/derive-showlink-shape.sh"
WORK="$(fixture_scratch_dir derive-showlink-shape)"

# Builds a throwaway store from rows given as TSV on stdin, one row per line:
#   pk <TAB> foldedTitle <TAB> openingNight <TAB> foldedVenue <TAB> status <TAB> performanceDate
#      <TAB> runEndDate <TAB> nights(comma separated, may be empty) <TAB> sourceListingURL
#      <TAB> firstSeenAt (an ISO date, or empty for a row that carries none)
# The natural key is assembled here the way ScoutService writes it, "title|date|venue", because the
# derivation reads the fold back OUT of that key rather than re-folding anything itself.
make_store() {
  local path="$1"
  local rows="${path}.rows"
  # `python3 - <<'PY'` takes its PROGRAM from stdin, so the rows cannot also arrive that way: they go
  # to a file first and the program is handed its path. Reading both from stdin silently builds an
  # EMPTY store, and an empty store answers 0 to every question, which reads as a real measurement.
  cat > "${rows}"
  rm -f "${path}"
  python3 - "${path}" "${rows}" <<'PY'
import sqlite3, sys, plistlib
from datetime import datetime, timezone
path = sys.argv[1]
db = sqlite3.connect(path)
db.execute("""create table ZPROSPECT (
  Z_PK integer primary key, ZNATURALKEY text, ZSTATUSRAW text, ZPERFORMANCEDATE text,
  ZRUNENDDATE text, ZRUNNIGHTS blob, ZRUNSOURCEURLS blob, ZSOURCELISTINGURL text,
  ZGROUPNAME text, ZVENUE text, ZFIRSTSEENAT real)""")


def archive(values):
    """An NSKeyedArchiver NSArray of strings, the shape SwiftData writes for [String]."""
    if not values:
        return None
    objs = ["$null", {"NS.objects": [plistlib.UID(i + 2) for i in range(len(values))],
                      "$class": plistlib.UID(len(values) + 2)}]
    objs.extend(values)
    objs.append({"$classname": "NSArray", "$classes": ["NSArray", "NSObject"]})
    return plistlib.dumps({"$version": 100000, "$archiver": "NSKeyedArchiver",
                           "$top": {"root": plistlib.UID(1)}, "$objects": objs},
                          fmt=plistlib.FMT_BINARY)


for line in open(sys.argv[2]):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    # Padded rather than unpacked strictly: a trailing empty field is a trailing TAB, which editors and
    # tooling strip without trace, and a fixture that dies on invisible whitespace is a fixture that
    # reports a store-building failure as a grouping answer of zero.
    parts = (line.split("\t") + [""] * 10)[:10]
    pk, title, opening, venue, status, perf, end, nights, url, first_seen = parts
    # Core Data stores a TIMESTAMP as seconds since 2001-01-01 UTC, so the fixture writes what the real
    # store holds rather than an ISO string the command would never meet.
    seen = None
    if first_seen.strip():
        seen = (datetime.fromisoformat(first_seen.strip()).replace(tzinfo=timezone.utc)
                - datetime(2001, 1, 1, tzinfo=timezone.utc)).total_seconds()
    db.execute("insert into ZPROSPECT values (?,?,?,?,?,?,?,?,?,?,?)",
               (int(pk), f"{title}|{opening}|{venue}", status, perf or None, end or None,
                archive([n for n in nights.split(",") if n]), archive([url] if url else []),
                url or None, title, venue, seen))
db.commit()
PY
}

# Prints the value of one field for one population from a derivation's output, so a case asserts on a
# number rather than on a whole block of text.
# The same, for a field on the header line that stands over the whole run rather than one population.
field_for_header() {
  local out="$1" field="$2"
  echo "${out}" | tr ' ' '\n' | awk -F= -v f="${field%=}" '$1 == f { print $2 }'
}

field_for() {
  local out="$1" population="$2" field="$3"
  echo "${out}" | awk -v p="${population}" -v f="${field}" '
    $0 ~ "^population="p { inpop=1; next }
    inpop && $0 ~ "^population=" { inpop=0 }
    inpop && $1 == f { print $2 }'
}

# --- a run that measured nothing never reads as a measurement ---------------------------------------

out="$("${DERIVE}" --store "${WORK}/does-not-exist.store" 2>&1)"
status=$?
assert_eq "no store exits 3, not 0" "3" "${status}"
assert_contains "no store says so in words" "${out}" "NO LIVE STORE"
assert_not_contains "no store never prints a groups figure" "${out}" "groups="

printf 'not a sqlite database at all\n' > "${WORK}/corrupt.store"
out="$("${DERIVE}" --store "${WORK}/corrupt.store" 2>&1)"
status=$?
assert_eq "an unreadable store exits 2 UNMEASURED" "2" "${status}"
assert_contains "an unreadable store says UNMEASURED" "${out}" "UNMEASURED"
assert_not_contains "an unreadable store never prints a groups figure" "${out}" "groups="

# --- the night rule ---------------------------------------------------------------------------------

make_store "${WORK}/intersect.store" <<'ROWS'
1	we are happy to serve you	2026-10-02	the players theatre	new	2026-10-02	2026-10-05
2	we are happy to serve you	2026-10-04	the players theatre	new	2026-10-04	2026-10-08
ROWS
out="$("${DERIVE}" --store "${WORK}/intersect.store" --asof 2026-09-19)"
assert_eq "two rows sharing a night are one group" "1" "$(field_for "${out}" queue groups=)"
assert_eq "that group holds both rows" "2" "$(field_for "${out}" queue largest=)"
assert_eq "an intersecting pair is never a near miss" "0" "$(field_for "${out}" queue nearMisses=)"

# The Tuudr shape: one folded title, one venue key, 20 days apart, nothing shared.
make_store "${WORK}/disjoint.store" <<'ROWS'
78	tuudr piano competition gala	2026-10-11	weill recital hall	new	2026-10-11
1348	tuudr piano competition gala	2026-10-31	weill recital hall	new	2026-10-31
ROWS
out="$("${DERIVE}" --store "${WORK}/disjoint.store" --asof 2026-09-19)"
assert_eq "disjoint nights in one bucket are never joined" "0" "$(field_for "${out}" queue groups=)"
assert_eq "and are reported as a near miss for Dan to settle" "1" "$(field_for "${out}" queue nearMisses=)"

make_store "${WORK}/venue.store" <<'ROWS'
1	open mic	2026-10-02	asylum nyc	new	2026-10-02
2	open mic	2026-10-02	the cutting room	new	2026-10-02
ROWS
out="$("${DERIVE}" --store "${WORK}/venue.store" --asof 2026-09-19)"
assert_eq "one title on one night at two venues is never one group" "0" "$(field_for "${out}" queue groups=)"
assert_eq "and is not a near miss either, being a different bucket" "0" "$(field_for "${out}" queue nearMisses=)"

# A joins B and B joins C while A and C share nothing: the closure is what makes them one card.
make_store "${WORK}/closure.store" <<'ROWS'
1	the infinite wrench	2026-10-02	asylum nyc	new	2026-10-02		2026-10-02,2026-10-03
2	the infinite wrench	2026-10-03	asylum nyc	new	2026-10-03		2026-10-03,2026-10-09
3	the infinite wrench	2026-10-09	asylum nyc	new	2026-10-09		2026-10-09
ROWS
out="$("${DERIVE}" --store "${WORK}/closure.store" --asof 2026-09-19)"
assert_eq "a bridging night makes three rows one group" "1" "$(field_for "${out}" queue groups=)"
assert_eq "and all three are in it" "3" "$(field_for "${out}" queue largest=)"

# --- the token arm, and the three refusals that ride with it -----------------------------------------

make_store "${WORK}/token.store" <<'ROWS'
397	nihao broadway	2026-10-11	the green room 42	new	2026-10-11			https://thegreenroom42.venuetix.com/showdetails/zGbL9oImamvWwHF3ti5i/111
1114	nihao broadway	2026-10-29	the green room 42	new	2026-10-29			https://thegreenroom42.venuetix.com/showdetails/zGbL9oImamvWwHF3ti5i/222
ROWS
out="$("${DERIVE}" --store "${WORK}/token.store" --asof 2026-09-19)"
assert_eq "a shared venuetix token joins disjoint nights" "1" "$(field_for "${out}" queue groups=)"
assert_eq "and the token arm is counted as the reason" "1" "$(field_for "${out}" queue tokenOnlyGroups=)"

# A venue that stamps one token across its season must never fuse the season into one card.
make_store "${WORK}/poisoned.store" <<'ROWS'
1	first show	2026-10-11	the green room 42	new	2026-10-11			https://thegreenroom42.venuetix.com/showdetails/seasonToken/111
2	first show	2026-10-29	the green room 42	new	2026-10-29			https://thegreenroom42.venuetix.com/showdetails/seasonToken/222
3	second show	2026-10-12	the green room 42	new	2026-10-12			https://thegreenroom42.venuetix.com/showdetails/seasonToken/333
ROWS
out="$("${DERIVE}" --store "${WORK}/poisoned.store" --asof 2026-09-19)"
assert_eq "a token under two folded titles at one venue joins nothing" "0" "$(field_for "${out}" queue groups=)"

# A tixr slug is the title slugified plus a per-performance integer, so it is never identity evidence.
make_store "${WORK}/tixr.store" <<'ROWS'
1	open mic	2026-10-11	asylum nyc	new	2026-10-11			https://www.tixr.com/groups/asylum/events/open-mic-8814
2	open mic	2026-10-29	asylum nyc	new	2026-10-29			https://www.tixr.com/groups/asylum/events/open-mic-9102
ROWS
out="$("${DERIVE}" --store "${WORK}/tixr.store" --asof 2026-09-19)"
assert_eq "a tixr slug is never a production token" "0" "$(field_for "${out}" queue groups=)"

# --- the listing links that carry more than one show (#4078) ------------------------------------------
#
# Two ingest arms join a stored row to an incoming listing because they SHARE A URL, `matchByAnyRunURL`
# on any shared run URL and `matchByStableSource` on the listing URL plus date plus venue. Both are
# guarded by a title predicate and nothing else, and neither can see how ambiguous the URL it matched on
# actually is. This section is the reachable population for both, which until now existed only inside an
# ad hoc script somebody wrote to answer #4068.

make_store "${WORK}/ambiguous-url.store" <<'ROWS'
1	max davidson strangers	2026-10-11	soho playhouse	dismissed	2026-10-11			https://ci.ovationtix.com/35583
2	max davidson does new material	2026-10-29	soho playhouse	new	2026-10-29			https://ci.ovationtix.com/35583
3	a third billing entirely	2026-11-02	soho playhouse	new	2026-11-02			https://ci.ovationtix.com/35583
ROWS
out="$("${DERIVE}" --store "${WORK}/ambiguous-url.store" --asof 2026-09-19)"
assert_contains "a URL held under several folded titles is named" "${out}" "ci.ovationtix.com/35583"
assert_contains "beside how many titles hold it" "${out}" "[3 titles]"
assert_contains "and the titles themselves, since the count alone cannot be acted on" \
  "${out}" "max davidson strangers"
assert_contains "the section says what it cannot see, which is a URL that moved across TIME" \
  "${out}" "across TIME"

# The control, and it is the half that matters: an over match here would report every ordinary
# per performance link as ambiguous, and the section would be ignored within a week (L104, L36).
make_store "${WORK}/unambiguous-url.store" <<'ROWS'
1	one show	2026-10-11	soho playhouse	new	2026-10-11			https://ci.ovationtix.com/11111
2	one show	2026-10-29	soho playhouse	new	2026-10-29			https://ci.ovationtix.com/22222
ROWS
out="$("${DERIVE}" --store "${WORK}/unambiguous-url.store" --asof 2026-09-19)"
assert_contains "a store with no ambiguous link says so positively" "${out}" "ambiguousListingURLs= 0"
assert_not_contains "and names no URL" "${out}" "ci.ovationtix.com/11111"

# One URL, one title, several rows is the ORDINARY shape of a run and must never be flagged: the two
# arms joining on it is exactly what they are for.
make_store "${WORK}/one-title-url.store" <<'ROWS'
1	a weekly series	2026-10-11	the players theatre	new	2026-10-11			https://theplayerstheatre.com/show-schedule.html
2	a weekly series	2026-10-18	the players theatre	new	2026-10-18			https://theplayerstheatre.com/show-schedule.html
ROWS
out="$("${DERIVE}" --store "${WORK}/one-title-url.store" --asof 2026-09-19)"
assert_contains "one title on a shared URL is not ambiguous" "${out}" "ambiguousListingURLs= 0"

# --- an input this command could not read is never counted as an ordinary empty one -------------------
#
# Both of these fall back to something plausible: a runNights blob that will not decode falls back to the
# performanceDate ... runEndDate span, and a row whose natural key has no separators is dropped from every
# population. Either is a figure quietly computed over different data from the one the reader believes,
# on a command whose whole output is numbers that get quoted into issue bodies and plans (L215, L11).

make_store "${WORK}/badblob.store" <<'ROWS'
1	a show	2026-10-02	asylum nyc	new	2026-10-02	2026-10-05
ROWS
python3 - "${WORK}/badblob.store" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("update ZPROSPECT set ZRUNNIGHTS = ? where Z_PK = 1", (b"not an archive at all",))
db.commit()
PY
out="$("${DERIVE}" --store "${WORK}/badblob.store" --asof 2026-09-19)"
assert_eq "a night list that will not decode is counted, not silently spanned" "1" \
  "$(field_for_header "${out}" unreadableNightLists=)"

make_store "${WORK}/badkey.store" <<'ROWS'
1	a show	2026-10-02	asylum nyc	new	2026-10-02	2026-10-05
ROWS
python3 - "${WORK}/badkey.store" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("update ZPROSPECT set ZNATURALKEY = 'no separators here' where Z_PK = 1")
db.commit()
PY
out="$("${DERIVE}" --store "${WORK}/badkey.store" --asof 2026-09-19)"
assert_eq "a row whose key cannot be read is counted, not silently dropped" "1" \
  "$(field_for_header "${out}" unreadableKeys=)"
assert_eq "and it is not counted among the rows that were grouped" "0" \
  "$(field_for "${out}" store rows=)"

# --- the populations are separated, which is the whole of #3772's claim 3 -----------------------------

make_store "${WORK}/populations.store" <<'ROWS'
1	the infinite wrench	2026-10-02	asylum nyc	dismissed	2026-10-02	2026-10-05
2	the infinite wrench	2026-10-04	asylum nyc	dismissed	2026-10-04	2026-10-08
3	we are happy to serve you	2026-10-02	the players theatre	new	2026-10-02	2026-10-05
4	we are happy to serve you	2026-10-04	the players theatre	new	2026-10-04	2026-10-08
ROWS
out="$("${DERIVE}" --store "${WORK}/populations.store" --asof 2026-09-19)"
assert_eq "a dismissed group is not on the queue" "1" "$(field_for "${out}" queue groups=)"
assert_eq "the queue's largest card counts only its own rows" "2" "$(field_for "${out}" queue largest=)"
assert_eq "the archive carries the dismissed group" "1" "$(field_for "${out}" archive groups=)"
assert_eq "and the whole store carries both" "2" "$(field_for "${out}" store groups=)"

# A row whose opening night has passed but whose run is still playing is still the queue's business.
make_store "${WORK}/liverun.store" <<'ROWS'
1	a long run	2026-09-18	asylum nyc	new	2026-09-18	2026-12-24
ROWS
out="$("${DERIVE}" --store "${WORK}/liverun.store" --asof 2026-09-19)"
assert_eq "a run opening yesterday and closing in December is in queue scope" "1" \
  "$(field_for "${out}" queue rows=)"

# --- --dates: WHEN each member of a group arrived (#4033) --------------------------------------------
#
# The question this answers decides whether a duplicate is worth fixing at ingest, and on 2026-09-19 it
# reversed a conclusion: #3766's premise re-check said the store's duplicates were pre-fix residue minted
# before #1558 shipped, which was true of the group it measured and false of the store. Answering it meant
# patching a private copy of this script, which is exactly the figure-nobody-can-re-take this command
# exists to end.

make_store "${WORK}/dates.store" <<'ROWS'
1	the infinite wrench	2026-10-02	asylum nyc	dismissed	2026-10-02	2026-10-05			2026-07-23
2	the infinite wrench	2026-10-04	asylum nyc	dismissed	2026-10-04	2026-10-08			2026-09-03
3	we are happy to serve you	2026-10-02	the players theatre	new	2026-10-02	2026-10-05			2026-07-23
4	we are happy to serve you	2026-10-04	the players theatre	new	2026-10-04	2026-10-08			
5	a show stored once	2026-11-01	the cutting room	new	2026-11-01				2026-08-01
ROWS

out="$("${DERIVE}" --store "${WORK}/dates.store" --asof 2026-09-19 --dates)"
assert_contains "--dates prints a member's first sighting beside its pk" "${out}" "pk 1"
assert_contains "and the date it was first seen" "${out}" "2026-07-23"
assert_contains "and the later member's own date, which is the whole point" "${out}" "2026-09-03"
assert_contains "a row that carries no first sighting says so in words" "${out}" "not recorded"
assert_not_contains "a row stored once is in no group, so it is never listed" "${out}" "a show stored once"

# EVERY group, not the largest three: the default output caps the list and that cap is what hid the
# store-wide answer in the first place.
assert_contains "--dates lists the first group" "${out}" "the infinite wrench"
assert_contains "--dates lists the second group too" "${out}" "we are happy to serve you"
# #4021: the member line carries the row's own natural key, which is what ShowLink.Row.id is, so the
# shipped rule can be compared against this membership rather than against this count.
assert_contains "a member line carries the natural key" "${out}" \
  "key the infinite wrench|2026-10-02|asylum nyc"

# The two misreadings that produced #3766's wrong mechanism, said beside the dates rather than left for
# a reader to know (L11): firstSeenAt is not unconditionally a mint date, and ingestedAt is the LAST touch.
assert_contains "the output warns that a first sighting can have been rewritten" "${out}" "NaturalKeyVenueMigration"
assert_contains "and that ingestedAt is the last touch, not the first" "${out}" "ingestedAt"

# The default output is UNCHANGED, because its four populations are quoted in issue bodies.
plain="$("${DERIVE}" --store "${WORK}/dates.store" --asof 2026-09-19)"
assert_not_contains "without --dates nothing prints a member's date" "${plain}" "first seen"
assert_eq "without --dates the store figure is what it always was" "2" \
  "$(field_for "${plain}" store groups=)"
assert_eq "and --dates does not change it either" "2" "$(field_for "${out}" store groups=)"

rm -rf "${WORK}"

if [[ "${FAILURES:-0}" -eq 0 ]]; then
  echo "All derive-showlink-shape.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} derive-showlink-shape.sh fixture(s) failed." >&2
exit 1
