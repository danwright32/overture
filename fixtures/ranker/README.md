# Ranker scoring fixture (#490)

Not a `docs/contracts.md` handoff contract: nothing writes or reads this file at runtime.
`Ranker.swift` is a hand port of `ranker.ts` (the app scouts natively; the TypeScript path is a
reference mirror, see `docs/scout-runbook.md`), so the two pure scoring functions need to agree
even though neither one reads the other's output. `cases.json` is the shared spec: each case is a
candidate plus its expected score, tier, and excluded flag, decoded and asserted by both
`src/lib/ranker.test.ts` and `mac/OvertureTests/RankerTests.swift`. A one sided change to either
`PRIOR_RELATIONSHIP_POINTS` (TypeScript) or `Ranker.priorPoints` (Swift) now fails whichever suite
did not make the matching change, instead of drifting silently (the failure class #490 found:
`contacted` scored 3 in TypeScript and 0 in Swift, and the locked ladder's `declined_by_you`,
`warm`, and `lost_soft` tiers, plus the `lost_hard` penalty, existed only on the Swift side).

Covers every tier of the locked relationship ladder (#70) at a neutral baseline, plus a few
combined signal cases (dead zone, a strong self produced dance prospect, and the high tier
threshold boundary) so the fixture exercises more than the one field that drifted.
