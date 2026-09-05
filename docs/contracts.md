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
| `downbeat-export.json` | Downbeat app (separate repo) | App (`DownbeatBridge.decode`) | 1 or above: a MINIMUM with no ceiling, not a set (#3193). See the note in the section below | `fixtures/downbeat-export/` | `DownbeatExportContractTests.swift` |
| `overture-history.json` | Importer (`scripts/import-history.ts`) | App (`[HistoryRecord]`) | none (plain array; `email` added additively in #762) | `fixtures/local-history/` | `LocalHistoryContractTests.swift` |
| `overture-shoot-history.json` | Importer (`scripts/import-shoot-history.ts`) | App (`ShootHistory`) | 1 | `fixtures/shoot-history/` | `ShootHistoryContractTests.swift` |
| `overture-prep-queue.json` | App (`PrepQueueBuilder.encode`) | Prep run (workflow) | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 | `fixtures/prep-queue/` | `PrepQueueContractTests.swift` |
| `overture-prep-results.json` | Prep run (workflow) writes the results; then **`prep-run.sh`** adds five top-level keys of its own (`model`, `runCost`, `webCalls`, `runKind`, `runSlot`, all via `lib/models.sh`, after the workflow has finished). See the note below the table. | App (`PrepImporter` / `PrepResultsDecoder`; it ignores all five of those keys. `RecordedRunCost` reads `runCost` and `runKind`) | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 | `fixtures/prep-results/` (`run-metadata-complete-v8.json` and `run-metadata-partial-v8.json` carry all five) | `PrepResultsContractTests.swift`, `PrepResultsRunMetadataContractTests.swift`, `ResultsFileNamesItsRunKindTests.swift`, `lib/models.test.sh` |
| `overture-prep-progress.json` | `prep-run.sh` **only**: seeds it, then derives every update from `overture-prep-results.json` itself (`lib/progress-watcher.sh`'s `update_progress_from_results`, the same helper scout uses). #1023: the workflow never writes this file; it rewrites the results file incrementally and the script counts its entries, so a run that forgets to self-report can no longer leave the count wrong. | App (`PrepProgressDecoder`) | 1 | `fixtures/prep-progress/` | `PrepProgressContractTests.swift`, `lib/progress-watcher.test.sh` |
| `prep-run-archives/<yyyyMMdd-HHmmss>/` | App (`PrepRunArchive.archiveFinishedRun`, #1878: on every run completion, and at launch for a run that ended while Overture was closed) | By hand today (the evidence for "did the run do what the runbook told it to"), and the intended source of history for #1616's wait estimate | n/a: the folder holds byte copies of the two files above under their live names, so each keeps its own version | `fixtures/prep-queue/`, `fixtures/prep-results/` (the same fixtures, read by the archive's own tests) | `PrepRunArchiveTests.swift` |
| `prep-running`, `prep-chunks/`, `prep-run.log`, `prep-run-events.jsonl` | `prep-run.sh` (the heartbeat marker, the per-chunk working directory it wipes on entry, and the two logs), plus the App, which writes the marker at launch so the double-run guard is immediate (`PrepQueueService`) | App (`DetachedRunner.heartbeat` reads the marker for live, stale or gone; the logs and the chunk directory are read by hand and by `RunEventsReader`) | none (the marker's CONTENTS are never read: its modification time is the whole signal, exactly as `prep-cancel`'s presence is) | none | `DetachedRunnerTests.swift`, `prep-run-chunking.test.sh`, `lib/run-slot.test.sh` |
| `overture-check-queue.json`, `overture-check-results.json`, `overture-check-progress.json`, `check-run-archives/<yyyyMMdd-HHmmss>/` | The reachability CHECK's four rows, and they are the three files above plus the archive under the `check` slot's names rather than the `prep` slot's (#2760, #2805). Same writers, same readers, same versions, same fixtures and same tests as the prep rows: every name is built by `RunSlot` from one set of declarations, so a row here that disagreed with the row above it would be describing code that does not exist. Listed because this catalogue is what anyone is told to read before changing a cross-boundary file shape, and until #2805 it named only the prep spellings, which are the files the check STOPPED writing at #2760. | | | | |
| `prep-covers.json`, `check-covers.json` | App (`RunCoverage.write`, from `startPrep` and `startReachabilityProbe`, immediately after the slot's marker is taken and before the listing read, #3010) | App (`RunCoverage.read`, gated on that slot's marker being LIVE); `prep-run.sh` only REMOVES it, in the EXIT trap, AFTER the marker | none (a bare JSON array of `naturalKey`s, plus each grouped item's `alsoAnswersFor`) | none | `RunCoverageTests.swift`, `lib/run-slot.test.sh` |
| `check-running`, `check-cancel`, `check-chunks/`, `check-run.log`, `check-run-events.jsonl` | The same for the marker, the cancel sentinel, the per-chunk working directory and the two logs: `RunSlot`'s `check` spellings of the `prep-*` names elsewhere in this table. None carries a version; the marker and the sentinel are presence-only, exactly as `prep-cancel` above. | | | | |
| `prep-cancel` | App (`PrepQueueService.requestCancel`) writes it to ask a running Prep run to stop; App (`startPrep`) clears any stale one before a fresh run | `prep-run.sh` (`lib/scout-cancel.sh`'s `cancel_requested`, on each heartbeat tick; `clear_cancel` on exit) | n/a (empty sentinel; presence IS the request, contents never read) | none | `PrepReplyCancelServiceTests.swift`, `lib/scout-cancel.test.sh`, `PrepReplyRunnerWiringGuardTests.swift` |
| `reachability-probe-run.json` | App (`PrepQueueService.startReachabilityProbe`, via `ReachabilityProbeMarker.write`), rewritten by `settleReachabilityProbe` when a settle could not save, removed when it settles | App (`ReachabilityProbeMarker.read`, from `settleReachabilityProbe` / `settleOrphanedProbe` / `isProbeRunning`); `prep-run.sh` reads its PRESENCE only, and since #2980 only when the run NAMES no slot (a build older than #2763, the one case that could put a check in the prep slot); a run that names its slot takes its kind from the slot alone | none (two fields; `settleAttempts` added additively and optionally in #1809) | `fixtures/reachability-probe-run/` | `ReachabilityProbeMarkerContractTests.swift`, `UnfinishedCheckTests.swift`, `RunKindGuardTests.swift`, `prep-run-chunking.test.sh` |
| `<slot>-claude-pid` | `prep-run.sh` (`lib/run-slot.sh`'s `SLOT_CLAUDE_PID`): the pid of the `claude` process, or the space separated pids of every chunk's, written after launch and removed by the EXIT trap | `prep-run.sh` itself, and only it: `heartbeat_guard_exit` refuses to keep a heartbeat alive for a dead run, `heartbeat_touch_or_stop` stops when it has gone, and cancel kills what it names | n/a (pids, whitespace separated; presence means a run believes it has a live claude) | none | `lib/run-slot.test.sh`, `lib/run-heartbeat.test.sh` |
| `<slot>-stall-state` | `prep-run.sh` (`lib/run-slot.sh`'s `SLOT_STALL_STATE`, through `stall_tick`): how long the results file has gone without growing | `prep-run.sh` (`stall_tick` decides whether to stop, `stall_stalled_seconds` says how long for the message) | n/a (bookkeeping for one run; removed by the EXIT trap) | none | `lib/run-slot.test.sh`, `lib/stall-guard.test.sh` |
| `<slot>-run-events.fifo` | `prep-run.sh` (`lib/run-slot.sh`'s `SLOT_EVENTS_FIFO`): the named pipe `run_one_claude` streams the run's events through, so they can be tee'd live rather than read after the fact | The same run's own tee, into `<slot>-run-events.jsonl`. NOTHING outside the run reads the pipe: it exists so the events file is written as the run goes rather than at the end | n/a (a FIFO, not a file with contents to read later) | none | `lib/run-slot.test.sh` |
| `<slot>-run.chunk-N.log`, `<slot>-run-events.chunk-N.jsonl`, `<slot>-events-chunk-N.fifo` | `prep-run.sh` per CHUNK when a run fans out (`slot_chunk_log`, `slot_chunk_events`, `slot_chunk_fifo`) | The run itself: the per-chunk events files are what `record_run_cost` sums into the results file's `runCost`. The logs are read by hand | n/a (`N` is the chunk index from 0; these are FAMILIES rather than single files, which is why the catalogue names the shape) | none | `prep-run-chunking.test.sh`, `lib/models.test.sh` |
| `run-boundary-violation.log` | `prep-run.sh` (`lib/run-slot.sh`'s `slot_check_foreign_results`, #2764: appends one entry when a run's EXIT trap finds another slot's results file changed while it ran) | App (`RunBoundaryViolations.newlyReported`, #2760: counted at launch and at each settle, and said out loud once per violation as a `.warning`) | n/a (a plain log; the app counts lines carrying `BOUNDARY VIOLATION` and stores the count under `runBoundaryViolationsReported`) | none | `RunBoundaryViolationTests.swift`, `lib/run-slot.test.sh` |
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
| `installed-build.json` | `mac/build-install.sh` (after a successful install) | App (`BuildFreshness.installedRecord`) | 2 | v2 adds `provenance` (`main`, `branch` or `unknown`); a v1 record has none, which the app reads as its own reason it cannot tell, never as `main` | `BuildFreshnessTests.swift`, `mac/scripts/lib/build-provenance.test.sh` |
| `shipped-commit.json` | `scripts/record-shipped-commit.sh` **only**, called by both merge scripts, `scripts/hooks/post-merge`, and `mac/build-install.sh` | App (`BuildFreshness.shippedRecord`) | 1 | none (two fields, pinned on both sides) | `BuildFreshnessTests.swift`, `scripts/record-shipped-commit.test.sh` |
| `update-result.json` | `mac/scripts/lib/update-result.sh`, called by `mac/scripts/update-overture.sh` (#2188: `running` before it decides anything, the refusal reason if it refuses, REMOVED on success) | App (`UpdateAttempt.record`) | 1 | none (four fields, pinned on both sides) | `UpdateAttemptTests.swift`, `UpdateAttemptStateTests.swift`, `mac/scripts/update-overture.test.sh` |

| `feed-movement.log` (in `~/Library/Logs/Overture`) | App (`FeedMovementLog`, one line per source per successful scout; the default-file write is suppressed under tests so a run cannot inject fake movement into the evidence) | **NOBODY YET.** Written for #913, to retune `minReBaselineFraction` against real movement rather than the reasoned 0.9 guess. #913 is open and deferred, so this is a writer with no reader today, which is the whole reason these rows exist (L46) | n/a (one `key=value` line per source, ISO timestamp first so it sorts and greps by time) | none | `FeedMovementLogTests.swift` |
| `gmail-connect-debug.log` (in `~/Library/Logs/Overture`) | App (`GmailAuthManager`, tracing the connect flow; the path is named once in `AgentLogLocation` rather than assembled at the writer, #2096) | By hand, when a connect fails. The app runs resident, so there is no console to watch it on | n/a (a plain trace log) | none | `AgentLogLocationTests.swift` (the name and the directory) |
| `queue-derivations.log` (in the DATA directory, not Logs) | App (`QueueRenderCounter`, **Debug builds only**; the suite is kept out of the file entirely by its own `underTests` seam, because the unit suite hosts itself in the full app and its renders were landing in the same file a real observation is read from) | By hand, plus the `derived N · <reason>` line the Debug queue draws above itself | n/a (one line per derivation, capped on write) | none | `QueueDerivationCounterTests.swift`, `QueueDerivationReasonTests.swift` |

#3465: the three rows above are LOGS the app itself writes, and they were absent from this catalog
until they were catalogued here. They carry no version and no fixture, which is the honest shape for a
plain log, but they do carry a writer and a reader, and that is what they were missing: a file nobody
catalogued has no stated reader, which is how a writer with no reader survives unnoticed (L46).
Asking the question found one immediately. `feed-movement.log` has been accumulating a line per source
per scout since #1114 and nothing has ever read it, because its only intended reader is #913, which is
open and deferred. That is not an argument for deleting it (the evidence is exactly what #913 needs and
cannot be reconstructed later), but it is worth being written down rather than discovered again.

One correction to #3465's own text, which said `backup.log` was already listed: it is not, and neither
are the two resident-agent logs (`overture-agent.out.log`, `overture-agent.err.log`) or
`overture-agent.problems.log`. Those four are still uncatalogued. They are left for their own pass
rather than swept in here, because each needs its reader checked the way these three did, and a row
asserting a reader nobody verified is worse than no row (#3525).

#1678: the results files carry **run metadata written by the runner script, not by the workflow**. On
`overture-prep-results.json` that is `model` (#1533, which model actually ran), `runCost` (#1593, dollars and
wall clock) and `webCalls` (#1864, how many web calls the run made against its allowance). `model` alone is
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

#2762 adds one more key to `runCost`, on BOTH the complete and the incomplete path: `contended`, whether
another RUN SLOT was alive at any point while this run worked. Three states, and they are three different
facts. `true` and `false` are measurements the runner latched (`lib/run-contention.sh`, sampled before the
work starts and again on every marker tick, derived from `slot_others` so a third slot cannot be missed, and
never counting the run's own marker). ABSENT means a runner that predates the flag, which is a real state
rather than a defensive one: the script is resolved out of the git checkout and `update-overture.sh`
fast-forwards that checkout BEFORE the rebuild, so a new app meets an older script for a couple of minutes
on every update and permanently for anyone who only pulls. The app refuses to record a sample whose
contention is absent, rather than reading it as solo, because reading it as solo would file exactly the
co-run the flag exists to measure as evidence about a run that had the machine to itself.

#3004 adds two more keys, and they sit at the TOP LEVEL rather than inside `runCost`: `runKind` (what kind
of run wrote this file) and `runSlot` (which slot it ran in). Both are spelled `prep` or `check`, the same
strings `RunSlot`'s raw values use, and `RunKind.resultsFileValue` / `RunKind.init(resultsFileValue:)` are
the only mapping in the app.

They are two facts and not one: a check may legitimately run in the prep slot, and that is exactly the case
a reader has to be able to see. Before this, a finished results file recorded `version`, `generatedAt` and
`results` and nothing about its own provenance, so a check's file and a Prep run's were indistinguishable
once written. That is the fact #2762's session 1 got wrong, and the only thing that caught it was a person
reading `prep-run.log` by eye.

Top level, deliberately: the provenance is true of the file whether or not the cost reading completed, and a
fact filed under a key that can go absent is a fact that disappears exactly when the run went wrong. The
PARTIAL fixture carries them for that reason.

Additive and optional, exactly like `contended`: a runner that says nothing writes no key, and so does one
whose value the reader would not recognise (only `prep` and `check` are written, so an environment typo
cannot become a permanent refusal with nothing naming its cause). The reader,
`ProbeRunPaceRecording.sample`, refuses to pool a reading that SAYS it was a Prep run, and pools an
unstamped one on the slot's trust exactly as before, which is what keeps the update window working.

`contended` deliberately does NOT mean "the machine was busy". A scout extract (up to four claudes, fired
hourly on its own) or a reply classify can be running too. Folding those in would give one stored field two
meanings depending on which version wrote the row, since every row already on disk predates the wider
reading, so #2762's measurement session counts concurrent processes directly instead.

The latch itself, `<slot>-contended`, is runner-only and never reaches the app: it is cleared on entry and
in the trap, exactly as `<slot>-stall-state` is, and the fact travels to the app inside `runCost`, beside
the wall clock it qualifies. One observer for both facts about one run rather than two that can disagree.

#1616: `overture-probe-duration-history.json` is app-internal telemetry on the same footing as
`overture-run-duration-history.json` above (the last 10 completed reachability CHECKS, as lookups, streams
and wall-clock seconds, for the wait the selection bar quotes before Dan spends anything). The app writes and
reads it, no script touches it, and a missing or malformed file reads as no history at all, which puts the
bar back on its hand-set constant rather than on a number nobody measured.

#2762: each stored run now also carries `contended`, copied from the results file above, and the two classes
are POOLED SEPARATELY and never together. A row with no `contended` key was written before #2762 and every
one of those ran while the prep/check exclusion was still in force, so it reads as solo; every row this
version writes carries the key, which is what makes that reading a fact about the writer rather than an
assumption about the data. A class holding fewer than three comparable runs answers nothing and the bar falls
back to its constant, rather than borrowing the other class's pace.

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

The version gate is the only one in this catalogue with no upper bound, and that is deliberate
(#3193). It used to be the exact set `[1, 2]`, so Downbeat's next bump would have thrown
`unsupportedVersion` in a reader that answers a throw with empty clients, empty bookings and empty
blockedDates: the roster would have emptied AND the scout would have stopped suppressing nights Dan
is already shooting, which is a pitch for a night that is taken. Downbeat is a separate app on its
own release schedule, so it bumping the format is the ordinary case rather than an error, and the
format is additive by contract (Codable ignores keys the struct does not declare). A version at or
above `DownbeatBridge.minimumVersion` is therefore read for the keys this reader declares.
`PrepResultsDecoder` and `ReplyClassifyResultsDecoder` keep their CLOSED `minimumVersion...supportedVersion`
ranges for the opposite reason: their producers are in this repository, so a version they do not
know means a run wrote a shape this build cannot act on, and reading it half-way stamps every show
in the run with a floor nothing upgrades (#1594). The rule is the writer, not the reader: refuse a
future version when the producer ships with you, accept one when it does not.

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

Which versions this reader accepts is DECLARED, in a file the producing repository can read:
`integration/downbeat-export-accepted-versions.json`, holding `minimumVersion` and a
`maximumVersion` that is `null` for no ceiling (#3203). It is not in the catalogue table above
because it is not a handoff file in the app-support directory: it is committed here and read by
Downbeat's own push gate, which refuses a push whose export version has outrun what this app
accepts. That gate used to find the number by pattern matching `DownbeatExport.swift`, understood
three shapes, and had to grow the third within an hour of being written, so a rename or a
restructure on this side silently stopped the comparison working and the only remedy over there was
to teach the script another shape afterwards. The path is a convention shared with Ovation, whose
handoff decoder declares at `integration/downbeat-handoff-accepted-versions.json`, so Downbeat reads
both consumers through one file reader. `DownbeatExportAcceptedVersionsTests` keeps the declaration
honest by BEHAVIOUR rather than by reading `DownbeatBridge.minimumVersion`: it re-stamps a committed
fixture with the declared minimum, one below it, and (while there is no ceiling) a far higher
version, and runs the real decoder over each.

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

**Where these names come from, since #2763.** Every file a prep-style run touches (this queue, its
results, the N of M counter, the marker, the cancel sentinel, the chunk directory, the logs, the events
files and their FIFOs, the pid file, the stall state) is named by `RunSlot`, in two halves that must
agree: `mac/Overture/Domain/RunSlot.swift` for the app and `mac/scripts/lib/run-slot.sh` for the runner.
The names above are what the `prep` slot produces, unchanged, and two guards keep it that way: a Swift
one refusing any `appendingPathComponent("prep...")` outside `RunSlot`, and a shell one refusing any
`$SUPPORT/` literal in `prep-run.sh` outside its resolver.

The slot reaches the runner as `OVERTURE_RUN_SLOT`, and an ABSENT value means `prep`. That is a
compatibility contract, not a convenience: the runner script lives in the git checkout rather than the
app bundle, and `update-overture.sh` fast-forwards the checkout before the rebuild, so a new script
routinely meets an app that names no slot. An UNKNOWN value is refused, and the refusal is written to
`runner-launch.log`, which is slot-independent because the slot is what names every other log.

The second slot, `check`, is LIVE as of #2760: the reachability check writes `overture-check-queue.json`,
`overture-check-results.json`, `overture-check-progress.json`, `check-running`, `check-cancel`,
`check-chunks/`, `check-run.log`, `check-run-events.jsonl` and `check-run-archives/`, every one of them
built by `RunSlot` from the same declarations as the prep slot's. The stored state moved with it:
`check.consumedResultsFingerprint` and `checkLastRunStartedAt` in UserDefaults, and a
`DetachedRunActivity` per slot inside the app.

The EXCLUSION between the two is unchanged and still in force. #2760 makes running them at once SAFE;
#2765 is what turns it on, because it owns the one genuine domain conflict (a draft written against a
contact a check is midway through replacing). Both launches go through
`PrepQueueService.runInFlightRefusal`, which asks both slots and names which run is in the way.

One file is deliberately NOT per slot: `reachability-probe-run.json`, which carries the keys a check
covers. Only one check can be alive at a time, so a second marker would be a file nothing could write.
Its OTHER job, telling a finished prep run apart from a finished check, is now needed only for the prep
slot's upgrade-window branch (a check launched by a build older than #2760, still in the prep slot);
#2800 deletes that branch on the evidence of the log line it writes when it is genuinely taken.

#3010: each slot also publishes `<slot>-covers.json`, the shows its live run is holding, so the other
launch can drop the overlap instead of two paid runs both taking one show (#2765). Three things about it
are load-bearing. It is NOT inside the marker, because `mac/scripts/prep-run.sh` truncates that at startup
(`: > "$MARKER"`), so anything written there dies with the run's first second; the heartbeat itself uses
`touch` and would have preserved it, but a design that survives only until somebody re-adds a truncation
is not a design. It is read ONLY through the marker, so a leftover from a run that ended holds nothing.
And the read has THREE answers, not a set-or-nil: a live slot whose covers cannot be read, or has not been
written yet, REFUSES rather than reporting that it holds nothing, because folding those into "excludes
nothing" is fail-open on the one control that stops two paid runs colliding. The runner's EXIT trap
removes it AFTER the marker for the same reason, and `lib/run-slot.test.sh` asserts that order.

#2980: the RUNNER stopped taking its own identity from that file, which is the same rule arriving on the
other side of the boundary. It used to decide it was a check from the marker's mere presence, and the
marker sits in the shared directory for the whole life of a check, so a Prep run started in that window
ran as a check: chunked, on the cheaper model, drafting nothing, and reporting success. Observed on
2026-08-18 during #2762's measurement session. `prep-run.sh` now derives it from `OVERTURE_RUN_SLOT`
(`check` is a check, `prep` never is), and reads the marker only when the run names NO slot, which is
the same upgrade-window branch #2800 deletes. The slot resolver keeps whether the slot was NAMED apart
from what it resolved to, because an absent value and an explicit `prep` are different facts even though
both run in the prep slot.

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
store backups use (`DatedFolderRotation`). #2760: PER SLOT, so a check's pair lands in
`check-run-archives/` with its own rotation. Sharing one folder had two defects in it: a busy night of
checks aged out the prep archives #1616's learner reads, and two runs whose `generatedAt` fell in the
same second collided on the folder name, at which point the second read as already archived and its
evidence was dropped. The folder is named for the RUN, from its own `generatedAt`
rendered in UTC, so the name and the timestamp inside it are the same moment and archiving one run twice
(the app archives at launch and again when it settles a run it watched) lands on the one folder rather
than minting a second copy. The files keep their live names, so anything that can read a live handoff
file can be pointed at an archived run with nothing to translate, and their fixtures and versions above
are therefore the archive's too. A run that produced only half a pair is still archived, with
`archive.log` naming what was missing: a run that went wrong is the one most worth reading later.
`prep-run-events.jsonl` and `prep-run.log` are 300 KB+ each and are deliberately NOT archived; their
retention is a separate decision.

#3357 Phase 1.2 and 1.3 add TWO more dated directories per slot, each with its own keep, and the reason
is the rotation rather than tidiness: `DatedFolderRotation.prune` rotates whole FOLDERS by one keep, so
any folder holding two consumers silently gives one of them a lifetime nobody chose.

- `<slot>-run-event-archives/<stamp>/` holds the raw chunk streams, keep **10**. About 1.7 MB per run
  (measured 2026-09-01 over seven files of 214 to 310 KB). Its reader is a same-week diagnosis of a run
  that went wrong; nobody reads these months later.
- `<slot>-run-attribution-archives/<stamp>/<slot>-run-attribution.json` holds the per item attribution
  SIDECAR, keep **60**, a few KB per run. Written by `record_item_attribution` (`mac/scripts/lib/models.sh`)
  from the same streams the two recorders above read; read by `scripts/what-the-check-searched.sh` to
  say which calls belonged to WHICH show, and by anyone asking whether a run is usable as comparison
  evidence. Version 1.

  Note what the two keeps together mean, so nobody later cites a safety net that is not there: for the
  50 runs between them the sidecar SURVIVES and the streams it was derived from do NOT, so re-deriving
  it for those runs is impossible. The archived derivation is the only copy, which is why it is
  archived rather than recomputed on demand.

  The sidecar also carries `watchdogKills` (#3357 Phase 1.5), appended live by `record_watchdog_kill`
  into `<slot>-run-watchdog-kills.json` and folded in after the run. A killed chunk settles its items as
  unfinished rather than as negatives, so a run with any kill in it is a confound and this is the field
  to read before using one as evidence. `killsReadable` is separate from an empty list, because a run
  with no kills and a record nobody could read leave the same empty result.

All three directories share the run's stamp, so one run is found under one folder name in three places.

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

Queue version 4 (#1122) adds two optional fields to each item for a MULTI-NIGHT run: the run's closing
night, nil for a single-night show, and whether the run is still live with its opening night already
past. Both are on the wire so a draft can pitch a run by the night that is still ahead rather than by
one that has been and gone.

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

Queue version 6 (#1597) adds an optional `alsoAnswersFor` to each item: the OTHER shows this one item
answers for. Set only on a reachability CHECK, where one paid lookup against an organisation settles
every show that organisation presents, so the run reports once and the app fans the answer out. A Prep
run never sets it.

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

Version 4 (#639, #634 Phase A) added an optional `overrideBody` to a `contacts[]` entry: a direct,
second-person draft for that specific contact, meaningful only when its `provenance` is `performer`.
It was what actually got sent to that contact, in place of the shared third-person `draft.body`.

**#3549 RETIRED it, and the reader now ignores the key.** A show has ONE letter, `draft.body`,
addressed to whoever its contacts are (`docs/prep-runbook.md` §2, "Address the one letter to the
people it reaches"). The retirement is a WRITER-side change: no version was bumped, because an older
payload still carrying the key decodes exactly as before and the value is dropped, so nothing that
ever wrote this file became invalid. `v4.json` keeps its `overrideBody` entries as the record of what
version 4 looked like. What enforces the new rule is `src/lib/prepEval.ts`, which FAILS any run that
still emits one, and `OneLetterPerShowTests`, which fails if a second copy reappears in the app.

Why it went: only the send path read it, while the card previewed, edited and badged the shared body,
so an edit Dan made was reported as applied and could never reach the recipient (`LESSONS` L402).
Measured on the live store 2026-09-05 before removing it: 9 contacts held one, 8 of those shows had a
single contact so the body on screen reached nobody, and 30 shows carrying more than one performer had
never had a per-performer letter written at all.

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

Queue version 9 (#1856) adds an optional `onlyTheActIsNamed` to each item: nobody but the ACT is
named on this show, so there is no producing organisation to research and the act itself is the only
party to try. Measured on the live store 2026-07-31, 93 open rows were in that state, 63 of them at one
cabaret room: every venue in that list rents itself out and books a different act a night, so the
listing names the room and the act and never says who is producing. Overture refuses to treat the room
as the producer (#1787), which left the check with no target at all and a run that found nothing.

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

Queue version 11 (#2259) adds an optional `listingCreditedOrg` to each item: the producing company this
show's OWN listing page credits, read by the app out of `showListing.text` (version 8 above). It exists
because `onlyTheActIsNamed` says one thing (the stored presenter field is empty) and the runbook restated
it as a much bigger one ("this listing named no producing organisation at all"). On one show the bigger
claim was false, the page's title line named the company twice, and the run was told there was nothing
to find: eleven web calls on two individuals, and a card reading "No email found".

Queue version 12 (#2392) adds an optional `struckAddresses` to each item: addresses Dan has STRUCK on
this show. Do not research them, do not write to them, do not report them back as contacts. They are on
the wire rather than filtered on the way home because the point is to stop the run SPENDING on an
address he already knew was wrong. His report was a card reading "10 found, 4 reachable" over three
personal accounts and the act's own domain, with the only control anywhere sitting in the draft-review
panel, after the run had been paid for.

Queue version 13 (#2983) adds an optional `presenterName` to each item: the producing organisation the
APP already holds for this show, by name, straight from the stored `presenter`. Until this field the
only thing either builder derived from `presenter` was `onlyTheActIsNamed`, a boolean ABOUT the fact, so
a show credited to a real company handed the run "a producing organisation IS named here" and withheld
WHICH one. On one such show, credited on Dan's own card since 2026-07-22, the check spent 22 web calls
and never searched that name once.

#3310: six of these paragraphs were backfilled on 2026-09-04, having been missing since each version
shipped. The document read as complete, because every version it DID describe was described well, and on
2026-08-30 a planning brief was written from it stating the contract was at v7 and the change in hand
would be v8. It was wrong by six versions and three agents reading the source had to correct it. A
confidently incomplete reference is worse than an obviously incomplete one. `PrepQueueVersionsAreDocumentedTests`
is what stops the next bump shipping undocumented, and it found two more gaps than the issue named on
its first run: #3310 listed 9, 11, 12 and 13, and 4 and 6 were missing too. That is the guard working
rather than the issue having been careless, and it is the reason the class was closed rather than the
six instances.

Results version 11 (#2895) adds an optional `performanceCorroborated` to each contact: does the page named
in `sourceUrl` tie THAT PERSON to THIS performance. Only meaningful for a `performer` contact at `high`,
which is the only place the runbook's rule applies ("only use `high` if the source page corroborates that
person against THIS SPECIFIC performance").

FALSE is the alarming value, deliberately, the same way `nameMatchOnly`'s TRUE is. `ContactConfidenceGuard`
refuses to store such a contact as `high` and records WHICH rule fired, so the card's badge can say whether
the check named no page at all or named one that establishes nobody. Those ask different things of Dan and
one sentence cannot honestly cover both.

ABSENT reads as "nobody has said" and changes nothing (Dan's call, 2026-08-21, matching #2912). That keeps
his queue as it is and lets the check work on the runs that declare it; what it costs is that the rule is
dormant until they do, and `PerformerCorroborationAdoptionTests` measures that rather than leaving it to be
discovered. Measured on this Mac the day it shipped: 48 of 229 contacts are performer contacts claiming
`high`, which is the population the rule can speak about at all.

Additive; the reader's tolerant gate (1 through 11) still accepts `v1.json` through `v10.json` unchanged,
and `v11.json` is the corroboration spec, built from the real 2026-08-17 case with invented people.

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
