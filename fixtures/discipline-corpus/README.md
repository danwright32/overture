# Discipline signal corpus (#981)

A checked-in corpus of REAL event titles used to measure whether
`EventClassifier.detectDiscipline`'s hand-written word lists still resolve real rows by an
actual discipline signal, rather than dropping them to the `.other` fallback. Read by
`mac/OvertureTests/DisciplineSignalGuardTests.swift`.

Not a `docs/contracts.md` handoff contract: nothing writes or reads this file at runtime.

## Why this exists

Every discipline in `detectDiscipline` (dance, opera, theater, music, band, comedy) is
detected by a hand-written regex word list, and until #981 nothing measured those lists
against real data. #970 Phase 0 found the music list had only ever known choir words while the
function fell back to `.music`, so "no signal" and "music" were the same answer: 119 of 128
live prospects were tagged music, only 4 from an actual signal, and the whole suite stayed
green. Under #970, discipline now picks the geographic gate (music takes the strict
five-borough rule, everything else the looser one), so a stale list quietly files a show under
the wrong rule.

The guard measures the OUTCOME, not the word lists: over this corpus, what share of titles
resolve to the `.other` fallback. It deliberately does NOT re-list the classifier's own words
and assert they match (the "test compared against its own definition" trap this repo has hit).
It asserts the aggregate signal instead.

## Provenance

Every title here is a real live-store row. The first block came from the `#970` Phase 0 comments in
`mac/OvertureTests/EventClassifierTests.swift` (the "live titles", "Real rows from the live
store", and "Live high-tier rows" cases). The non-music block was pulled for #1079 directly from the
live Release store (`ZPROSPECT.ZGROUPNAME`, and `ZPRESENTER` where the store carried one), read from
a copy so the write-ahead log was included. Nothing here is invented. A small tail of genuinely
unreadable titles (for example the Under St Marks rows "A Man Called Paris", "Gigi in Punk",
"Honey, Drop It") carry no discipline signal and legitimately resolve to `.other`.

Each entry is a `title` and an optional `presenter` (the classifier reads both, joined, when
detecting discipline). A few titles hold a real em dash, written as the JSON escape (backslash u 2014) so the
file carries no literal dash character; the decoder restores the true title.

## The threshold, and why

The guard fails when the `.other` fallback share over this corpus rises above **0.35**.

The healthy classifier resolves this corpus at roughly 0.10 fallback (the genuinely unreadable
tail, now a smaller share of a larger corpus). The bar sits at 0.35, leaving headroom so a few
more genuinely-signal-free rows can be added without a false alarm, while any wholesale list
failure trips it. The defect this guard exists to catch (the music list going dark, as it was
before #970 Phase 0) sends the share far past 0.35 on this corpus, because only the rows that
carry a non-music signal survive. `DisciplineSignalGuardTests` confirms the bar is not vacuous by
also measuring a deliberately rot-heavy corpus and asserting it crosses the bar.

## Per-discipline coverage (#1079)

The aggregate fallback share is dominated by music, so it can stay green while a thin non-music
list rots: a handful of rows sliding to `.other` barely moves the whole-corpus number. #1079
seeds each thin list with real live-store rows and adds a second assertion,
`eachDisciplineIsExercisedByRealTitles`, that classifies every corpus row with the real classifier
and requires a per-discipline floor. A single non-music list going stale now trips the guard even
when the aggregate share does not.
<!-- LIVE-STORE-CLAIM verified=2026-07-17 measure="real rows per discipline in the live store, which set the corpus coverage floors" -->
The floors are the honest coverage found in the live store (313 prospects at the time of #1079), not
aspirations:

- music: 14
- theater: 10
- dance: 4
- band: 4
- comedy: 4
- opera: 2

Opera is the thinnest, at 2, because those are all the real opera rows the store holds.
<!-- LIVE-STORE-CLAIM verified=2026-07-17 measure="live rows available for band and comedy, which is why their floors sit at 4" -->
Dance, band, and comedy sit at 4 each for the same reason: the live store simply has few real rows
for them. These floors are minimums, so adding more real titles later is free, but any drop (a list
going dark, or coverage lost from the corpus) fails the assertion and is visible in the diff. The
assertion uses the real classifier and never restates a word list, so it cannot become a test
compared against its own definition.
