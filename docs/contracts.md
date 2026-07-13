# Local file contracts

Overture's pieces (the SwiftUI Mac app, a small booking-history importer script, and the Claude
Code workflows) never call each other directly. They hand off through fixed-shape JSON files in
`~/Library/Application Support/Overture/`, the same fire-and-forget boundary Downbeat uses for its
export. That boundary is the riskiest seam in the product: a format change on one side that the
other side has not caught up to fails silently in production (the #109 regression, where every
client was silently treated as cold).

A TypeScript engine (`src/lib/`, `scripts/scout/run-scout.ts`) used to mirror the app's scout,
classifier, matcher, ranker, and results writer as a second, parallel implementation. #493 retired
it once it was confirmed unused (the real scout has always run natively) and already drifting from
the Swift version it mirrored; only the booking-history importer (`scripts/import-history.ts`)
survives from that side.

The guard against that is a committed sample fixture per contract under `fixtures/`, asserted by a
test on each programmatic side (#113 established it for the Downbeat export; #157, #159, and #166 extended
it to the rest). When a format changes, update the fixture and every side's test in the same change;
a side that has not caught up then fails its test instead of drifting silently. Where one side is a
Claude Code workflow rather than code, there is no automated test for that side, so the fixture plus
the workflow's runbook is its spec.

## Catalog

