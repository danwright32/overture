# Prep results contract fixtures (#157)

`v1.json` is the single source of truth for the Prep results handoff
(`~/Library/Application Support/Overture/overture-prep-results.json`): for each kept prospect, the
contact the Prep run found and the email it drafted.

The two sides of this contract are NOT symmetric: the **Prep Claude Code workflow** WRITES the file
(`docs/prep-runbook.md`) and Swift READS it (`PrepResultsDecoder`). There is no second programmatic
writer to assert, so `mac/OvertureTests/PrepResultsContractTests.swift` pins the Swift decode and
this fixture is the canonical example the runbook points the workflow at. A change to the
`PrepResults` shape then fails that test, forcing the runbook + fixture to update in lockstep
instead of the workflow silently writing a file the app can't ingest (the #109 class of bug).

The fixture exercises the contract's edge cases: a full result (named decision-maker contact + a
drafted email with a recorded `variant`), a contact-only result (no draft yet, and the contact's
own optionals omitted), and a bare result (just the echoed `naturalKey`, no contact or draft).
