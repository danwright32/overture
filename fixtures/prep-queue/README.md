# Prep queue contract fixtures (#157)

`v1.json` is the single source of truth for the Prep work-list
(`~/Library/Application Support/Overture/overture-prep-queue.json`): the kept prospects the app
hands the Prep run to find a contact and draft an email for.

The two sides of this contract are NOT symmetric: Swift WRITES the file (`PrepQueueBuilder.encode`)
and the **Prep Claude Code workflow** READS it (`docs/prep-runbook.md`). There is no second
programmatic reader to assert, so `mac/OvertureTests/PrepQueueContractTests.swift` pins the writer:
the committed fixture must decode to exactly the model the builder round-trips. A change to the
`PrepQueue` shape then fails that test, forcing the runbook + fixture to update in lockstep instead
of the workflow silently reading a work-list it no longer understands (the #109 class of bug).

The fixture exercises both ends of the contract: one fully-populated item and one with every
optional (`venue`, `performanceDate`, `websiteURL`, `sourceListingURL`, `possibleMatchName`)
omitted. `naturalKey` is an opaque token the workflow must echo back verbatim into the results file.

`v1.json` is kept byte-identical as the backward-decode proof. `v2.json` (#586) adds an optional
`production` (`self` / `agency` / `unknown`, from `Prospect.production`/#349) to each item, so the
Prep research step knows whether a show is self-produced before deciding whether to pursue a named
performer directly (#366 Phase 3). Additive, so `v1.json` still decodes with `production` absent
(nil). Both are asserted by `PrepQueueContractTests`.

`v3.json` (#367) adds an optional `reprepMode` (`draft_only` / `contacts_only`, absent means both)
to each item. Set only when Dan asks to re-prep a prospect that already has a draft, so the run
knows to skip the corresponding half instead of redoing everything. Additive, so `v1.json`/`v2.json`
still decode with it absent (nil). Asserted by `PrepQueueContractTests`.