| File (in app-support dir) | Writer | Reader | Version | Fixture | Tests |
| --- | --- | --- | --- | --- | --- |
| `downbeat-export.json` | Downbeat app (separate repo) | App (`DownbeatBridge.decode`) | 1, 2 | `fixtures/downbeat-export/` | `DownbeatExportContractTests.swift` |
| `overture-history.json` | Importer (`scripts/import-history.ts`) | App (`[HistoryRecord]`) | none (plain array; `email` added additively in #762) | `fixtures/local-history/` | `LocalHistoryContractTests.swift` |
| `overture-prep-queue.json` | App (`PrepQueueBuilder.encode`) | Prep run (workflow) | 1, 2, 3 | `fixtures/prep-queue/` | `PrepQueueContractTests.swift` |
| `overture-prep-results.json` | Prep run (workflow) | App (`PrepImporter` / `PrepResultsDecoder`) | 1, 2, 3, 4, 5, 6 | `fixtures/prep-results/` | `PrepResultsContractTests.swift` |
| `overture-prep-progress.json` | `prep-run.sh` (seeds it) + Prep run (workflow, updates it) | App (`PrepProgressDecoder`) | 1 | `fixtures/prep-progress/` | `PrepProgressContractTests.swift` |
| `overture-reply-classify-queue.json` | App (`ReplyClassifyQueueBuilder.encode`) | Classify+drafter run (workflow) | 1, 2, 3 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-reply-classify-results.json` | Classify+drafter run (workflow) | App (`ReplyClassifyResultsDecoder`) | 1, 2, 3 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-scout-page-<sourceId>.html` | App (`ScoutPagePin.write`, normalized + hashed) | Scout-extract run (workflow, reads it; never fetches the listings page itself) | n/a (HTML, not JSON) | none (the shape is a web page) | `SourceFetcherTests.swift` (normalization, hash, safe filename), `HandoffCleanupTests.swift` (retention) |
| `overture-scout-extract-queue.json` | App (`ScoutExtractQueueBuilder.encode`) | Scout-extract run (workflow) | 1, 2 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift` |
| `overture-scout-extract-results.json` | Scout-extract run (workflow) **and `scout-extract-run.sh`** (#856: it writes a `not_read` result for any queued source the run never came back with) | App (`ScoutExtractResultsDecoder`) | 1 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift`, `RunVanishedTests.swift`, `lib/results-guard.test.sh` |
| `overture-scout-extract-progress.json` | `scout-extract-run.sh` (seeds it) + scout-extract run (workflow, updates it) | App (`ScoutExtractProgressDecoder`) | 1 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift` |
| `overture-voice-feedback.json` | App (`VoiceFeedbackBuilder.encode`) | Prep run (workflow) | 1, 2, 3 | `fixtures/voice-feedback/` | `VoiceFeedbackContractTests.swift` |

`overture-uncertain.json` and `overture-refined.json` (the scout's round trip with a Claude
Code refine step for ambiguous classifications) were also retired in #493: confirmed never
actually completed in practice, and fully superseded by the app's own queue-review flow for
uncertain events. See Per contract below.

"App" is the SwiftUI Mac app (`mac/Overture/`). "Workflow" is a Claude Code run on Dan's Max
plan, not code.

## How long these files stay (#821)

Most of the files above are overwritten by the next run that produces them, so they never pile up.
Two are not, and both are kept on purpose:

- `overture-scout-page-<sourceId>.html`, the pinned page. Kept after its run too: when a source comes
  back with nonsense, it is the only record of what that page actually said. A watched source
  overwrites its own pin every read (the name is derived from its id), but a lead pin is written per
  pasted URL (`LeadIntakeModel.sourceId(for:)`), so those accumulate one per distinct link, and a
  source dropped from the watchlist orphans its pin.
- `<results>.corrupt`, the bytes of a results file that would not parse (`quarantine_unreadable_results`
  in `mac/scripts/lib/results-guard.sh`, #868). The only evidence of what that run really did.

`HandoffCleanup.sweep` deletes both at launch once they are more than 14 days old, next to the store
backup rotation and for the same reason. It is scoped by NAME first and age second: the handoff
directory also holds the booking history, the Gmail tokens, and Dan's voice guidance, so a sweep that
went by age alone would eventually take them and the loss would be silent. Nothing else in the folder
is a candidate at any age. It cannot reach a pin an in-flight run is about to read: those are minutes
old, never days.

## CI coverage

Phases 1 and 3 of #478 run the TypeScript and Swift suites on every PR, but that only closes
the core worry in #478 (a fixture-shape change merging green while silently breaking the
other side) for a contract with an automated test on every side that is code. Before #493,
exactly 3 contracts cleared that bar: `downbeat-export.json`, `overture-history.json`, and
`overture-results.json`, each with both a TypeScript and a Swift reader/writer. #493 retired
the TypeScript side of all three (confirmed unused and drifting); #669 went further for
`overture-results.json` and retired its Swift side too, once it was confirmed the native scout
writes straight to SwiftData and nothing has ever produced a file for the app to ingest, so that
contract no longer exists at all. `downbeat-export.json` and `overture-history.json` each still
has its own Swift XCTest against the shared fixture; none of the 8 contracts above now has two
independent code implementations to drift apart from, the cross-language risk Phases 1 and 3
guarded against for those no longer exists, there is nothing left to drift from.

The remaining 6 each have at least one side that is not code, by design: a Claude Code workflow
for all of them, plus `mac/scripts/prep-run.sh` (a shell script) on the writing side of
`overture-prep-progress.json`: the fixture plus the runbook (and, for that one, the script)
is deliberately the whole spec for that half (see Per contract below). Running the existing
suite for the code side in CI does not and cannot add coverage for a side that was never
meant to have an automated test.

`src/lib/fixtureShape.test.ts` (#509) adds a lightweight structural check for those other 6: it
decodes every version file committed under each fixture directory and asserts it still matches
its documented shape above (required fields, and which fields are additive vs. a hard replacement
between versions). This is not behavioral coverage, since the workflow side is not code to run,
but it does fail CI the moment a fixture stops matching its own spec, rather than only when
someone notices in production.

## Per contract

### `downbeat-export.json`

Downbeat's export of past clients, venues, committed bookings, and blocked dates, read by the app's
`DownbeatBridge.decode`. Previously also read by a TypeScript mirror (`parseDownbeatExport`),
retired in #493 since the real scout has always run natively; the app is now the only reader. The
canonical spec lives in the Downbeat repo at
`Downbeat/Downbeat/Integration/OvertureExport/CONTRACT.md`; if the Overture decoder ever drifts from
it, that file wins. Match on `clientId` (the stable org identity), never `clientDisplayName`.
`bookings` and `blockedDates` start empty and only fill from bookings made through the app going
forward.

### `overture-history.json`

Past booking history (`{ groupName, status }`), so repeat-client matching and do-not-contact
suppression work before the app has its own activity. Read by the app through `[HistoryRecord]`.
Previously also read by a TypeScript mirror (`loadLocalHistory`, which mapped the app's camelCase
shape to the matcher's snake_case, `{ group_name, status }`); skipping that mapping used to silently
read `undefined` and match nothing (the core of #104), which is why the shared fixture existed for
both readers (#166). That TypeScript reader was retired in #493; the app is now the only one.
`status` may be null; an unrecognized status reads as cold.

### `overture-results.json` (retired)

The ranked prospects the native scout upserts directly into SwiftData; there was never an
intermediate results file in the live path (`ScoutService.apply` writes straight to the store). The
TypeScript writer (`buildResultsFile`, `src/lib/resultsContract.ts`) that used to produce this file
for the app to ingest was retired in #493 once it was confirmed to be a reference mirror only, never
the live path. The app's own decoder and importer (`ResultsFileDecoder.decode` / `ResultsImporter`)
were kept in place afterward in case a file was ever produced by hand, but nothing ever did; #669
removed them too, since permanently dead code with no live writer anywhere isn't worth carrying.

### `overture-uncertain.json` and `overture-refined.json` (retired)

This was the TypeScript scout's round trip with a Claude-Code-assisted refine step for events its
rules left `uncertain`: it wrote `uncertain.json`, a human re-judged that slice via a Claude Code
session and wrote `refined.json`, and the scout merged the result back in. Retired in #493 after
confirming it was never actually completed in practice, an `uncertain.json` existed on disk from an
early manual test run, over two weeks stale, but no `refined.json` was ever produced. The native
app's queue view already surfaces any prospect with `confidence == uncertain &&
!confidenceReviewedByDan` for Dan to correct by hand (`ClassificationOverride.swift`), which fully
covers the same need, so the file hand-off was dropped rather than ported.

### `overture-prep-queue.json` and `overture-prep-results.json`

The app's round trip with the Prep run. The app writes `prep-queue.json` (the kept-undrafted
prospects that need a contact and a draft, plus, since #367, any prospect Dan explicitly flagged
for re-prep even though it already has one, via `PrepQueueBuilder.encode`); the Prep run reads it,
does the research and drafting, and writes `prep-results.json`; the app ingests that through
`PrepImporter`, moving prospects to `drafted` for Dan to review. The `naturalKey` is the opaque join
key the run must echo back verbatim, never rebuild. The Prep run is the counterpart side with no
automated test, so `fixtures/prep-queue/` and `fixtures/prep-results/` are its spec (see
`docs/prep-runbook.md`).

Queue version 2 (#586, #366 Phase 1) adds an optional `production` (`self` / `agency` / `unknown`,
from `Prospect.production`/#349) to each item, so the research step knows whether a show is
self-produced before deciding whether to pursue a named performer directly (#366 Phase 3). Additive;
`v1.json` stays byte-identical and still decodes with `production` absent (nil).

Queue version 3 (#367) adds an optional `reprepMode` (`draft_only` / `contacts_only`, absent means
both) to each item, set only when Dan asked to re-prep a prospect that already has a draft, so the
run knows to skip the corresponding half instead of redoing everything. Additive; `v1.json`/
`v2.json` stay byte-identical and still decode with it absent (nil).

Version 2 (#392) replaces the single `contact` object with a `contacts[]` array, one entry per party
the run found for the performance: the act plus at most one real presenting org, each labelled with a
`provenance` (`act` / `presenter`), and NEVER the host venue. `PrepImporter` ingests them as the
prospect's recipients (one separate email per recipient). The reader's tolerant gate (1 through 2)
still accepts the v1 single-`contact` file, which a custom `init(from:)` maps to a one-element
`contacts[]`; `v1.json` stays byte-identical as that proof, `v2.json` is the multi-contact spec.

Version 3 (#587, #366 Phase 2) adds `performer` to the `provenance` vocabulary: a named individual
performer on a self-produced show, distinct from `act` (a single-act waterfall result). Performer and
act are mutually exclusive per performance (never both used at once) and tie for first send position.
Purely additive to the `provenance` string; the reader's tolerant gate (1 through 3) still accepts
`v1.json`/`v2.json` unchanged, `v3.json` is the performer-contact spec.

Version 4 (#639, #634 Phase A) adds an optional `overrideBody` to a `contacts[]` entry: a direct,
second-person draft for that specific contact, meaningful only when its `provenance` is `performer`.
The shared `draft.body` stays third-person and keeps serving any act/presenter contact on the same
performance; a performer contact's own `overrideBody` is what actually gets sent to them instead
(`SendService`), so a named performer is addressed directly rather than described in the third person
they'd otherwise read about themselves in. Purely additive; the reader's tolerant gate (1 through 4)
still accepts `v1.json`/`v2.json`/`v3.json` unchanged, `v4.json` is the override-body spec.

Version 5 (#611) adds an optional `alreadyCoveredNote` on the result itself (a sibling of
`contacts`/`draft`, not per-contact): a fit-risk Prep's own research found, e.g. the org's site
explicitly names its own photographer. Set only from an explicit statement actually read on the
org's site, never inferred (the same STRICT-verification bar `docs/prep-runbook.md` already
applies to contact confidence). Never changes the show's fit score or tier; the app surfaces it as
a dismissible warning on the review card (`Prospect.alreadyCoveredNote`/`alreadyCoveredDismissed`)
so Dan decides himself whether to deprioritize or skip. Purely additive; the reader's tolerant gate
(1 through 5) still accepts `v1.json`/`v2.json`/`v3.json`/`v4.json` unchanged, `v5.json` is the
already-covered spec.

Version 6 (#363) adds an optional `sourceUrl` to a `contacts[]` entry: the page the run actually
read a high-confidence named contact from, so the app's confidence badge can link Dan through to
verify it himself instead of asking him to trust an unverifiable "high confidence" label. Only
ever meaningful when `confidence == "high"`; the app's own display gate
(`RecipientSnapshot.contactSourceLinkURL`) never shows a link for medium/low regardless of what's
set, so a stale or mistaken value on a lower-confidence contact is inert rather than misleading.
Distinct from the existing `formUrl`, which stays the `form_or_dm` contact's own actionable
submission link; the two fields never carry the same meaning. Purely additive; the reader's
tolerant gate (1 through 6) still accepts `v1.json`/`v2.json`/`v3.json`/`v4.json`/`v5.json`
unchanged, `v6.json` is the source-URL spec.

### `overture-reply-classify-queue.json` and `overture-reply-classify-results.json`

The app's round trip with the reply-classify run (#112). The app writes the queue (kept replies, each
with the captured `replyText`, via `ReplyClassifyQueueBuilder.encode`); the classify workflow reads
it, judges each reply's intent (`ReplyIntent`: interested / wants_to_book / has_question / declined),
and writes the results; the app ingests them and suggests the conversation state (auto). The
`naturalKey` is the opaque join key the run must echo back verbatim. The classify run is the
counterpart side with no automated test, so `fixtures/reply-classify/` is its spec (runbook added in
the workflow phase).

Version 2 (#392) adds an optional `recipientId` to each queue item and each result, so a reply is
tied to the specific recipient on the show it came from (a presenter reply and an act reply are then
classified independently instead of collapsing to the first replier). It is additive: the tolerant
gate (1 through 2) still accepts the v1 files (`queue.json` / `results.json`), where `recipientId`
decodes to nil; `queue-v2.json` / `results-v2.json` are the discriminator spec.

Version 3 (#420) folds the AI reply-DRAFTER into the same run: each result adds optional `draftSubject`
and `draftBody` (the contextual reply drafted in Dan's voice for that recipient), and the queue now
emits one item per replied recipient with `recipientId` populated. It also adds an optional
`performanceDate` to each queue item (#438) so a draft can NAME the known show date rather than ask for
it; absent only for a genuinely undated show. A draft must never request a field the queue already holds. The run reads Dan's distilled voice
guidance (`overture-voice-guidance.md`) and applies only distilled tendencies, never raw past pairs
(#119/#249 leak guard). The `intent` is consumed as a NON-BINDING hint (it never sets a binding
per-recipient outcome). Additive: the tolerant gate (1 through 3) still accepts v1/v2; `queue-v3.json`
/ `results-v3.json` are the spec.

### `overture-voice-feedback.json`

How Dan revises drafts, so the Prep drafter learns his voice over time (#241 / #119). The app writes
it when a Prep run launches (`PrepQueueService.startPrep`, best-effort so a feedback-write failure
never blocks the run); the Prep workflow reads it (wired by #242). One-sided: the reader is a Claude
Code workflow with no automated test, so `fixtures/voice-feedback/` plus the prep runbook is its spec.
Only HIGH-SIGNAL pairs are written: a prospect Dan substantively edited (`originalDraftBody`, captured
in #240) AND sent (`sentBody`, frozen at send), where the sent copy still differs from the AI original
by more than a near-revert/typo (`VoiceFeedbackBuilder.minEditDistance`). Newest first, capped at
`maxPairs` (20), so a few trivial or stale edits can't dominate the drafter's context. The distiller
(#242) must anonymize before reusing: the bodies carry org/venue/contact specifics that are NOT
transferable voice and must never leak into other drafts.

Version 2 (#392) adds an optional `outcomeRecipientId` to each pair, attributing the outcome to the
recipient who earned it (the booked one, else the first replier). The drafted body is shared across a
performance's recipients, so there is still exactly ONE cold pair per show; the discriminator only
credits the win, it does not duplicate the body. Additive: `v1.json` stays byte-identical (its
`outcomeRecipientId` decodes to nil), `v2.json` is the new spec.

Version 3 (#463) adds an optional `kind` to each pair: `"reply"` for an inbound-reply Dan rewrote and
committed (sent via Overture or copied out to Gmail), absent/nil for a cold opener. Reply pairs are
PER RECIPIENT (each contact's reply is its own lesson, so a show can contribute several), captured the
same way as the cold path: `Recipient.originalReplyDraftBody` (snapshotted on the first substantive
edit) versus `Recipient.sentReplyBody` (frozen at commit), gated on the same `minEditDistance`. Cold
and reply pairs share the one `maxPairs` cap, winners first. The distiller should treat a reply pair's
register (short, responsive) separately from a cold opener. Additive: `v1.json`/`v2.json` stay
byte-identical (their `kind` decodes to nil = cold), `v3.json` is the new spec.
