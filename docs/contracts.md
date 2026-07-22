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
| `overture-prep-queue.json` | App (`PrepQueueBuilder.encode`) | Prep run (workflow) | 1, 2, 3, 4, 5 | `fixtures/prep-queue/` | `PrepQueueContractTests.swift` |
| `overture-prep-results.json` | Prep run (workflow) | App (`PrepImporter` / `PrepResultsDecoder`) | 1, 2, 3, 4, 5, 6 | `fixtures/prep-results/` | `PrepResultsContractTests.swift` |
| `overture-prep-progress.json` | `prep-run.sh` **only**: seeds it, then derives every update from `overture-prep-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`, the same helper scout uses). #1023: the workflow never writes this file; it rewrites the results file incrementally and the script counts its entries, so a run that forgets to self-report can no longer leave the count wrong. | App (`PrepProgressDecoder`) | 1 | `fixtures/prep-progress/` | `PrepProgressContractTests.swift`, `lib/progress-watcher.test.sh` |
| `prep-cancel` | App (`PrepQueueService.requestCancel`) writes it to ask a running Prep run to stop; App (`startPrep`) clears any stale one before a fresh run | `prep-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `PrepReplyCancelServiceTests.swift`, `lib/scout-cancel.test.sh`, `PrepReplyRunnerWiringGuardTests.swift` |
| `overture-reply-classify-queue.json` | App (`ReplyClassifyQueueBuilder.encode`) | Classify+drafter run (workflow) | 1, 2, 3 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-reply-classify-results.json` | Classify+drafter run (workflow, rewrites it after every item, not only once at the end; #1081) | App (`ReplyClassifyResultsDecoder`) | 1, 2, 3 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-reply-classify-progress.json` | `reply-classify-run.sh` **only**: seeds it, then derives every update from `overture-reply-classify-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`, the same helper prep and scout use). #1081: the workflow never writes this file; it rewrites the results file incrementally and the script counts its entries, so a run that forgets to self-report can no longer leave the count wrong. | App (`ReplyClassifyProgressDecoder`) | 1 | `fixtures/reply-classify-progress/` | `ReplyClassifyProgressContractTests.swift`, `lib/progress-watcher.test.sh` |
| `reply-classify-cancel` | App (`ReplyClassifyService.requestCancel`) writes it to ask a running reply-classify run to stop; App (`startClassify`) clears any stale one before a fresh run | `reply-classify-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `PrepReplyCancelServiceTests.swift`, `lib/scout-cancel.test.sh`, `PrepReplyRunnerWiringGuardTests.swift` |
| `overture-scout-page-<sourceId>.html` | App (`ScoutPagePin.write`, normalized + hashed) | Scout-extract run (workflow, reads it; never fetches the listings page itself) | n/a (HTML, not JSON) | none (the shape is a web page) | `SourceFetcherTests.swift` (normalization, hash, safe filename), `HandoffCleanupTests.swift` (retention) |
| `overture-scout-extract-queue.json` | App (`ScoutExtractQueueBuilder.encode`) | Scout-extract run (workflow) | 1, 2 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift` |
| `overture-scout-extract-results.json` | Scout-extract run (workflow, rewrites it after every item, not only once at the end; #1015) **and `scout-extract-run.sh`** (#856: it writes a `not_read` result for any queued source the run never came back with) | App (`ScoutExtractResultsDecoder`) | 1, 2, 3 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift`, `RunVanishedTests.swift`, `lib/results-guard.test.sh` |
| `overture-scout-extract-progress.json` | `scout-extract-run.sh` **only**: seeds it, then derives every update from `overture-scout-extract-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`). #1015: the workflow never writes this file; a run that forgets to self-report (2026-07-16) can no longer leave the count wrong. | App (`ScoutExtractProgressDecoder`) | 1 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift`, `lib/progress-watcher.test.sh`, `ScoutProgressWiringGuardTests.swift` |
| `scout-extract-cancel` | App (`ScoutExtractService.requestCancel`) writes it to ask a running read to stop; App (`startExtract`) clears any stale one before a fresh run | `scout-extract-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `ScoutCancelTests.swift`, `lib/scout-cancel.test.sh`, `ScoutCancelWiringGuardTests.swift` |
| `overture-voice-feedback.json` | App (`VoiceFeedbackBuilder.encode`) | Prep run (workflow) | 1, 2, 3 | `fixtures/voice-feedback/` | `VoiceFeedbackContractTests.swift` |
| `overture-recent-openers.json` | App (`RecentOpenersBuilder.encode`) | Prep run (workflow) | 1 | `fixtures/recent-openers/` | `RecentOpenersContractTests.swift` |

`PageVerdict` (the token in each scout-extract result's `verdict` field) added `incomplete_extraction`
in #1012: a page the run could only read part of. Its events are ingested but its source's content
hash is deliberately never latched, so the next scout re-reads the page rather than treating it as
finished.

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

Queue version 5 (#5) adds an optional `experimentArmInstruction` to each item: the opener archetype
this item MUST use (one of `reason-first` / `credential-first` / `observation-first` /
`direct-intent`), copied from the app-assigned `Prospect.assignedArm` when the prospect belongs to an
active A/B experiment. Absent (the common case, no active experiment) means the drafter uses the
normal #362 opener rotation. The runbook (`docs/prep-runbook.md` §2) gives this field PRECEDENCE over
that rotation, so an experiment item genuinely randomizes what is produced. Additive; `v1.json`
through `v4.json` stay byte-identical and still decode with it absent (nil). (Version 4, #1122, added
`runEndDate` + `openingNightPassed`; it had no paragraph here before this one.)

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

### `overture-recent-openers.json`

The opening sentences recent drafts already used, so a Prep run can steer away from them and separate
small batches drafted on different days don't independently converge on the same handful of openers
(#730, extending #362's within-run rule across runs). The app writes it when a Prep run launches
(`PrepQueueService.startPrep`, best-effort so a write failure never blocks the run, alongside the
voice-feedback handoff); the Prep workflow reads it (docs/prep-runbook.md §2). One-sided: the reader is
a Claude Code workflow with no automated test, so `fixtures/recent-openers/` plus the prep runbook is
its spec. Each `openers[]` entry carries the opaque `naturalKey`, `discipline`, the `opener` (the first
sentence of a recently drafted body, derived from `originalDraftBody` when present else `draftBody`),
and the `usedAt` timestamp it is ordered by. Newest first, deduped by opener text, capped at
`maxOpeners` (15). Like the voice-feedback file, it carries real body text: it is a list of shapes to
AVOID reusing, and the runbook forbids lifting any specific out of it into a draft.

### `overture-scout-extract-results.json`

Written by the scout-extract run (a Claude Code workflow, so it has no automated test of its own) and
read by `ScoutExtractResultsDecoder`. `fixtures/scout-extract/` plus `docs/scout-extract-runbook.md`
are its spec. One rule dominates: `sourceId` is opaque and must be echoed back verbatim, never rebuilt,
because a reconstructed id matches nothing on the way home and the work vanishes with no error.

Version 2 (#970) adds an optional `location` to each event: where the page says the show is, VERBATIM,
exactly as written. It is the only way the app can learn where a show is, and it exists because the
alternatives were measured against real data and do not work:

- The **venue** cannot answer it reliably. A venue can end up carrying a city when a source page bakes a
  full street address into it (#1030: "The Players Theatre, 115 MacDougal Street, New York, NY"), but
  that is an artifact of the address, not a location report, and it does not help the touring artist
  pages this serves, which frequently name no venue at all (`smokeringquartet.com/gigs` publishes a city
  and never a room).
- The **title** cannot answer it either, except on Carnegie's NYO tour convention
  (`NYO Jazz in Beijing, China`), which no other source shares.

The run must not normalize it. What pages actually write ranges from `Louisville, KY` to
`Baltimore, Maryland` to `Harrogate, UK` to a bare `Amsterdam` to `southern Norway` to
`Orange County, Santa Barbara, Pasadena, and Santa Monica` to a full street address. Deciding what any
of that MEANS is a resolver's job in the app; the wire's job is to carry the page's own words intact.

**Two consumers, different tolerances (#1065).** Once in the app (stored as `Prospect.location`), this
one raw string feeds TWO independent readers, and a change to how it is populated or normalized has to
satisfy BOTH: the **geography gate** (`EventPlace.resolve`) places or refuses a show and handles the
messier shapes above on purpose, while the **display fallback** (`VenueDisplay.resolve`'s
`safeCityStateLine`, #1030) is stricter and shows it on the card ONLY when it is already a clean
city/state shape, rejecting anything address-shaped. They have NOT diverged far enough to warrant
splitting `location` into two derived values. `LocationTwoConsumersGuardTests` pins both tolerances
against shared inputs so a change that silently diverges them turns that guard red.

Absent means the page named no place, which is common and is NOT an error: an unknown place is a show
to keep and flag, never one to hide. Unlike `venue`, a missing `location` does not drop the event.

Additive, and the version bump is **documentation of the shape change, not a behavioral gate**: nothing
reads `version`, and because `location` is optional a v1 file decodes unchanged and simply carries no
locations. That is the same outcome as a v2 run that looked and found none. The app cannot tell those
apart and does not need to, so do not add a version check to invent the distinction. `results-v1.json`
stays byte-identical as that proof; `results-v2.json` is the location spec, and its cases are real rows
from real pages.

Version 3 (#897) adds an optional `monthsCovered` to each result: which of the pinned page's stitched
month sections (the `<!-- overture-month ... -->` markers #858 writes) the run actually read. It exists
to close a data-loss hole that opens the moment calendar pagination is turned on for the watchlist. A
stitched page holds several months under one `sourceId` and one hash; a run that reads three of the four
sections does not fail, it just returns fewer shows, and on a reconciling feed "fewer shows" reads as
"those shows were cancelled". Nothing in the run's own verdict can tell "the calendar shrank" from "I
read three of the four months", because a show the run never returned is not one it rejected. The app
holds the truth the run cannot fake (the set of months it stitched into the pin, persisted on the source
as `pendingPageMonths`), compares it to `monthsCovered`, and treats a shortfall as a NAMED incomplete
read (`SweepCoverage` downgrades the effective verdict to `incomplete_extraction`): the shows the run did
find still land, but the page is not marked finished and no feed health is recorded, so a short sweep can
never mark a live show gone. Purely additive, and like `location` the version bump is documentation, not
a behavioral gate: nothing reads `version`, and an absent `monthsCovered` (a v1/v2 file, or any
single-month page) makes the check inert, which is exactly its dormant state on the watchlist today
(`monthHorizon` is still 1). `results-v1.json`/`results-v2.json` stay byte-identical as that proof;
`results-v3.json` is the coverage spec.

Version 4 (#1174) adds an optional `seriesId` to each event: the source's own production id, when it
publishes one that ties several performances of one show together. VenueTix (Green Room 42) tags every
night of a run with a shared id, and without carrying it a six-night run became six separate prospects to
review. The wire carries the id VERBATIM; the grouping rule lives in the app, not the decoder. Every event
that shares a non-null `seriesId` is one production, and `RunGrouping` collapses those nights into a single
prospect that renders an opening-to-closing span, REGARDLESS of the usual same-venue, close-together-dates
rule (a residency's nights can be weeks apart). It is the authoritative "these are one show" signal, so it
does not depend on the titles matching. Purely additive, and like `location` and `monthsCovered` the
version bump is documentation, not a behavioral gate: nothing reads `version`, and an absent `seriesId`
(a v1/v2/v3 file, or any source that publishes no production id, which is nearly all of them) decodes
unchanged and simply never collapses, which is the same outcome as before this field existed.
`results-v1.json`/`results-v2.json`/`results-v3.json` stay byte-identical as that proof; `results-v4.json`
is the seriesId spec, a three-night run sharing one id plus a standalone show that carries none.
