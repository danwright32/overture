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

`v1.json` (version 1) exercises the legacy single-`contact` shape's edge cases: a full result (named
decision-maker contact + a drafted email with a recorded `variant`), a contact-only result (no draft
yet, and the contact's own optionals omitted), a bare result (just the echoed `naturalKey`, no
contact or draft), and a form-only act (a `form_or_dm` contact with a `formUrl` and no email). It
stays byte-identical as the proof that the custom `init(from:)` still maps a v1 singular `contact` to
a one-element `contacts[]`.

`v2.json` (version 2, #392) is the current shape new runs MUST write: `contacts[]`, one entry per
party to email, each with a `provenance` (`act` / `presenter`, never the host venue). It exercises a
performance with both an act and a presenter, plus a form-only act with no email.
