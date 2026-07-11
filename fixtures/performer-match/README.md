# Performer-name match fixture (#749, plan #748, issue #585)

Repeat-client detection has always matched on the org or group name only, so a performance whose
group name is new but whose *performer* is someone Dan has already shot scored as a cold lead
(#585). `HistoryMatch.matchPerformer` closes that gap at Prep time: it matches a performer's name
against the canonical Downbeat clients and the imported booking history, and returns a positive
relationship when it is confident.

`v1.json` is the locked spec for that behavior, decoded and asserted by
`mac/OvertureTests/PerformerMatchTests.swift`. It carries a `clients` list, a `history` list, and a
`cases` table of inputs (performer name, performer email, production) to the expected verdict.

Three properties this fixture exists to hold still, because each one is load-bearing and easy to
regress by "improving" the matcher:

1. **Person names are matched more strictly than org names.** `GroupNameMatch.isConfident` accepts
   token *containment* (so "New York Ballet" matches "New York Theatre Ballet"), which is right for
   orgs and wrong for people: it would match the person "Jane Doe" to the org "Jane Doe Ensemble".
   The person-name path requires full token-set equality instead. Token *order* still does not
   matter, so a surname-first program listing ("Vega, Marisol") matches.
2. **A conflicting email suppresses an otherwise-good name match.** Two different people share a
   name more often than one person changes their email, so a mismatch between the performer's email
   and the address on file for that Downbeat client is treated as evidence against the match, and
   nothing is auto-corrected (Dan's call, precision-first). An empty address on either side is not a
   conflict; the name alone decides.
3. **This path can never suppress a performance.** It is positive-match-only by construction: the
   verdict has no `suppressed` field, so a do-not-contact record reached through a performer name
   neither drops the performance nor lends it a positive relationship. Do-not-contact suppression
   remains the org-level `HistoryMatch.matchRelationship`'s job alone.

The production gate is enforced inside the matcher rather than at the call site: an agency-produced
or unknown-production performance returns no match without ever being compared, so a future caller
cannot forget to check.

Sibling of `fixtures/group-name-match/`, which locks the org-name matcher this one deliberately
diverges from. Neither is a cross-language contract (see `docs/contracts.md` for those); both are
internal locked specs for Swift logic that is too important to let drift silently.
