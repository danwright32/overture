# Prep progress contract fixtures (#354)

`v1.json` is the single source of truth for the Prep progress handoff
(`~/Library/Application Support/Overture/overture-prep-progress.json`): how far a live Prep run has
gotten through its queue, so the toolbar can show real "N of M" progress instead of an indefinite
spinner.

The two sides of this contract are NOT symmetric: `mac/scripts/prep-run.sh` seeds the file (writing
`{"version":1,"total":<queue length>,"completed":0}` before launching the Prep workflow), then the
**Prep Claude Code workflow** (`docs/prep-runbook.md`) updates `completed` as it finishes each item;
Swift only READS it (`PrepProgressDecoder`). There is no second programmatic writer to assert, so
`mac/OvertureTests/PrepProgressContractTests.swift` pins the Swift decode and this fixture is the
canonical example the runbook points the workflow at. A change to the `PrepProgress` shape then fails
that test, forcing the runbook + fixture to update in lockstep instead of the workflow silently
writing a file the app can't read (the #109 class of bug).

`total` is fixed for the run (the queue's item count, seeded by the shell script, never rewritten by
the workflow); `completed` only ever increases, one at a time, as each item finishes. The file is
overwritten wholesale on every update, never partially patched, so a reader never sees a half-written
value from one field and a stale value from another. Best-effort on the Swift side: a missing,
malformed, or mid-write file reads as "no progress to show" rather than an error, since the workflow
may be writing it at the exact moment the toolbar polls.
