# Reply classify contract fixtures (#183 / #112)

These two files are the single source of truth for the reply-classification handoff in
`~/Library/Application Support/Overture/`:

- `queue.json` is what the app WRITES (`overture-reply-classify-queue.json`, via
  `ReplyClassifyQueueBuilder`): the kept replies for the classify workflow to read.
- `results-v1.json` is what the **Claude Code classify workflow** WRITES back
  (`overture-reply-classify-results.json`); the app READS it via `ReplyClassifyResultsDecoder`.

The workflow is the counterpart side with no automated test, so these committed fixtures (plus the
runbook, once added in Phase 4) are its spec. `mac/OvertureTests/ReplyClassifyContractTests.swift`
pins the Swift side: the queue fixture decodes to exactly what the builder encodes (round-trip), and
the results fixture decodes to the agreed shape. `naturalKey` is an OPAQUE token the workflow must
echo back verbatim, never rebuild (the silent-mismatch trap). `intent` is a `ReplyIntent` raw value
(`interested` / `wants_to_book` / `has_question` / `declined`), tolerated as a string so an unknown
value decodes rather than throwing. The queue fixture exercises both an item with a venue and one
with it omitted.

`queue-v1.json` / `results-v1.json` are the v1 shape (kept byte-identical as the backward-decode proof).
They carry their version in the name like every other fixture: an unversioned name is refused rather than
read as version 1 (#2340).
`queue-v2.json` / `results-v2.json` are version 2 (#392): each item and result gains an optional
`recipientId`, the opaque per-recipient token the workflow echoes back so a reply attaches to the
right recipient on a multi-recipient show. It is additive, so the tolerant gate (1 through 2) decodes
both; in the v1 files `recipientId` is simply absent (decodes to nil).

`results-v3-as-written.json` is version 3 in the shape the runner ACTUALLY writes, and it exists because
every other file here was shaped to satisfy the reader rather than measured from a real run (L48, L52).
Its top-level keys are exactly `model`, `results` and `version`, read off the live
`overture-reply-classify-results.json` on 2026-08-17: no `generatedAt`. `ReplyClassifyResults` declared
that field non-optional, so the synthesized decoder required it, `ReplyClassifyResultsDecoder.decode`
threw on every real file, the throw was discarded by a `try?`, and every AI reply draft Overture produced
was dropped in silence (#2873). All six files here carried the field, so this suite stayed green
throughout. Its CONTENT is invented, like every fixture in this repo: only the key shape is measured, and
no real contact ever goes in a fixture.
