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

Every title here is a real live-store row, cited as such in the `#970` Phase 0 comments in
`mac/OvertureTests/EventClassifierTests.swift` (the "live titles", "Real rows from the live
store", and "Live high-tier rows" cases). Nothing here is invented. The mix is faithful to the
live store's real shape: overwhelmingly music, with a small tail of genuinely unreadable titles
(for example the Under St Marks rows "A Man Called Paris", "Gigi in Punk", "Honey, Drop It")
that carry no discipline signal and legitimately resolve to `.other`.

Each entry is a `title` and an optional `presenter` (the classifier reads both, joined, when
detecting discipline).

## The threshold, and why

The guard fails when the `.other` fallback share over this corpus rises above **0.35**.

The healthy classifier resolves this corpus at roughly 0.21 fallback (the genuinely unreadable
tail). The bar sits at 0.35, leaving headroom so a few more genuinely-signal-free rows can be
added without a false alarm, while any wholesale list failure trips it. The defect this guard
exists to catch (the music list going dark, as it was before #970 Phase 0) sends the share to
roughly 0.84 on this corpus, because only the two choir/chorus rows and the one theater row
survive: far past 0.35. `DisciplineSignalGuardTests` confirms the bar is not vacuous by also
measuring a deliberately rot-heavy corpus and asserting it crosses the bar.

## Known coverage gap (for Dan, not fixed here)

The live store is overwhelmingly music, so this corpus mostly exercises the music list, which
is the list the defect actually hit and the dominant bucket. The dance, opera, theater, band,
and comedy lists are thinly represented here (theater has one real row, the others none),
purely because the live store holds few or no real rows for them. The guard's power over those
lists is therefore limited by the real distribution. Expanding coverage there (seeding real
dance/opera/band/comedy titles as they appear in the store) is a follow-up, not part of #981,
which is the GUARD, not a re-tuning or expansion of the lists.
