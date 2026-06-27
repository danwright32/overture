# Local file contracts

Overture's pieces (the TypeScript scout engine, the SwiftUI Mac app, and the Claude Code
workflows) never call each other directly. They hand off through fixed-shape JSON files in
`~/Library/Application Support/Overture/`, the same fire-and-forget boundary Downbeat uses for its
export. That boundary is the riskiest seam in the product: a format change on one side that the
other side has not caught up to fails silently in production (the #109 regression, where every
client was silently treated as cold).

The guard against that is a committed sample fixture per contract under `fixtures/`, asserted by a
test on each programmatic side (#113 established it for the Downbeat export; #157, #159, and #166 extended
it to the rest). When a format changes, update the fixture and every side's test in the same change;
a side that has not caught up then fails its test instead of drifting silently. Where one side is a
Claude Code workflow rather than code, there is no automated test for that side, so the fixture plus
the workflow's runbook is its spec.

## Catalog

| File (in app-support dir) | Writer | Reader | Version | Fixture | Tests |
| --- | --- | --- | --- | --- | --- |
| `downbeat-export.json` | Downbeat app (separate repo) | Scout (`parseDownbeatExport`) + App (`DownbeatBridge.decode`) | 1, 2 | `fixtures/downbeat-export/` | `downbeatExportContract.test.ts`, `DownbeatExportContractTests.swift` |
| `overture-history.json` | Importer (`scripts/import-history.ts`) | Scout (`loadLocalHistory`) + App (`[HistoryRecord]`) | none (plain array) | `fixtures/local-history/` | `localHistoryContract.test.ts`, `LocalHistoryContractTests.swift` |
| `overture-results.json` | Scout (`buildResultsFile`) | App (`ResultsFileDecoder.decode`) | 1, 2 | `fixtures/scout-results/` | `resultsContract.test.ts`, `ResultsContractTests.swift` |
| `overture-uncertain.json` | Scout (`buildUncertainPayload`) | Scout refine agent (workflow) | none (plain array) | `fixtures/scout-refine/uncertain.json` | `refineContract.test.ts` (writer) |
| `overture-refined.json` | Scout refine agent (workflow) | Scout (`applyRefinements`) | none (plain array) | `fixtures/scout-refine/refined.json` | `refineContract.test.ts` (reader) |
| `overture-prep-queue.json` | App (`PrepQueueBuilder.encode`) | Prep run (workflow) | 1 | `fixtures/prep-queue/` | `PrepQueueContractTests.swift` |
| `overture-prep-results.json` | Prep run (workflow) | App (`PrepImporter` / `PrepResultsDecoder`) | 1 | `fixtures/prep-results/` | `PrepResultsContractTests.swift` |
| `overture-reply-classify-queue.json` | App (`ReplyClassifyQueueBuilder.encode`) | Classify run (workflow) | 1 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-reply-classify-results.json` | Classify run (workflow) | App (`ReplyClassifyResultsDecoder`) | 1 | `fixtures/reply-classify/` | `ReplyClassifyContractTests.swift` |
| `overture-voice-feedback.json` | App (`VoiceFeedbackBuilder.encode`) | Prep run (workflow) | 1 | `fixtures/voice-feedback/` | `VoiceFeedbackContractTests.swift` |

"Scout" is the TypeScript engine (`src/lib/`, `scripts/scout/run-scout.ts`). "App" is the SwiftUI
Mac app (`mac/Overture/`). "Workflow" is a Claude Code run on Dan's Max plan, not code.

## Per contract

### `downbeat-export.json`

Downbeat's export of past clients, venues, committed bookings, and blocked dates. The only contract
with two code readers (the scout and the app both consume it), so the same fixture is decoded by
both. The canonical spec lives in the Downbeat repo at
`Downbeat/Downbeat/Integration/OvertureExport/CONTRACT.md`; if the Overture decoders ever drift,
that file wins. Match on `clientId` (the stable org identity), never `clientDisplayName`. `bookings`
and `blockedDates` start empty and only fill from bookings made through the app going forward.

### `overture-history.json`

Past booking history (`{ groupName, status }`), so repeat-client matching and do-not-contact
suppression work before the app has its own activity. A two-reader contract: the scout reads it
through `loadLocalHistory`, which maps the app's camelCase shape to the matcher's snake_case
(`{ group_name, status }`), and the app reads it through `[HistoryRecord]`. Skipping that mapping
silently reads `undefined` and matches nothing (the core of #104), so the shared fixture is decoded
by both readers (#166). `status` may be null; an unrecognized status reads as cold.

### `overture-results.json`

The ranked prospects the scout writes and the app ingests, upserting by natural key so Dan's
keep/dismiss decisions survive a re-run. The writer pipeline (serialize, collapse multi-night runs,
sort) is `buildResultsFile` (`src/lib/resultsContract.ts`), kept pure so the writer side is testable.
Version 2 added the run-collapse fields; the reader's tolerant version gate (1 through 2) accepts the
older shape and defaults the missing fields.

### `overture-uncertain.json` and `overture-refined.json`

The scout's round trip with the refine agent. The scout writes `uncertain.json` (only the events the
rules left `uncertain`, via `buildUncertainPayload`); the agent re-judges that slice and writes
`refined.json`; the scout merges it back with `applyRefinements` and marks those events confident.
The `title` is the opaque join key the agent must echo back verbatim. The agent is the counterpart
side with no automated test, so `fixtures/scout-refine/` is its spec (see `docs/scout-runbook.md`).

### `overture-prep-queue.json` and `overture-prep-results.json`

The app's round trip with the Prep run. The app writes `prep-queue.json` (the kept-undrafted
prospects that need a contact and a draft, via `PrepQueueBuilder.encode`); the Prep run reads it,
does the research and drafting, and writes `prep-results.json`; the app ingests that through
`PrepImporter`, moving prospects to `drafted` for Dan to review. The `naturalKey` is the opaque join
key the run must echo back verbatim, never rebuild. The Prep run is the counterpart side with no
automated test, so `fixtures/prep-queue/` and `fixtures/prep-results/` are its spec (see
`docs/prep-runbook.md`).

### `overture-reply-classify-queue.json` and `overture-reply-classify-results.json`

The app's round trip with the reply-classify run (#112). The app writes the queue (kept replies, each
with the captured `replyText`, via `ReplyClassifyQueueBuilder.encode`); the classify workflow reads
it, judges each reply's intent (`ReplyIntent`: interested / wants_to_book / has_question / declined),
and writes the results; the app ingests them and suggests the conversation state (auto). The
`naturalKey` is the opaque join key the run must echo back verbatim. The classify run is the
counterpart side with no automated test, so `fixtures/reply-classify/` is its spec (runbook added in
the workflow phase).

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
