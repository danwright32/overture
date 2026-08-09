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
keeps the legacy single-`contact` shape as the proof that the custom `init(from:)` still maps a v1
singular `contact` to a one-element `contacts[]`. Its draft body is salutation-free (#393): the app
owns the greeting at send, so no fixture body carries an inline "Hi <name>,".

`v2.json` (version 2, #392) exercises `contacts[]`, one entry per party to email, each with a
`provenance` (`act` / `presenter`, never the host venue). It exercises a performance with both an act
and a presenter, plus a form-only act with no email.

`v3.json` (version 3, #587) exercises a performer-only self-produced show: adds `performer` to the
`provenance` vocabulary, a named individual performer on a self-produced show, distinct from `act` (a
single-act waterfall result).

`v4.json` (version 4, #639) adds an optional `overrideBody` to a `contacts[]` entry, a direct
second-person draft for that specific contact, meaningful only when its `provenance` is `performer`.
It exercises a performer contact carrying an `overrideBody` alongside a presenter contact with none,
under one shared third-person `draft.body`.

`v5.json` (version 5, #611) adds an optional `alreadyCoveredNote` on the result itself: a fit-risk
flag Prep's own research found (the org's site already names its own photographer), surfaced to Dan
so he can deprioritize or skip without the show's fit score/tier changing. It exercises a presenter
contact whose result carries the note alongside a normal draft.

`v6.json` (version 6, #363) is the current shape new runs MUST write: adds an optional `sourceUrl` to
a `contacts[]` entry, the page the run actually read a high-confidence contact from, so the app's
confidence badge can link Dan through to verify it himself. Distinct from `formUrl`, which stays the
`form_or_dm` contact's own submission link; only ever meaningful at `confidence == "high"`. It
exercises a high-confidence act contact carrying a `sourceUrl` alongside a medium-confidence presenter
contact with none.

`v8.json` (#1824) adds an optional `showSummary` on the result itself, one plain line saying what the show
IS as read from the listing text the app handed over, plus a `showSummaryAbsentReason` that is REQUIRED
whenever there is no summary (`no_listing_page` / `page_unreadable` / `no_description_published`). The
fixture carries a summary, an honest absence beside a real draft, and an absence on an entry with no
contacts at all. Additive, so `v1.json` through `v7.json` still decode with both absent. The absent-reason
vocabulary is enforced by `assertPrepResultsShape`, which also refuses a v8 entry carrying neither.

## The run metadata fixtures (#1678)

`run-metadata-complete-v8.json` and `run-metadata-partial-v8.json` are a different KIND of fixture from the
`vN.json` files above. They are not a new version of the results shape: they carry the three top-level keys
`prep-run.sh` adds AFTER the workflow has finished with the file, through `lib/models.sh`, which the app's
decoder ignores entirely. `model` (#1533) names the model that actually ran, `runCost` (#1593) the dollars
and wall clock, `webCalls` (#1864) the web lookups against the run's allowance. Both files use `v8.json`'s
results as their base, so the results half is the current shape.

What they exist to pin is the honest/partial split, which is the same split twice:

- `run-metadata-complete-v8.json`: every stream reported, so `runCost` carries `usd` and `durationMs` and
  `webCalls` carries `total` and `denied`.
- `run-metadata-partial-v8.json`: one of three chunks died and left no envelope, so `runCost` carries NEITHER
  `usd` NOR `durationMs`, and `webCalls` carries neither `total` nor `denied`. Only the `partial*` keys, plus
  how many streams reported out of how many. A reader reaching for the field it always reads finds nothing
  rather than a part of the total presented as the whole.

**Where the numbers come from.** The cost and call figures are the run measured on the live store on
2026-08-07 (`usd` 5.395423, longest stream 389906ms, 3 streams, 59 web calls split 28 fetch and 31 search),
reproduced by feeding those values through the real writers rather than typed in. The counts that depend on
the results file (`items`, `parties`, `allowance`, and therefore the `overCap` verdict) come from `v8.json`'s
three results, so the complete fixture sits OVER its allowance and says so, while the partial one is under it
and stays silent, which is the rule for that verdict.

The refusal counts (#1835) are zero here because that run had none, and they are left at zero rather than
invented: a figure shaped to make a rule fire is a fixture defending a shape nobody measured (L48). The real
refusals that this counting was built from are in the 2026-07-27 Debug run
(`prep-run-events.chunk-1.jsonl` and `chunk-3.jsonl`), one refused `mcp__playwright__browser_navigate` in
each. What these two files pin is that `denied` and `partialDenied` obey the same honest/partial split as
`total`, and that every route appears even at zero.

`lib/models.test.sh` regenerates both through `record_model`, `record_run_cost` and `record_web_calls` on
every run and compares the key sets against what is committed here, so neither file can drift into a shape
its writer does not produce. `PrepResultsRunMetadataContractTests.swift` asserts the split itself.
