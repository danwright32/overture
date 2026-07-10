import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Prep results import")
struct PrepImporterTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func keptProspect(_ ctx: ModelContext, group: String, date: String, venue: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    @Test func fillsContactAndDraftAndMarksDrafted() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Indianapolis Children's Choir", date: "2026-06-24", venue: "Stern Auditorium / Perelman Stage")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: "Jane Doe", role: "Artistic Director", email: "jane@choir.org",
                                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                                              provenance: "act")],
                       draft: PrepDraft(subject: "Photographing your Carnegie performance", body: "Hi Jane,\n...", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)
        #expect(outcome.matched == 1)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        // The single contact becomes recipients[0].
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.email == "jane@choir.org")
        #expect(p?.recipients.first?.provenance == .act)
        #expect(p?.recipients.first?.name == "Jane Doe")
        #expect(p?.recipients.first?.contactConfidenceRaw == "high")
        #expect(p?.recipients.first?.contactMethodRaw == "named_decision_maker")
        #expect(p?.draftSubject == "Photographing your Carnegie performance")
        #expect(p?.hasDraft == true)
        #expect(p?.status == .drafted)
    }

    @Test func reportsUnmatchedKeysInsteadOfSilentlyDropping() throws {
        let ctx = ModelContext(try container())
        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: "ghost|2026-01-01|nowhere",
                       draft: PrepDraft(subject: "x", body: "y", variant: nil))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)
        #expect(outcome.matched == 0)
        #expect(outcome.unmatchedKeys == ["ghost|2026-01-01|nowhere"])
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
    }

    @Test func reIngestDoesNotClobberAHandEditedDraft() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Indianapolis Children's Choir", date: "2026-06-24", venue: "Stern Auditorium / Perelman Stage")

        // First Prep run drafts it; Dan edits the draft.
        let firstRun = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, draft: PrepDraft(subject: "S1", body: "B1", variant: "A"))
        ])
        _ = PrepImporter.ingest(firstRun, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        p?.draftBody = "Dan's hand-tuned version"
        p?.draftEditedByDan = true
        try ctx.save()

        // A second Prep run must NOT overwrite Dan's edit.
        let secondRun = PrepResults(version: 2, generatedAt: "later", results: [
            PrepResult(naturalKey: key, draft: PrepDraft(subject: "S2", body: "B2 regenerated", variant: "B"))
        ])
        let outcome = PrepImporter.ingest(secondRun, into: ctx)

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(after?.draftBody == "Dan's hand-tuned version")
        #expect(after?.draftEditedByDan == true)
        #expect(outcome.skippedEdited == 1)
    }

    // v2 (#392): a performance can carry the act plus a presenter; each becomes its own recipient
    // with its provenance preserved, while the legacy mirror tracks the act for the current UI.
    @Test func ingestsMultipleContactsAsRecipientsWithProvenance() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: "Manager", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act"),
                PrepContact(name: "Lou", role: "Presenting Director", email: "lou@presenter.example",
                            method: "named_decision_maker", confidence: "medium", formUrl: nil, provenance: "presenter"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 2)
        #expect(p?.recipients.first(where: { $0.provenance == .act })?.email == "emma@act.example")
        #expect(p?.recipients.first(where: { $0.provenance == .presenter })?.email == "lou@presenter.example")
    }

    // A form-only act (#368) still becomes a recipient (no email, id keyed on the form URL) so it
    // shows in the list; Dan adds an email later if the act replies to his form submission.
    @Test func formOnlyContactBecomesARecipientWithNoEmail() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Ivalas Quartet", date: "2026-07-01", venue: "Madison Square Park")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Ivalas Quartet", role: nil, email: nil, method: "form_or_dm",
                            confidence: "low", formUrl: "https://www.ivalasquartet.com/contact", provenance: "act"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.email == nil)
        #expect(p?.recipients.first?.id == "form:https://www.ivalasquartet.com/contact")
        #expect(p?.recipients.first?.contactFormURL == "https://www.ivalasquartet.com/contact")
    }

    // A re-run is idempotent on the same contact (matched by id) and never duplicates a recipient.
    @Test func reIngestUpsertsTheSameContactInPlace() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        let run = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: "Manager", email: "emma@act.example",
                            method: "generic_inbox", confidence: "low", formUrl: nil, provenance: "act"),
            ])
        ])
        _ = PrepImporter.ingest(run, into: ctx)
        // Second run corrects the role/confidence for the same email.
        let run2 = PrepResults(version: 2, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma Robinson", role: "Director", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act"),
            ])
        ])
        _ = PrepImporter.ingest(run2, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.name == "Emma Robinson")
        #expect(p?.recipients.first?.role == "Director")
    }

    // recipientsEditedByDan is a freeze SEPARATE from draftEditedByDan: once Dan has curated the
    // recipient list (manual add/remove, Phase 7), a re-run must not clobber it, even while a body
    // redraft still flows.
    // #408 / #409: a form-only recipient that later gains an email via a Prep re-run must keep the
    // SAME row (matched by its form URL), not spawn a duplicate.
    @Test func aFormOnlyRecipientGainingAnEmailKeepsTheSameRow() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Ivalas Quartet", date: "2026-07-01", venue: "Madison Square Park")
        let form = "https://www.ivalasquartet.com/contact"

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Ivalas Quartet", role: nil, email: nil, method: "form_or_dm",
                            confidence: "low", formUrl: form, provenance: "act"),
            ])
        ]), into: ctx)
        // The act later replies to the form submission, so a re-run has a real email for it.
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Ivalas Quartet", role: "Manager", email: "hello@ivalas.example",
                            method: "named_decision_maker", confidence: "high", formUrl: form, provenance: "act"),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.email == "hello@ivalas.example")
        #expect(p?.recipients.first?.id == "hello@ivalas.example")
        #expect(p?.recipients.first?.contactFormURL == form)
    }

    // The plain corrected-email path (no form URL): a re-run with a different email for the same
    // pending act updates that row in place rather than duplicating.
    @Test func aCorrectedEmailUpdatesThePendingActInPlace() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: nil, email: "old@act.example", method: nil,
                            confidence: nil, formUrl: nil, provenance: "act"),
            ])
        ]), into: ctx)
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: nil, email: "new@act.example", method: nil,
                            confidence: nil, formUrl: nil, provenance: "act"),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.email == "new@act.example")
    }

    // #408: a batch that (unexpectedly) carries two contacts of the same provenance must not let the
    // second one grab and overwrite the first's freshly created recipient through the pending-match
    // fallback, which otherwise cannot tell the two apart and silently collapses them into one row.
    @Test func twoSameProvenanceContactsInOneBatchDoNotMergeIntoOneRecipient() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: "Manager", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act"),
                PrepContact(name: "Understudy", role: "Manager", email: "understudy@act.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 2)
        let emails = Set(p?.recipients.compactMap(\.email) ?? [])
        #expect(emails == ["emma@act.example", "understudy@act.example"])
    }

    // #597 (#366 Phase 2/3): the same #408 guard, but for two named performers instead of two act
    // contacts — a self-produced show with a soloist/duo is exactly the case a batch of two
    // same-provenance contacts is now expected, not just an unexpected act-batch edge case.
    @Test func twoPerformerContactsInOneBatchDoNotMergeIntoOneRecipient() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Midnight Quartet", date: "2026-08-15", venue: "Weill Recital Hall")

        let results = PrepResults(version: 3, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Maya Chen", role: "Founder & Artistic Director", email: "maya@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "performer"),
                PrepContact(name: "Jules Ortiz", role: nil, email: "jules@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "performer"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 2)
        let emails = Set(p?.recipients.compactMap(\.email) ?? [])
        #expect(emails == ["maya@performer.example", "jules@performer.example"])
    }

    // SUP-017: an already-sent recipient's address is locked (existing rule); a later Prep run that
    // finds a "corrected" email for the same provenance must not append a second recipient either,
    // since id match and pending match both miss a sent row and would otherwise fall through to create.
    @Test func aCorrectedEmailForAnAlreadySentActNeverCreatesADuplicate() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: nil, email: "old@act.example", method: nil,
                            confidence: nil, formUrl: nil, provenance: "act"),
            ])
        ]), into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        p?.recipients.first?.sendState = .sent
        try ctx.save()

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: nil, email: "new@act.example", method: nil,
                            confidence: nil, formUrl: nil, provenance: "act"),
            ])
        ]), into: ctx)

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(after?.recipients.count == 1)
        #expect(after?.recipients.first?.email == "old@act.example")
        #expect(after?.recipients.first?.sendState == .sent)
    }

    @Test func recipientsEditedByDanFreezeIsNotClobberedByAReRun() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        p?.setRecipients([Recipient(id: "dan@manual.example", email: "dan@manual.example", provenance: .manual)])
        p?.recipientsEditedByDan = true
        try ctx.save()

        let run = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: "Emma", role: nil, email: "emma@act.example",
                                              method: nil, confidence: nil, formUrl: nil, provenance: "act")],
                       draft: PrepDraft(subject: "S", body: "B", variant: nil))
        ])
        let outcome = PrepImporter.ingest(run, into: ctx)

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        // Dan's curated list survives untouched...
        #expect(after?.recipients.count == 1)
        #expect(after?.recipients.first?.email == "dan@manual.example")
        #expect(outcome.skippedRecipientEdits == 1)
        // ...but the independent draft freeze still let the body through.
        #expect(after?.draftBody == "B")
    }

    // #587 (#366 Phase 2): a named individual performer on a self-produced show becomes its own
    // recipient with `.performer` provenance, distinct from the act-waterfall `.act` case.
    @Test func ingestsAPerformerContactAsItsOwnRecipient() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")

        let results = PrepResults(version: 3, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma Robinson", role: nil, email: "emma@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "performer"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.provenance == .performer)
        #expect(p?.recipients.first?.email == "emma@performer.example")
    }

    // v4 (#640, #634 Phase B): a performer contact's own direct-address `overrideBody` lands on its
    // matching recipient, so a send to them can prefer it over the shared third-person draft body.
    @Test func ingestsAPerformerContactWithOverrideBodyOntoItsRecipient() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Midnight Quartet", date: "2026-08-15", venue: "Weill Recital Hall")

        let results = PrepResults(version: 4, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Maya Chen", role: nil, email: "maya@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "performer", overrideBody: "I saw you're self-presenting..."),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.overrideBody == "I saw you're self-presenting...")
    }

    // A re-run that doesn't repeat overrideBody for the same still-performer contact must not erase
    // the existing one (the normal "never clobber on a nil field" convention), same as name/role.
    @Test func reIngestWithoutOverrideBodyPreservesTheExistingOneForAStillPerformerContact() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Midnight Quartet", date: "2026-08-15", venue: "Weill Recital Hall")

        _ = PrepImporter.ingest(PrepResults(version: 4, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Maya Chen", role: nil, email: "maya@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "performer", overrideBody: "First draft, direct address."),
            ])
        ]), into: ctx)
        // Second run corrects the role only, omitting overrideBody.
        _ = PrepImporter.ingest(PrepResults(version: 4, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Maya Chen", role: "Founder", email: "maya@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "performer", overrideBody: nil),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.role == "Founder")
        #expect(p?.recipients.first?.overrideBody == "First draft, direct address.")
    }

    // A contact reclassified AWAY from `.performer` on a later run (a research correction, or the
    // show's `production` field changing) must have any stale overrideBody CLEARED, not preserved:
    // overrideBody is only ever meaningful for a `.performer` recipient, so leftover second-person
    // text on a now-generic act/presenter contact would be the same mail-merge-style mistake this
    // whole fix exists to prevent, just triggered by a reclassification instead of the first draft.
    @Test func reclassifyingAwayFromPerformerClearsAnyStaleOverrideBody() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Midnight Quartet", date: "2026-08-15", venue: "Weill Recital Hall")

        _ = PrepImporter.ingest(PrepResults(version: 4, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Maya Chen", role: nil, email: "maya@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "performer", overrideBody: "I saw you're self-presenting..."),
            ])
        ]), into: ctx)
        // A later run decides this is really the act's own contact, not a directly-addressed performer.
        _ = PrepImporter.ingest(PrepResults(version: 4, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Maya Chen", role: nil, email: "maya@performer.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", overrideBody: nil),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.provenance == .act)
        #expect(p?.recipients.first?.overrideBody == nil)
    }

    @Test func decodesAndVersionGates() throws {
        let json = """
        {"version":1,"generatedAt":"now","results":[{"naturalKey":"k","contact":null,"draft":{"subject":"s","body":"b"}}]}
        """
        let decoded = try PrepResultsDecoder.decode(Data(json.utf8))
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].draft?.subject == "s")

        #expect(throws: PrepResultsError.unsupportedVersion(6)) {
            try PrepResultsDecoder.decode(Data(#"{"version":6,"generatedAt":"x","results":[]}"#.utf8))
        }
        // Below the minimum is rejected too — the gate is a closed range, not an exact match (#140).
        #expect(throws: PrepResultsError.unsupportedVersion(0)) {
            try PrepResultsDecoder.decode(Data(#"{"version":0,"generatedAt":"x","results":[]}"#.utf8))
        }
    }

    // #617: a real save() failure (not just the source-scan guard in ImporterSaveGuardTests),
    // via ImmutableStoreFixture.
    @Test func ingestReportsSaveFailedOnAGenuineSaveFailure() async throws {
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24", venue: "Stern Auditorium / Perelman Stage")
        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self]),
            seed: { _ = self.keptProspect($0, group: "Indianapolis Children's Choir",
                                          date: "2026-06-24", venue: "Stern Auditorium / Perelman Stage") },
            body: { ctx in
                let results = PrepResults(version: 2, generatedAt: "now", results: [
                    PrepResult(naturalKey: key,
                              contacts: [PrepContact(name: "Jane Doe", role: "Artistic Director", email: "jane@choir.org",
                                                     method: "named_decision_maker", confidence: "high", formUrl: nil,
                                                     provenance: "act")],
                              draft: PrepDraft(subject: "s", body: "b", variant: "A"))
                ])
                return PrepImporter.ingest(results, into: ctx)
            })

        #expect(outcome.matched == 1)
        #expect(outcome.saveFailed)
    }

    // MARK: - #611 already-covered fit-risk flag

    @Test func aFreshAlreadyCoveredNoteSetsItAndClearsAnyPriorDismissal() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.alreadyCoveredDismissed = true   // a stale dismissal from unrelated prior state

        let results = PrepResults(version: 5, generatedAt: "now", results: [
            PrepResult(naturalKey: key, alreadyCoveredNote: "Lists a Photographer in Residence.")
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        #expect(p.alreadyCoveredNote == "Lists a Photographer in Residence.")
        #expect(p.alreadyCoveredDismissed == false)   // fresh evidence, not yet judged
    }

    // A re-run reporting the SAME note Dan already judged a false positive must not silently
    // un-dismiss it.
    @Test func anUnchangedAlreadyCoveredNotePreservesDansPriorDismissal() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.alreadyCoveredNote = "Lists a Photographer in Residence."
        p.alreadyCoveredDismissed = true
        try ctx.save()

        let results = PrepResults(version: 5, generatedAt: "now", results: [
            PrepResult(naturalKey: key, alreadyCoveredNote: "Lists a Photographer in Residence.")
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        #expect(p.alreadyCoveredDismissed == true)
    }

    // A later run that omits the note (a transient research miss) must never erase a real finding.
    @Test func anAbsentAlreadyCoveredNoteNeverClearsAPreviousOne() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.alreadyCoveredNote = "Lists a Photographer in Residence."
        try ctx.save()

        let results = PrepResults(version: 5, generatedAt: "now", results: [
            PrepResult(naturalKey: key)   // no alreadyCoveredNote this time
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        #expect(p.alreadyCoveredNote == "Lists a Photographer in Residence.")
    }

    // MARK: - #388 venue contact guard

    @Test func aFreshVenueMatchingContactIsFlaggedOnIngest() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: nil, email: "publicrelations@carnegiehall.org",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.looksLikeVenue == true)
        #expect(p?.recipients.first?.looksLikeVenueDismissed == false)
    }

    @Test func anUnchangedVenueMatchingAddressPreservesDansPriorDismissal() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: nil, email: "publicrelations@carnegiehall.org",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.recipients.first!.looksLikeVenueDismissed = true   // Dan judged this one a false positive
        try ctx.save()

        _ = PrepImporter.ingest(results, into: ctx)   // a re-run reports the SAME address

        #expect(p.recipients.first?.looksLikeVenueDismissed == true)
    }

    @Test func aChangedAddressResetsTheDismissalAndReDerivesTheFlag() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: nil, email: "publicrelations@carnegiehall.org",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.recipients.first!.looksLikeVenueDismissed = true
        try ctx.save()

        let corrected = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: nil, email: "info@frenchamericanpiano.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(corrected, into: ctx)

        #expect(p.recipients.first?.email == "info@frenchamericanpiano.example")
        #expect(p.recipients.first?.looksLikeVenue == false)
        #expect(p.recipients.first?.looksLikeVenueDismissed == false)
    }

    @Test func aManualContactIsNeverCheckedAgainstTheVenue() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: nil, email: "publicrelations@carnegiehall.org",
                                              method: nil, confidence: nil, formUrl: nil,
                                              provenance: "manual")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.looksLikeVenue == false)
    }
}
