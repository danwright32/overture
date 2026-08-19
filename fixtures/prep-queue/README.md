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

`v7.json` (#1720) adds an optional RUN-LEVEL `houses`, beside `items` rather than inside them: the
organisations the app has already judged to be the building rather than the act, each as a folded
`key` and one readable `name`. It is the app's answer about the whole store, not a fact about any one
show, which is why it sits at the top level. The run looks a name up here rather than judging it: one
that is NOT on the list gets visited before the run concludes no contact exists, and one that IS on
it is refused exactly as the host venue is. Additive, so `v1.json` through `v6.json` still decode
with it absent. See `docs/contracts.md` for why the judgment is computed in the app rather than
restated in the runbook prompt.

`v8.json` (#1824) adds an optional `showListing` to each item: what the show's OWN listing page says,
rendered by the APP and handed over as text. The Prep run cannot read that page itself (its tool scope
denies every browser tool, and this class of page is drawn client-side), which is how a solo
singer-songwriter's cabaret concert came to be pitched as if the reader were a performing arts
organisation. The fixture carries all three states, because the run says a different thing about each:
`read` with the page's text, `unreadable` (a page we could not read, which is NOT a show with no
description), and absent (there was no page to look at). Additive, so `v1.json` through `v7.json` still
decode with it absent. See `docs/contracts.md` for why the app hands over the page's TEXT rather than
trying to pick the description out of it.

`v9.json` (#1856) adds an optional `onlyTheActIsNamed` to each item: this listing named no producing
organisation at all, so the act itself is the only party to try. Measured on the live store 2026-07-31,
93 open shows are in that state, 63 of them at one cabaret room that books a different act every night.
The room is not the producer, so the run has nothing to research under `groupName` as an organisation,
and it used to hunt for one, find nothing, and report `nothing_published`: a claim about a search it
never ran. On these shows the app also renders the listing page (the `showListing` above), because the
act's name is frequently nowhere else. Additive, and ABSENT IS NOT FALSE: a file predating the field and
an item the app judged to name a producer both leave it out, and neither is a claim.

`v10.json` (#1887) adds an optional `venueHistory` per item: how well Dan already knows THIS room,
as one of `shot_before` / `a_few` / `regularly`. A BAND and never a count, because Dan's rule is
that a pitch never claims an exact number and the reliable way to stop a prompt stating one is to
send it nothing to state (L27).

Note what the fixture's Carnegie item does: it carries NO `venueHistory` at all, even though Dan has
shot Carnegie well over a hundred times. That absence is a decision, not a gap. The runbook already
requires a Carnegie show to lead with the "nearly ten years at Carnegie Hall" tenure credential,
which is about that same room, so a band beside it would be one fact stated twice (Dan's call,
2026-07-31). The app omits the field for Carnegie deliberately, in code, so it cannot drift.

`v11.json` (#2259) adds an optional `organisationNamedOnListing` to each item: the producing company the
show's OWN listing page credits in front of its title, read by the app off `showListing.text`
(`ListingOrganiser`). It rides WITH `onlyTheActIsNamed`, deliberately. That flag means the app stored no
presenter for the row, and the runbook had restated it as "this listing named no producing organisation at
all", which is a claim about the page: on ICB Productions' "Summer Lovin'" the page's title line named the
company twice while the flag was true, and the run was told there was nothing to find. Additive, so every
earlier fixture still decodes with it absent. Absent means the app's narrow parse found no credit, never
that the page names nobody.

`v12.json` (#2392) adds an optional `refusedEmails` to each item: addresses Dan struck on that show
before the run, which it must neither research, write to, nor report back. Additive, so every earlier
fixture still decodes with it absent, and ABSENT is deliberately different from an empty list (almost
every show has nothing to say here, and the run should not be handed a list to reason about). The app
refuses the same addresses again at ingest through the record the strike wrote, so a run that ignores
the field costs money rather than putting somebody back on Dan's card. Asserted by
`PrepQueueContractTests`.

`v13.json` (#2983) adds an optional `presenterOnRecord` to each item: the producing organisation THE APP
ALREADY HOLDS for the show, by name, straight from the stored `presenter`.

It is the fact `onlyTheActIsNamed` had been the flag for. Until v13 that boolean was the ONLY thing either
builder derived from the presenter, so an item saying "a producing organisation IS named here" carried no
name and the run went hunting a producer it could not search for. On a cabaret show credited to a real
theatre company since 2026-07-22, a check spent 22 web calls, never searched that company's name once,
drifted onto a different production of a similarly titled show at another venue, and recorded
`nothing_published` about a company publishing its address on its own contact page. Measured on the live
store the same day, 12 of the 23 shows reading "No email found" were in that state, and four of those
companies appear in no check transcript on the machine at all.

Distinct from `organisationNamedOnListing` (v11) by PROVENANCE, and the two are complementary rather than
alternatives: that one is what the app READ off this show's listing page, and it is only ever read for
`onlyTheActIsNamed == true` items, so it could never reach a show whose producer is named. This one is what
the app was already told by whatever wrote the presenter (a scout, a feed, or Dan).

Note what the fixture's items do. Item 0 carries a name and no `onlyTheActIsNamed`. Item 1 carries
`onlyTheActIsNamed: true` and NO name. That pairing is the point: the flag and the name come from one
predicate (`OrganiserNaming.namedOrganiser`, which `onlyTheActIsNamed` is now defined in terms of), so an
item asserting both is the original defect one layer down, and both `fixtureShape.ts` and
`PrepQueueContractTests` refuse it across every fixture version rather than only this one.

Additive, and absent is not a claim: it means the app holds no producer for that row, which is exactly
`onlyTheActIsNamed`. Never an empty string, because an empty value reads to the run as a named nobody.
