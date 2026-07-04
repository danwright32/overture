# Group-name match cross-language fixture (#492)

`groupNameMatch.ts` and `GroupNameMatch.swift` are two independent hand ports of the same
normalization and matching logic used for repeat-client detection and do-not-contact
suppression, the highest-value signal in the product (warm past-client conversion is roughly
79 percent versus roughly 1.6 percent cold). They are not a writer/reader file handoff like the
contracts in `docs/contracts.md`; each side runs its own copy of the same algorithm against its
own in-memory strings, so there is no wire-format fixture to guard, only the two implementations'
behavior.

`v1.json` is the shared source of truth for that behavior: a set of `normalize` cases (input
string to expected normalized string) and `match` cases (a pair of names to expected `confident`
and `possible` results). Both sides decode the SAME file and assert the SAME expected values
against their OWN implementation:

- TypeScript: `src/lib/groupNameMatchContract.test.ts`
- Swift: `mac/OvertureTests/GroupNameDriftTests.swift`

A change to either side's normalization or matching logic that is not mirrored on the other side
fails that side's suite against this fixture instead of silently reclassifying a warm client as
cold with nothing catching it.
