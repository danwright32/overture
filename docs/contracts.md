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
| `overture-shoot-history.json` | Importer (`scripts/import-shoot-history.ts`) | App (`ShootHistory`) | 1 | `fixtures/shoot-history/` | `ShootHistoryContractTests.swift` |
| `overture-prep-queue.json` | App (`PrepQueueBuilder.encode`) | Prep run (workflow) | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 | `fixtures/prep-queue/` | `PrepQueueContractTests.swift` |
| `overture-prep-results.json` | Prep run (workflow) writes the results; then **`prep-run.sh`** adds three top-level keys of its own (`model`, `runCost`, `webCalls`, all via `lib/models.sh`, after the workflow has finished). See the note below the table. | App (`PrepImporter` / `PrepResultsDecoder`; it ignores all three of those keys) | 1, 2, 3, 4, 5, 6, 7, 8 | `fixtures/prep-results/` (`run-metadata-complete-v8.json` and `run-metadata-partial-v8.json` carry the three keys) | `PrepResultsContractTests.swift`, `PrepResultsRunMetadataContractTests.swift`, `lib/models.test.sh` |
| `overture-prep-progress.json` | `prep-run.sh` **only**: seeds it, then derives every update from `overture-prep-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`, the same helper scout uses). #1023: the workflow never writes this file; it rewrites the results file incrementally and the script counts its entries, so a run that forgets to self-report can no longer leave the count wrong. | App (`PrepProgressDecoder`) | 1 | `fixtures/prep-progress/` | `PrepProgressContractTests.swift`, `lib/progress-watcher.test.sh` |
| `prep-run-archives/<yyyyMMdd-HHmmss>/` | App (`PrepRunArchive.archiveFinishedRun`, #1878: on every run completion, and at launch for a run that ended while Overture was closed) | By hand today (the evidence for "did the run do what the runbook told it to"), and the intended source of history for #1616's wait estimate | n/a: the folder holds byte copies of the two files above under their live names, so each keeps its own version | `fixtures/prep-queue/`, `fixtures/prep-results/` (the same fixtures, read by the archive's own tests) | `PrepRunArchiveTests.swift` |
| `prep-cancel` | App (`PrepQueueService.requestCancel`) writes it to ask a running Prep run to stop; App (`startPrep`) clears any stale one before a fresh run | `prep-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `PrepReplyCancelServiceTests.swift`, `lib/scout-cancel.test.sh`, `PrepReplyRunnerWiringGuardTests.swift` |
| `reachability-probe-run.json` | App (`PrepQueueService.startReachabilityProbe`, via `ReachabilityProbeMarker.write`), rewritten by `settleReachabilityProbe` when a settle could not save, removed when it settles | App (`ReachabilityProbeMarker.read`, from `settleReachabilityProbe` / `settleOrphanedProbe` / `isProbeRunning`); `prep-run.sh` reads its PRESENCE only, to chunk the run and pick the cheaper model | none (two fields; `settleAttempts` added additively and optionally in #1809) | `fixtures/reachability-probe-run/` | `ReachabilityProbeMarkerContractTests.swift`, `UnfinishedCheckTests.swift`, `RunKindGuardTests.swift`, `prep-run-chunking.test.sh` |
| `overture-reply-classify-queue.json` | App (`ReplyClassifyQueueBuilder.encode`) | Classify+drafter run (workflow) | 1, 2, 3 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-reply-classify-results.json` | Classify+drafter run (workflow, rewrites it after every item, not only once at the end; #1081) | App (`ReplyClassifyResultsDecoder`) | 1, 2, 3 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-reply-classify-progress.json` | `reply-classify-run.sh` **only**: seeds it, then derives every update from `overture-reply-classify-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`, the same helper prep and scout use). #1081: the workflow never writes this file; it rewrites the results file incrementally and the script counts its entries, so a run that forgets to self-report can no longer leave the count wrong. | App (`ReplyClassifyProgressDecoder`) | 1 | `fixtures/reply-classify-progress/` | `ReplyClassifyProgressContractTests.swift`, `lib/progress-watcher.test.sh` |
| `reply-classify-cancel` | App (`ReplyClassifyService.requestCancel`) writes it to ask a running reply-classify run to stop; App (`startClassify`) clears any stale one before a fresh run | `reply-classify-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `PrepReplyCancelServiceTests.swift`, `lib/scout-cancel.test.sh`, `PrepReplyRunnerWiringGuardTests.swift` |
| `overture-scout-page-<sourceId>.html` | App (`ScoutPagePin.write`, normalized + hashed) | Scout-extract run (workflow, reads it; never fetches the listings page itself) | n/a (HTML, not JSON) | none (the shape is a web page) | `SourceFetcherTests.swift` (normalization, hash, safe filename), `HandoffCleanupTests.swift` (retention) |
| `overture-scout-extract-queue.json` | App (`ScoutExtractQueueBuilder.encode`) | Scout-extract run (workflow) | 1, 2 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift` |
| `overture-scout-extract-results.json` | Scout-extract run (workflow, rewrites it after every item, not only once at the end; #1015) **and `scout-extract-run.sh`** (#856: it writes a `not_read` result for any queued source the run never came back with) | App (`ScoutExtractResultsDecoder`) | 1, 2, 3, 4, 5 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift`, `RunVanishedTests.swift`, `lib/results-guard.test.sh` |
| `overture-scout-extract-progress.json` | `scout-extract-run.sh` **only**: seeds it, then derives every update from `overture-scout-extract-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`). #1015: the workflow never writes this file; a run that forgets to self-report (2026-07-16) can no longer leave the count wrong. | App (`ScoutExtractProgressDecoder`) | 1 | `fixtures/scout-extract/` | `ScoutExtractContractTests.swift`, `lib/progress-watcher.test.sh`, `ScoutProgressWiringGuardTests.swift` |
| `scout-extract-cancel` | App (`ScoutExtractService.requestCancel`) writes it to ask a running read to stop; App (`startExtract`) clears any stale one before a fresh run | `scout-extract-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `ScoutCancelTests.swift`, `lib/scout-cancel.test.sh`, `ScoutCancelWiringGuardTests.swift` |
| `overture-voice-feedback.json` | App (`VoiceFeedbackBuilder.encode`) | Prep run (workflow) | 1, 2, 3 | `fixtures/voice-feedback/` | `VoiceFeedbackContractTests.swift` |
| `overture-recent-openers.json` | App (`RecentOpenersBuilder.encode`) | Prep run (workflow) | 1 | `fixtures/recent-openers/` | `RecentOpenersContractTests.swift` |
| `overture-run-duration-history.json` | App (`RunDurationHistoryStore.record`) | App (`RunDurationHistoryStore.load`) | 1 | none | `RunDurationHistoryTests.swift` |
| `overture-probe-duration-history.json` | App (`ProbeDurationHistoryStore.record`) | App (`ProbeDurationHistoryStore.load`) | 1 | none | `ProbeDurationHistoryTests.swift` |
| `installed-build.json` | `mac/build-install.sh` (after a successful install) | App (`BuildFreshness.installedRecord`) | 1 | none (three fields, pinned by the decode test) | `BuildFreshnessTests.swift` |
| `shipped-commit.json` | `scripts/record-shipped-commit.sh` **only**, called by both merge scripts, `scripts/hooks/post-merge`, and `mac/build-install.sh` | App (`BuildFreshness.shippedRecord`) | 1 | none (two fields, pinned on both sides) | `BuildFreshnessTests.swift`, `scripts/record-shipped-commit.test.sh` |
| `update-result.json` | `mac/scripts/lib/update-result.sh`, called by `mac/scripts/update-overture.sh` (#2188: `running` before it decides anything, the refusal reason if it refuses, REMOVED on success) | App (`UpdateAttempt.record`) | 1 | none (four fields, pinned on both sides) | `UpdateAttemptTests.swift`, `UpdateAttemptStateTests.swift`, `mac/scripts/update-overture.test.sh` |

#1678: the results files carry **run metadata written by the runner script, not by the workflow**. On
`overture-prep-results.json` that is `model` (#1533, which model actually ran), `runCost` (#1593, dollars and
wall clock) and `webCalls` (#1864, how many web lookups the run made against its allowance). `model` alone is
also written onto `overture-scout-extract-results.json` and `overture-reply-classify-results.json` by their
own runners. All of them are added by `lib/models.sh` after the run has finished, and the app's decoders
ignore them, which is what makes them safely additive.

The shape that must not be got wrong is the same split in each of `runCost` and `webCalls`:

- `recorded: true` carries the real figure (`usd` and `durationMs`; `total` and `denied`)
- `recorded: false` carries **none of those keys at all**, only `partialUsd` / `partialDurationMs` and
  `partialTotal` / `partialDenied`, plus how many streams reported out of how many

That absence is the point. A chunked run is up to ten concurrent claudes, so one dead chunk leaves a real but
incomplete figure, and a reader reaching for the field it always reads must find nothing rather than a part
of the total presented as the whole. `webCalls.overCap` follows the same rule from the other side: on the
incomplete path it appears only when the partial count ALREADY exceeds the allowance, because that verdict
can only get truer. This was registered here after the fact, having shipped without a row or a fixture, and
#1625 is about to build on `runCost.durationMs`.

#1616 now reads `runCost.durationMs` for the reachability check's wait estimate, and what it found is worth
recording here because it shapes what that key can and cannot be used for. `overture-prep-results.json` is
OVERWRITTEN by every run and is shared by a Prep run and a check, so exactly ONE `runCost` record exists at a
time: it is a reading of the last run, not a history. It also does not say WHICH kind of run wrote it (the
app decides that from the check's own marker, see `RunKind`) and carries no lookup count. What it does carry
is a real wall clock (`durationMs` is the LONGEST stream, never the sum) and `streams`, the chunk count,
which for a check is how many lookups ran at once. So the app accumulates its own history
(`overture-probe-duration-history.json`) from that reading plus the size stamped in the check's marker, and
never treats the results file as a record of more than the last run.

#1616: `overture-probe-duration-history.json` is app-internal telemetry on the same footing as
`overture-run-duration-history.json` above (the last 10 completed reachability CHECKS, as lookups, streams
and wall-clock seconds, for the wait the selection bar quotes before Dan spends anything). The app writes and
reads it, no script touches it, and a missing or malformed file reads as no history at all, which puts the
bar back on its hand-set constant rather than on a number nobody measured.

#2188: `update-result.json` is the return channel for the Update button. Pressing it opens a Terminal window
the app cannot see, so until this file existed a refused update and a successful one were the same thing from
inside Overture: nothing. It carries the id of the button press that started the run (`press`), so an outcome
can never be attributed to a press other than the one that caused it, and an `outcome` of `running` or
`failed` with the run's own `reason` sentence. Success is expressed by REMOVING the file rather than by a
value, which is what makes a record that is present and unreadable safe to treat as a failure. Like the two
records above it describes the app rather than a run, so the retention sweep does not own it.

#1813: `reachability-probe-run.json` is the marker that says which KIND of run is in flight, and it is
registered here late. Both of its programmatic sides are the app, which is why it was missed, but the seam it
crosses is time rather than language: a check runs detached for twenty minutes or more and can outlive the
build that launched it, so a marker written by one version is read by whatever version is installed when the
run comes home. #1809 changed its shape while that was true, adding `settleAttempts`, and got away with it
only because the field was made optional: Swift's synthesized decoding does not apply a property's default
value, so a non-optional would have failed to read exactly the paid run the field exists to protect. The
`launched.json` fixture is that pre-#1809 shape, kept so the next change to this file has to stay compatible
with it rather than merely intending to.

Misreading it is expensive in both directions, and unequally. A check read as a Prep run drafts over shows
Dan never kept; a Prep run read as a check ingests probe-safely, short-circuits before any draft handling,
and discards every draft that run wrote with nothing on screen saying why, which is what #1809 cost. So the
undecodable case is deliberately resolved as a Prep run: `read` throws, every caller flattens that to nil,
and `settleReachabilityProbe` declines, which is what sends the completion path to the ordinary ingest with
the run's drafts intact. `UnreadableCheckMarkerTests` asserts that end to end rather than trusting it.

#1808: `installed-build.json` and `shipped-commit.json` are how the app answers "is the copy Dan is looking
at behind the code?", which it cannot work out for itself because it has no git at runtime. They are the
only two files here whose writer is a shell script and whose reader is the app with no run in between.
Both are small, both are honest when absent (a missing record reports "cannot tell", never "up to date"),
and neither lives in the handoff directory's retention sweep: they describe the installed app rather than a
run, so ageing one out would silently turn the check off. `installed-build.json` also carries `repoPath`,
which is the only way the app knows where to run the installer from when Dan presses Update.

#1427: `overture-run-duration-history.json` is app-internal telemetry (the last 10 completed Reading-calendars
runs, for the "~X remaining" estimate), NOT a cross-language contract: the app both writes and reads it, no
script touches it, so its shape is pinned by `RunDurationHistoryTests`'s round-trip rather than a fixture. It
lives in the handoff directory only to sit alongside the other run files; it is deliberately kept out of the
live SwiftData store (that store's corruption history argues against new tables for low-stakes telemetry).

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

An empty `bookings` array is no longer read as a fact about Dan's diary on its own (#2478). When this
file lists clients and carries no upcoming bookings, while Overture last saw the same feed carrying
two or more whose dates have not passed yet, that is read as a BROKEN export and said so on the
queue's masthead: shoots leave this file one at a time as their dates pass, so the whole list going
in one step cannot be the calendar advancing. `DownbeatBookingFeed` owns that verdict, separately
from `DownbeatBridge.health` (is the file there, decodable, recent) and `DownbeatFeedFreshness` (has
anything new arrived lately). The producing side of the 2026-08-10 outage is filed in Downbeat as
danwright32/downbeat#147 and #148.

Those evidence keys are new, so a Mac whose export had ALREADY stopped carrying bookings would have
had nothing to compare against. `DownbeatBookingFeedStore.bootstrapFromSeenIds` migrates #1456's
seen-booking-id set into them once, and only into a store with no history of its own: the first
export that actually carries shoots overwrites all three keys, so dated evidence always wins over
the migrated record. The migrated record carries no end date (those ids never had one), and is
therefore leaned on for four weeks after the last new shoot arrived rather than until a date passes.
The same cold-start hole in the sibling checks is #2496; an export whose CLIENT list empties this
way is #2495.

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
early manual test run, over two weeks stale, but no `refined.json` was ever produced. At the time,
the native app's queue view surfaced every prospect the rules called uncertain for Dan to correct by
hand, which covered the same need, so the file hand-off was dropped rather than ported. #1533 then
retired that flag too (it never measured the genre it named, and the production type it really asked
about is not something Dan researches). What survives is the by-hand genre correction on the row
(`ClassificationOverride.swift`); no re-judge pass, automated or assisted, exists in any form.

### `overture-prep-queue.json` and `overture-prep-results.json`

The app's round trip with the Prep run. The app writes `prep-queue.json` (the kept-undrafted
prospects that need a contact and a draft, plus, since #367, any prospect Dan explicitly flagged
for re-prep even though it already has one, via `PrepQueueBuilder.encode`); the Prep run reads it,
does the research and drafting, and writes `prep-results.json`; the app ingests that through
`PrepImporter`, moving prospects to `drafted` for Dan to review. The `naturalKey` is the opaque join
key the run must echo back verbatim, never rebuild. The Prep run is the counterpart side with no
automated test, so `fixtures/prep-queue/` and `fixtures/prep-results/` are its spec (see
`docs/prep-runbook.md`).

Both files are OVERWRITTEN by the next run, so #1878 keeps each finished run's pair in
`prep-run-archives/<yyyyMMdd-HHmmss>/` beside the live ones, the last 30, through the same rotation the
store backups use (`DatedFolderRotation`). The folder is named for the RUN, from its own `generatedAt`
rendered in UTC, so the name and the timestamp inside it are the same moment and archiving one run twice
(the app archives at launch and again when it settles a run it watched) lands on the one folder rather
than minting a second copy. The files keep their live names, so anything that can read a live handoff
file can be pointed at an archived run with nothing to translate, and their fixtures and versions above
are therefore the archive's too. A run that produced only half a pair is still archived, with
`archive.log` naming what was missing: a run that went wrong is the one most worth reading later.
`prep-run-events.jsonl` and `prep-run.log` are 300 KB+ each and are deliberately NOT archived; their
retention is a separate decision.

The runbook states BOTH versions and names every item field in prose, which drifted from the code
unnoticed until #1908 (#1897 shipped queue v10 with `venueHistory` while the input spec still said
version 9 and never listed the field). `src/lib/prepQueueSpec.test.ts` now holds that section to
`PrepQueueBuilder.version`, `PrepResultsDecoder.supportedVersion` and the actual `PrepQueueItem`
fields, in both directions: a field the payload carries but the spec omits leaves the run unaware it
exists, and a field the spec names but the payload lacks invites the model to supply it itself.

The results file also carries RUN-LEVEL facts, stamped by the runner script after the run rather
than written by the model: `model` (#804, which model wrote these drafts), `runCost` (#1593), and
`webCalls` (#1721, how many times the run actually reached the web, counted from its own event
stream by `lib/models.sh`'s `record_web_calls`). These sit beside `results`, not inside it, and are
all OPTIONAL: a file from before any of them existed still decodes and still lands Dan's drafts.

`webCalls` is the first of the three the app actually reads (`PrepResults.WebCalls` ->
`PrepImporter.Outcome` -> `PrepRunSummary`), so it is documented here; `model` and `runCost` are
written and, as of #1721, still have no reader. Its `recorded` flag is the field to branch on: when
a stream did not report, the writer publishes NO `total` at all and carries the figure as
`partialTotal` instead, so nothing downstream can read a partial count as the real one by reaching
for the field it always reads. `overCap` is likewise absent when the verdict is not yet knowable.

#1835: `total` and `byRoute` count only the calls that actually RAN. A call the permission layer
refused reached nothing, and counting one as reach both inflated the figure the allowance is judged
against and, once, was read as evidence a run could do something it cannot. Refusals are counted in
their own right instead, as `denied` and `deniedByRoute` (`partialDenied` on the incomplete path,
following exactly the same rule as `total`), because a run repeatedly asking for a tool it does not
have is a signal worth keeping rather than one to throw away. A refusal is recognised by the CLI's
`tool_result_meta[].non_execution_kind` or by the permission sentence in the tool result, both read
from real refusals in Dan's own event streams; deliberately NOT by `is_error`, which a call that
really ran and failed also carries.

Queue version 2 (#586, #366 Phase 1) adds an optional `production` (`self` / `agency` / `unknown`,
from `Prospect.production`/#349) to each item, so the research step knows whether a show is
self-produced before deciding whether to pursue a named performer directly (#366 Phase 3). Additive;
`v1.json` stays byte-identical and still decodes with `production` absent (nil).

Queue version 3 (#367) adds an optional `reprepMode` (`draft_only` / `contacts_only`, absent means
both) to each item, set only when Dan asked to re-prep a prospect that already has a draft, so the
run knows to skip the corresponding half instead of redoing everything. Additive; `v1.json`/
`v2.json` stay byte-identical and still decode with it absent (nil).

Queue version 5 (#5) adds an optional `experimentArmInstruction` to each item: the opener archetype
this item MUST use (one of the live tokens `reason-first` / `direct-intent`), copied from the
app-assigned `Prospect.assignedArm` when the prospect belongs to an active A/B experiment.
`credential-first` and `observation-first` were retired on 2026-07-31: `ExperimentEditing.start`
refuses to assign either, and `fixtureShape.ts` rejects either as an echoed `variant`, but both remain
cases of Swift's `OpenerArchetype` so a stored experiment's arms and a prospect stamped before that
date still decode and label. A stale instruction naming a retired shape is not an error here; the
runbook tells the drafter to write the closest live shape and record THAT. Absent (the common case, no active experiment) means the drafter uses the
normal #362 opener rotation. The runbook (`docs/prep-runbook.md` §2) gives this field PRECEDENCE over
that rotation, so an experiment item genuinely randomizes what is produced. Additive; `v1.json`
through `v4.json` stay byte-identical and still decode with it absent (nil). (Version 4, #1122, added
`runEndDate` + `openingNightPassed`; it had no paragraph here before this one.)

Queue version 7 (#1720, milestone 34 Phase 3) adds an optional RUN-LEVEL `houses`, beside `items`
rather than inside them: the organisations the app has already judged to be the BUILDING rather than
the act. Each entry is a `key` (`ProducerGate.key`'s folded form, for an exact lookup) and a `name`
(one readable spelling of the same room, for a run comparing against a name it read on a page). The
list is `ProducerGate.houses`: every venue string in the store, every presenter its own venue-brand
arms refuse, and every house Dan demoted by hand (#1719), computed once per build from the WHOLE
store rather than the run's own items. The READER is `docs/prep-runbook.md` §1, which looks a name up
here instead of deciding for itself: an organisation NOT on the list is visited before the run
concludes nothing exists (#1681: it named Henry Street Settlement, searched for it, and reported no
contact without ever fetching henrystreet.org), and one ON the list is refused exactly as the hard
venue-disqualify rule already refuses the show's own venue. Deliberately not a second copy of that
judgment written in English inside the prompt: #1702 centralised it in `ProducerGate` so the two
halves could not drift, and the English version (compare the org's domain against the host venue's)
was refuted on five live rows served from carnegiehall.org with a host venue whose domain is not.
Additive; `v1.json` through `v6.json` stay byte-identical and still decode with it absent. ABSENT and
EMPTY differ and the runbook is told so: absent means a file written before this phase, empty means
the app looked and named nothing.

Queue version 8 (#1824) adds an optional `showListing` to each item: what the show's OWN listing page says,
rendered by the APP and handed over as text. It exists because the Prep run cannot read that page itself.
On 2026-07-30 the run fetched `sourceListingURL`, got an 11KB JavaScript shell with no description in it,
asked for a browser render, and was DENIED by its own tool scope (`PREP_ALLOWED_TOOLS` in
`mac/scripts/lib/claude-run-scope.sh`), then drafted a solo singer-songwriter's cabaret concert as if the
reader were a performing arts organisation. Dan's call was to render it app-side (`ShowListingReader`, reusing
#806's `RenderedPage`) rather than widen an unsupervised run's tools, since that scope exists because #1026
found a detached run auto-approving everything.

Three states, and the runbook is told all three because the honest sentence differs for each: `read` (with
the page's bounded readable `text`, plus `truncated` when it had to be cut), `unreadable` (the page did not
load or carried nothing), and ABSENT (there was no page to look at, or a file written before this field).
The app deliberately hands over the page's TEXT rather than trying to pick "the description" out of it:
roughly a third of the store's listing URLs point at a season calendar or an index rather than one show's
own page, and the run, which holds the show's name, date and venue, is the only side that can tell. Read by
`docs/prep-runbook.md` §2, which also requires the run to write back what it concluded. A reachability check
never carries one: it finds contacts and never drafts, so a render there would buy nothing. Additive, so
`v1.json` through `v7.json` stay byte-identical and still decode with it absent.

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

Version 8 (#1824) adds an optional `showSummary` on the result itself, one plain line saying what the show
IS, sourced entirely from the listing text the app handed over in the queue (version 8 above), plus a
`showSummaryAbsentReason` that is REQUIRED whenever there is no summary: `no_listing_page` (the item carried
no `showListing`), `page_unreadable` (the app could not read it), or `no_description_published` (it was read
and does not describe this show, which includes the common case of a listing URL pointing at a season
calendar). Three reasons rather than one silence, because they are three different facts and only the last
is a statement about the show (L11).

Two things it is for. It makes the "read the listing first" rule leave a CHECKABLE TRACE instead of living
only inside the prompt (L27), and it gives Dan a line on the review card saying what the draft beside it was
grounded in, or honestly that it was grounded in nothing (`Prospect.showSummary` ->
`ProspectRowView.showSummaryNote`). A run that sends neither field leaves whatever is already recorded alone:
the runbook is a prompt, and a silent gap is not evidence a page became unreadable. Purely additive; the
reader's tolerant gate (1 through 8) still accepts `v1.json` through `v7.json` unchanged, `v8.json` is the
show-summary spec.

Queue version 10 (#1887) adds an optional `venueHistory` to each item: how well Dan already knows
THIS room, as one of `shot_before` / `a_few` / `regularly`. It is a BAND and never a count, and the
count itself never leaves the app (`VenueShootHistory`). Dan's rule is that a pitch never claims an
exact number, and a rule that lives only in the prompt is a hope (L27), so the wire carries nothing
for the drafter to state. A second, deterministic guard sits at the other end: `DraftCheck`'s
`venueHistoryCount` BLOCKS a send whose body pairs a past-tense first-person shooting phrase with a
count, since the app never supplied one.

Absent means SAY NOTHING, and three different situations produce it: no history at the venue, no
history imported at all, and, deliberately, a show at Carnegie Hall, where the runbook already
requires the "nearly ten years at Carnegie Hall" tenure credential and a venue band beside it would
be one fact stated twice (Dan's call, 2026-07-31). Additive; the reader's tolerant gate (1 through
10) still accepts `v1.json` through `v9.json` unchanged, and `v10.json` is the venue-history spec.

### `overture-shoot-history.json`

Every past shoot Dan has photographed, with its venue and date, so a pitch can say he has shot this
room before. Written by `scripts/import-shoot-history.ts` from an iCalendar export of his "Shoots"
Google Calendar (a manual, re-runnable step: Overture holds no standing calendar permission and asks
for none), read by the app through `ShootHistory`.

`venue` arrives EXACTLY as the calendar writes it, unfolded but NOT normalised: 42 of 322 events
separate the address with a newline rather than a comma, and 40 wrap the whole value in double
quotes. The importer does no venue folding on purpose, so this file cannot become a fourth name
vocabulary drifting from the three the app already has; `VenuePlaces.canonicalKey` folds it. `date`
is already the Eastern day (81 of 381 events are evening shows whose UTC day is the next one).

Four `VEVENT` shapes never reach the file, and the importer names each one it refused rather than
guessing: `RRULE`, `RECURRENCE-ID`, `STATUS:CANCELLED`, and an all-day `DTSTART` (no time zone to
date it by). Refusing is the only behaviour that cannot be silently wrong: a parser that expanded a
weekly rule would turn one booking into hundreds of shoots, and one that ignored it would count a
decade of weekly shoots as one.

Code on both sides, so it carries no `fixtureShape.ts` entry (that guard exists for the contracts
whose other side is a workflow); its Swift contract test against the shared fixture is the whole
guard, exactly as `overture-history.json` works.

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
gate (1 through 2) still accepts the v1 files (`queue-v1.json` / `results-v1.json`), where `recipientId`
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
  (`NYO Jazz in Beijing, China`), which no other source shares. #1744 now READS that convention in the
  app (`EventLocationFill.cityFromTitle`), narrowly: the tail after the last " in " counts only when it
  is exactly "somewhere, place" and the trailing part is a country or US state `EventPlace` already
  recognises, so a show called "... in Concert" never becomes a show in a town called Concert.

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

**On the WIRE, absent still means absent. On the stored PROSPECT, it no longer does (#1744).** These used
to be the same statement, and that was the defect: 342 of 498 untriaged shows reached the queue with a
blank `location`, so the geography gate never ran on two thirds of the queue and a Dominican Republic show
and a Manhattan show sat there looking identical. Inventing a location on the wire would still be worse
than omitting one, so nothing here changes: the run reports the page's words or nothing. The FILL happens
one layer in, at `ProspectAssembler.decide`, through `EventLocationFill`, which tries in order the page's
own words, a city and state already baked into the venue string, the Carnegie tour-title convention
described above (which this document said was readable and nothing read until #1744), and a curated
venue-to-place table (`VenuePlaces`) shared with the card's city line. It never consults a per-source
address: Carnegie's own address is 881 7th Ave, so a source-level fallback would stamp "New York, NY" onto
its Santo Domingo date, and a confident wrong place is the only failure in this area that can hide a real
show. Measured on the live store 2026-07-29, that chain places 341 of the 342 blank rows.

The wire keeping the page's own answer is load-bearing rather than tidy: `SourcePlacement.placedCount`
reads the raw `location` off the same events to detect a source that has silently STOPPED reporting
places (#986), and a pre-filled wire would tell it every source places perfectly and switch that
detector off.

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

Version 5 (#1469) adds an optional `venueNotPublished` to each event: the run read this row and the PAGE
ITSELF has not published a venue for it (a placeholder row, an explicit TBA), as opposed to a detail page
the run could not open. Both come back with a null `venue` and are indistinguishable in the file, and they
are opposite facts about a source. An unread detail page means the run does not know what ELSE it failed to
reach, so past a small tolerance (`FeedReconcile.maxRejectedFraction`) that source forfeits the right to say
any show was cancelled (#887). A publisher's own blank field means nothing of the kind, and treating it as
though it did switched cancellation detection off indefinitely on real sources: 34 of OPERA America's 92
NY-area rows (#1472, the native-feed half of the same defect), and one permanent "Info coming soon" row on
Smoke Ring's four-show page, which is 25% of that calendar. The run is the only thing that ever saw the
page, so it is the only thing that can tell them apart, and the flag is where it says so. Set it ONLY for a
page that published no venue; leave it absent for anything unreached, which keeps the suspicious reading.
The dropped row is still not ingested (`ExtractedEventGuard` is unchanged: a venue-less prospect would name
the wrong place in Dan's email); it simply stops counting against the source's readability, and its own show
is held as still listed by its listing link, or by its date when the row has no link (a placeholder links
nowhere), so nothing stored is struck for a row that is on the page right now. Purely additive, and like
every field above the version bump is documentation, not a behavioral gate: nothing reads `version`, and an
absent flag (a v1 to v4 file, or any run whose pages all named their venues, which is nearly all of them)
decodes unchanged and keeps the pre-#1469 behaviour exactly. `results-v1.json` through `results-v4.json`
stay byte-identical as that proof; `results-v5.json` is the spec, Smoke Ring's real page with three read
rows and the Oct 24 Palm Springs placeholder.
