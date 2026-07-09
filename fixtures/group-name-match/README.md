# Group-name match fixture (#492)

`GroupNameMatch.swift` implements the normalization and matching logic used for repeat-client
detection and do-not-contact suppression, the highest-value signal in the product (warm
past-client conversion is roughly 79 percent versus roughly 1.6 percent cold).

`v1.json` is the locked spec for that behavior: a set of `normalize` cases (input string to
expected normalized string) and `match` cases (a pair of names to expected `confident` and
`possible` results), decoded and asserted by `mac/OvertureTests/GroupNameDriftTests.swift`.

This used to also guard a TypeScript mirror (`groupNameMatch.ts`), an independent hand port that
needed to agree with the Swift implementation against this same fixture even though neither read
the other's output. #493 retired that mirror once it was confirmed unused (the app scouts
natively) and no longer needed as a drift guard. The fixture now serves only as Swift's own
locked spec.
