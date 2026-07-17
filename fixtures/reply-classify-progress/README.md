# Reply-classify progress contract fixtures (#1081)

`v1.json` is the single source of truth for the reply-classify progress handoff
(`~/Library/Application Support/Overture/overture-reply-classify-progress.json`): how far a live
reply-classify + reply-drafter run has gotten through its queue, so the reply drafter's "Drafting a
reply" label can show real "N of M" progress instead of a bare spinner.

The two sides of this contract are NOT symmetric, and (as of #1081) there is only ONE writer:
`mac/scripts/reply-classify-run.sh` seeds the file (writing `{"version":1,"total":<queue length>,
"completed":0}` before launching the run), then DERIVES every update from
`overture-reply-classify-results.json` itself, by counting its `results[]` entries with
`lib/progress-watcher.sh`'s `update_progress_from_results` (the same helper prep and scout use). The
Claude Code workflow never writes this file: asking a model to self-report a count is the exact design
that left scout's counter stuck at 0 through a live run on 2026-07-16 (#1015), so the script owns it.
Swift only READS it (`ReplyClassifyProgressDecoder`).

`total` is fixed for the run (the queue's item count, seeded by the shell script, never rewritten);
`completed` only ever increases, one at a time, as each item lands in the results file. The file is
overwritten wholesale on every update, never partially patched, so a reader never sees a half-written
value from one field and a stale value from another. Best-effort on the Swift side: a missing,
malformed, or mid-write file reads as "no progress to show" rather than an error, since the run may be
writing it at the exact moment the label polls.
