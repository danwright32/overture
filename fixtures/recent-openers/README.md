# `overture-recent-openers.json` fixture

The cross-run anti-repetition handoff (#730). The **app writes** it (when a Prep run launches) and the
**Prep drafter workflow reads** it (docs/prep-runbook.md §2) so a run steers away from the opening
sentences recent runs already used. One-sided contract: the reader is a Claude Code workflow, not
code, so this fixture plus the prep runbook is its spec.

`v1.json` pins the wire shape `RecentOpenersBuilder.encode` emits: a versioned envelope plus an array
of recently-used openers (the first sentence of a recently drafted body), newest first, deduped, and
capped at 15. Each opener carries its opaque `naturalKey`, `discipline`, the `opener` text, and the
`usedAt` timestamp it is ordered by. It is a list of shapes to AVOID, never a source of facts: the
runbook forbids lifting any specific out of it. Asserted by `RecentOpenersContractTests`. When the
shape changes, update the fixture and the test in the same change.
