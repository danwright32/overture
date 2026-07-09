# Ranker scoring fixture (#490)

Not a `docs/contracts.md` handoff contract: nothing writes or reads this file at runtime.
`cases.json` is the locked spec for the relationship-ranking ladder: each case is a candidate plus
its expected score, tier, and excluded flag, decoded and asserted by `mac/OvertureTests/RankerTests.swift`.

This used to also guard a TypeScript mirror (`ranker.ts`), a hand port of `Ranker.swift` that
needed to agree with it even though neither read the other's output; #493 retired that mirror
once it was confirmed unused (the app scouts natively) and already drifting (the failure class
#490 found: `contacted` scored 3 in TypeScript and 0 in Swift, and the locked ladder's
`declined_by_you`, `warm`, and `lost_soft` tiers, plus the `lost_hard` penalty, existed only on
the Swift side). The fixture now serves only as Swift's own locked spec, not a cross-language
drift guard.

Covers every tier of the locked relationship ladder (#70) at a neutral baseline, plus a few
combined signal cases (dead zone, a strong self produced dance prospect, and the high tier
threshold boundary) so the fixture exercises more than the one field that drifted.
