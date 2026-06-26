# Reply classify contract fixtures (#183 / #112)

These two files are the single source of truth for the reply-classification handoff in
`~/Library/Application Support/Overture/`:

- `queue.json` is what the app WRITES (`overture-reply-classify-queue.json`, via
  `ReplyClassifyQueueBuilder`): the kept replies for the classify workflow to read.
- `results.json` is what the **Claude Code classify workflow** WRITES back
  (`overture-reply-classify-results.json`); the app READS it via `ReplyClassifyResultsDecoder`.

The workflow is the counterpart side with no automated test, so these committed fixtures (plus the
runbook, once added in Phase 4) are its spec. `mac/OvertureTests/ReplyClassifyContractTests.swift`
pins the Swift side: the queue fixture decodes to exactly what the builder encodes (round-trip), and
the results fixture decodes to the agreed shape. `naturalKey` is an OPAQUE token the workflow must
echo back verbatim, never rebuild (the silent-mismatch trap). `intent` is a `ReplyIntent` raw value
(`interested` / `wants_to_book` / `has_question` / `declined`), tolerated as a string so an unknown
value decodes rather than throwing. The queue fixture exercises both an item with a venue and one
with it omitted.
