import Testing
import Foundation
import SwiftData

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
                       // #1856: a high-confidence find names the page it was read off. Without one it is
                       // now stored as unverified, which is the rule this happy path is not about.
                       contacts: [PrepContact(name: "Jane Doe", role: "Artistic Director", email: "jane@choir.org",
                                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                                              provenance: "act", sourceUrl: "https://choir.org/about")],
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

    // #367: a prospect that already has a draft, flagged for re-prep.
    @discardableResult
    private func reprepProspect(_ ctx: ModelContext, key: String, status: ReviewStatus = .drafted,
                                draftEditedByDan: Bool = false,
                                reprepDraftRequested: Bool = false, reprepContactsRequested: Bool = false,
                                sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.draftSubject = "Old subject"
        p.draftBody = "Old body"
        p.draftEditedByDan = draftEditedByDan
        p.reprepDraftRequested = reprepDraftRequested
        p.reprepContactsRequested = reprepContactsRequested
        p.sentAt = sentAt
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // #367: a fresh (non-hand-edited) draft on an approved prospect must revert it to .drafted so
    // Dan re-reviews before it can send again.
    @Test func approvedProspectRevertsToDraftedOnGenuineRedraft() throws {
        let ctx = ModelContext(try container())
        let p = reprepProspect(ctx, key: "k1", status: .approved, reprepDraftRequested: true)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey, draft: PrepDraft(subject: "New", body: "New body", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(outcome.drafted == 1)
        #expect(p.status == .drafted)
        #expect(p.draftBody == "New body")
    }

    @Test func approvedProspectStaysApprovedWhenDraftWasHandEdited() throws {
        let ctx = ModelContext(try container())
        let p = reprepProspect(ctx, key: "k2", status: .approved, draftEditedByDan: true, reprepDraftRequested: true)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey, draft: PrepDraft(subject: "New", body: "New body", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(outcome.skippedEdited == 1)
        #expect(p.status == .approved)
        #expect(p.draftBody == "Old body")
    }

    @Test func approvedProspectStaysApprovedOnContactsOnlyChange() throws {
        let ctx = ModelContext(try container())
        let p = reprepProspect(ctx, key: "k3", status: .approved, reprepContactsRequested: true)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey, contacts: [
                PrepContact(name: "New Contact", role: nil, email: "new@example.com",
                           method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act")
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        #expect(p.status == .approved)
    }

    @Test func reprepFlagsClearAfterIngestWhetherAppliedOrSkipped() throws {
        let ctx = ModelContext(try container())
        let applied = reprepProspect(ctx, key: "applied", status: .drafted, reprepDraftRequested: true)
        let skipped = reprepProspect(ctx, key: "skipped", status: .drafted,
                                     draftEditedByDan: true, reprepDraftRequested: true, reprepContactsRequested: true)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: applied.naturalKey, draft: PrepDraft(subject: "New", body: "New body", variant: "A")),
            PrepResult(naturalKey: skipped.naturalKey, draft: PrepDraft(subject: "New", body: "New body", variant: "A")),
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        #expect(applied.reprepDraftRequested == false)
        #expect(applied.reprepContactsRequested == false)
        #expect(skipped.reprepDraftRequested == false)
        #expect(skipped.reprepContactsRequested == false)
    }

    // #367 (red-team finding 2): the external Prep run is prompt-driven, not code, so the app must
    // not trust it to have honored a contacts-only request. If it returns a draft anyway, ignore it.
    @Test func outOfScopeDraftIsIgnoredForContactsOnlyRequest() throws {
        let ctx = ModelContext(try container())
        let p = reprepProspect(ctx, key: "k4", status: .drafted, reprepContactsRequested: true)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                      contacts: [PrepContact(name: "New Contact", role: nil, email: "new@example.com",
                                             method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act")],
                      draft: PrepDraft(subject: "Unwanted", body: "Unwanted body", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(p.draftBody == "Old body")
        #expect(p.recipients.count == 1)   // contacts still applied normally
        #expect(outcome.skippedOutOfScope == 1)
    }

    @Test func outOfScopeContactsAreIgnoredForDraftOnlyRequest() throws {
        let ctx = ModelContext(try container())
        let p = reprepProspect(ctx, key: "k5", status: .drafted, reprepDraftRequested: true)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                      contacts: [PrepContact(name: "Unwanted Contact", role: nil, email: "unwanted@example.com",
                                             method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "act")],
                      draft: PrepDraft(subject: "New", body: "New body", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(p.draftBody == "New body")   // draft still applied normally
        #expect(p.recipients.isEmpty)
        #expect(outcome.skippedOutOfScope == 1)
    }

    // #367 (red-team finding 3): a defensive backstop, independent of ReprepRequest's own gate, in
    // case a draft-affecting item ever reaches ingest for a prospect something has already been
    // sent to.
    @Test func draftChangeIsRefusedOnceSentAtIsSet() throws {
        let ctx = ModelContext(try container())
        let p = reprepProspect(ctx, key: "k6", status: .approved, reprepDraftRequested: true,
                               sentAt: Date(timeIntervalSince1970: 10))

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey, draft: PrepDraft(subject: "New", body: "New body", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(p.draftBody == "Old body")
        #expect(p.status == .approved)
        #expect(outcome.skippedOutOfScope == 1)
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

    // #1590: the natural key is the opaque token a detached prep or reachability run is handed and echoes
    // back, matched here by exact equality. Folding the title half re-keys stored rows at launch, so a run
    // that was in flight ACROSS that launch comes back quoting a key nothing carries any more. That has to
    // be reported, never swallowed: a reachability answer costs real money and real minutes, and a silent
    // drop would look exactly like a run that found nothing.
    @Test func aResultEchoingThePreFoldKeyIsReportedNotSilentlyDropped() throws {
        let ctx = ModelContext(try container())
        let title = "Christine Andreas: S'Wonderful..."
        let live = keptProspect(ctx, group: title, date: "2026-07-31", venue: "54 Below")

        // Exactly what makeNaturalKey produced for this show BEFORE the title fold existed.
        let preFold = "christine andreas: s'wonderful...|2026-07-31|54 below"
        #expect(preFold != live, "the fold has to actually change this key, or the test proves nothing")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: preFold, draft: PrepDraft(subject: "x", body: "y", variant: nil))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(outcome.matched == 0)
        #expect(outcome.unmatchedKeys == [preFold],
                "PrepRunSummary turns this into \"1 didn't match\"; without it the answer vanishes")
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

    // #733: every matched result stamps reprepLastServedAt, whether the draft/contacts were
    // applied or skipped, so the UI can warn before re-prepping something just researched.
    @Test func ingestStampsReprepLastServedAtForEveryMatchedResult() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        let now = Date(timeIntervalSince1970: 1_000_000)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, draft: PrepDraft(subject: "S", body: "B", variant: "A"))
        ])
        _ = PrepImporter.ingest(results, into: ctx, now: now)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.reprepLastServedAt == now)
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

    // #726: a contact already pitched on another still-open prospect for what looks like the
    // same real-world performance (same contact, same venue, close date) gets flagged on ingest.
    @Test func flagsAContactAlreadyPitchedForANearbyPerformanceAtTheSameVenue() throws {
        let ctx = ModelContext(try container())
        _ = keptProspect(ctx, group: "Golden Awards", date: "2026-07-08", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: Prospect.makeNaturalKey(groupName: "Golden Awards", performanceDate: "2026-07-08", venue: "Weill Recital Hall"),
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let key2 = keptProspect(ctx, group: "Golden Awards Guest Artist Night", date: "2026-07-09", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key2,
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let p2 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        #expect(p2?.recipients.first?.looksLikeDuplicateContact == true)
    }

    // #726: two different recipients on the SAME prospect, with different emails, never cross-flag
    // each other (a plain regression check on the importer's wiring). This does NOT exercise the
    // guard's own naturalKey-based self-exclusion, since two PrepContacts sharing an email in one
    // batch collapse into a single Recipient row before the guard ever runs (Recipient.makeId
    // matches by email first). The self-exclusion itself is covered directly at the guard level by
    // DuplicateContactGuardTests.doesNotFlagTheSameProspectItself.
    @Test func differentRecipientsOnTheSameProspectNeverCrossFlag() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-07-08", venue: "Carnegie Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: nil, email: "emma@act.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act"),
                PrepContact(name: "Lou", role: nil, email: "lou@presenter.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "presenter"),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 2)
        #expect(p?.recipients.allSatisfy { $0.looksLikeDuplicateContact == false } == true)
    }

    // #726: a re-run that CORRECTS the email must reset a previously-set dismissal, mirroring the
    // existing looksLikeVenueDismissed reset-on-real-change convention.
    @Test func reIngestResetsDuplicateDismissalWhenEmailActuallyChanges() throws {
        let ctx = ModelContext(try container())
        _ = keptProspect(ctx, group: "Golden Awards", date: "2026-07-08", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: Prospect.makeNaturalKey(groupName: "Golden Awards", performanceDate: "2026-07-08", venue: "Weill Recital Hall"),
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let key2 = keptProspect(ctx, group: "Golden Awards Guest Artist Night", date: "2026-07-09", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key2,
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)
        let p2 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        p2?.recipients.first?.looksLikeDuplicateContactDismissed = true
        try ctx.save()

        // A later run corrects the email to a genuinely different address.
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "even later", results: [
            PrepResult(naturalKey: key2,
                       contacts: [PrepContact(name: nil, role: nil, email: "new@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        #expect(after?.recipients.first?.looksLikeDuplicateContactDismissed == false)
    }

    // #726: same-batch ordering asymmetry, an accepted, documented limitation. When two brand-new
    // duplicate prospects arrive together in ONE Prep results batch, only whichever is LATER in
    // the batch's results array sees the earlier one already inserted and gets flagged; the first
    // one processed correctly sees nothing yet, since it hasn't been inserted at that point.
    @Test func onlyTheLaterProspectInTheSameBatchGetsFlagged() throws {
        let ctx = ModelContext(try container())
        let key1 = keptProspect(ctx, group: "Golden Awards", date: "2026-07-08", venue: "Weill Recital Hall")
        let key2 = keptProspect(ctx, group: "Golden Awards Guest Artist Night", date: "2026-07-09", venue: "Weill Recital Hall")

        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key1, contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                                                method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")]),
            PrepResult(naturalKey: key2, contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                                                method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")]),
        ]), into: ctx)

        let p1 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key1 })).first
        let p2 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        #expect(p1?.recipients.first?.looksLikeDuplicateContact == false)
        #expect(p2?.recipients.first?.looksLikeDuplicateContact == true)
    }

    // #363: a high-confidence contact's sourceUrl is captured onto the recipient on first ingest.
    @Test func capturesSourceURLOnANewHighConfidenceContact() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")

        let results = PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma Robinson", role: "Marketing Director", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high",
                            formUrl: nil, provenance: "act",
                            sourceUrl: "https://act.example/about/staff"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.contactSourceURL == "https://act.example/about/staff")
    }

    // #363: a re-run correcting a contact also updates its sourceUrl in place, mirroring how the
    // same re-run already corrects contactFormURL/contactConfidenceRaw.
    @Test func reIngestUpdatesSourceURLInPlace() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: "Manager", email: "emma@act.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act"),
            ])
        ]), into: ctx)
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma Robinson", role: "Director", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high",
                            formUrl: nil, provenance: "act",
                            sourceUrl: "https://act.example/about/staff"),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.contactSourceURL == "https://act.example/about/staff")
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

        // #2895 moved the ceiling to 11 (the contact `performanceCorroborated`), so the first rejected
        // version is 12. The boundary is what matters here, not the literal number: a version ABOVE what this build
        // understands must throw, because `PrepImporter.answeredKeys` decodes the same file with no
        // version gate at all and would otherwise stamp every show with the no-email floor while this
        // reader silently refused to upgrade it.
        #expect(throws: PrepResultsError.unsupportedVersion(12)) {
            try PrepResultsDecoder.decode(Data(#"{"version":12,"generatedAt":"x","results":[]}"#.utf8))
        }
        // The version #2895 added decodes, so the ceiling really did move rather than the test being
        // relaxed around it, and #2912's and #2622's still do.
        #expect(try PrepResultsDecoder.decode(Data(#"{"version":11,"generatedAt":"x","results":[]}"#.utf8)).version == 11)
        #expect(try PrepResultsDecoder.decode(Data(#"{"version":10,"generatedAt":"x","results":[]}"#.utf8)).version == 10)
        #expect(try PrepResultsDecoder.decode(Data(#"{"version":9,"generatedAt":"x","results":[]}"#.utf8)).version == 9)
        #expect(try PrepResultsDecoder.decode(Data(#"{"version":8,"generatedAt":"x","results":[]}"#.utf8)).version == 8)
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

    // MARK: - #722 press contact guard

    @Test func aFreshPressMatchingContactIsFlaggedOnIngest() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: nil, email: "press@frenchamericanpiano.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.looksLikePressContact == true)
        #expect(p?.recipients.first?.looksLikePressContactDismissed == false)
    }

    @Test func anUnchangedPressMatchingContactPreservesDansPriorDismissal() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: "Media Relations Manager", email: "jane@frenchamericanpiano.example",
                                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.recipients.first!.looksLikePressContactDismissed = true
        try ctx.save()

        _ = PrepImporter.ingest(results, into: ctx)   // a re-run reports the SAME email and role

        #expect(p.recipients.first?.looksLikePressContactDismissed == true)
    }

    @Test func aChangedRoleResetsTheDismissalAndReDerivesTheFlag() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")
        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: "Media Relations Manager", email: "jane@frenchamericanpiano.example",
                                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
        p.recipients.first!.looksLikePressContactDismissed = true
        try ctx.save()

        let corrected = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: "Artistic Director", email: "jane@frenchamericanpiano.example",
                                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                                              provenance: "presenter")])
        ])
        _ = PrepImporter.ingest(corrected, into: ctx)

        #expect(p.recipients.first?.role == "Artistic Director")
        #expect(p.recipients.first?.looksLikePressContact == false)
        #expect(p.recipients.first?.looksLikePressContactDismissed == false)
    }

    @Test func aManualContactIsNeverCheckedAgainstThePressRule() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "French-American Piano Society", date: "2026-09-12", venue: "Weill Recital Hall")

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: nil, role: "Media Relations Manager", email: "press@frenchamericanpiano.example",
                                              method: nil, confidence: nil, formUrl: nil,
                                              provenance: "manual")])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.looksLikePressContact == false)
    }

    // MARK: - Performer-name warm-lead detection (#751, plan #748, issue #585)

    // Scores below are all: music 1 + self 2 + strong 2 + likely_uncovered 2 = 7, plus the prior.
    // So none = 7, declined_by_you = 7 (#1362: neutral), warm = 17, booked = 27.
    private func performerProspect(_ ctx: ModelContext, prior: String = "none",
                                   production: String = "self") -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Emerging Artists Series",
                                          performanceDate: "2026-08-02", venue: "Weill Recital Hall")
        let base = Ranker.scoreFit(Candidate(
            reachable: true, priorRelationship: PriorRelationship(rawValue: prior) ?? .none,
            production: Production(rawValue: production) ?? .unknown, profile: .strong,
            coverage: .likelyUncovered, discipline: .music,
            passedOnThisShow: false, contactRoute: .unchecked))
        let p = Prospect(naturalKey: key, groupName: "Emerging Artists Series", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-02",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: prior,
                         production: production, profile: "strong", coverage: "likely_uncovered",
                         fitScore: base.score, tier: base.tier.rawValue, fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func larkin(email: String = "") -> DownbeatClient {
        DownbeatClient(id: "client-larkin", displayName: "Larkin Sable", shortName: nil,
                       email: email, contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                       hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")
    }

    private func performerResults(_ key: String, name: String = "Larkin Sable",
                                  email: String? = "larkin@sableviolin.example",
                                  provenance: String = "performer") -> PrepResults {
        PrepResults(version: 3, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: name, role: "Violinist", email: email,
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: provenance)],
                       draft: nil)
        ])
    }

    // The whole point of #585: the group name ("Emerging Artists Series") matches nothing, but the
    // performer fronting it is a past client, so the lead is warm and was being scored cold.
    @Test func aPerformerWhoIsAPastClientCorrectsTheRelationshipAndRescores() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx)
        #expect(p.fitScore == 7)   // cold, on the org name alone

        _ = PrepImporter.ingest(performerResults(p.naturalKey), into: ctx,
                                clients: [larkin()], history: [])

        #expect(p.priorRelationship == "booked")
        #expect(p.matchedClientName == "Larkin Sable")
        #expect(p.downbeatClientId == "client-larkin")
        #expect(p.fitScore == 27)                 // rescored from the upgraded relationship
        #expect(p.tier == "high")
        #expect(p.relationshipCorrectedByPerformerMatch)
        #expect(p.matchedPerformerName == "Larkin Sable")
        #expect(p.performerMatchNote != nil)
        // A brand-new finding starts unreviewed and undismissed: Dan hasn't seen it yet.
        #expect(!p.performerMatchReviewed)
        #expect(!p.performerMatchDismissed)
        // The pre-correction snapshot, so a dismissal can restore exactly what the scout had.
        #expect(p.performerMatchPreviousRelationship == "none")
        #expect(p.performerMatchPreviousFitScore == 7)
        #expect(p.performerMatchPreviousMatchedClientName == nil)
    }

    @Test func aPerformerWhoMatchesNothingLeavesTheProspectAlone() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx)

        _ = PrepImporter.ingest(performerResults(p.naturalKey, name: "Rowan Delacroix"),
                                into: ctx, clients: [larkin()], history: [])

        #expect(p.priorRelationship == "none")
        #expect(p.fitScore == 7)
        #expect(!p.relationshipCorrectedByPerformerMatch)
        #expect(p.performerMatchNote == nil)
    }

    // "Assume it runs twice": re-ingesting the same prep-results file must not re-fire. If it did, the
    // second pass would snapshot the ALREADY-CORRECTED values as the "previous" ones, destroying the
    // only record of what the scout originally had, and would silently un-review a finding Dan had
    // already looked at.
    @Test func reIngestingTheSameEvidenceDoesNotReFireTheCorrection() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx)
        let results = performerResults(p.naturalKey)

        _ = PrepImporter.ingest(results, into: ctx, clients: [larkin()], history: [])
        p.performerMatchReviewed = true   // Dan has now seen it
        try ctx.save()

        _ = PrepImporter.ingest(results, into: ctx, clients: [larkin()], history: [])

        #expect(p.performerMatchReviewed)                       // not silently un-reviewed
        #expect(p.performerMatchPreviousFitScore == 7)          // still the SCOUT's score, not 27
        #expect(p.performerMatchPreviousRelationship == "none")
        #expect(p.fitScore == 27)
    }

    // The upgrade-only floor. This, not the do-not-contact exclusion, is what stops a performer match
    // from quietly DOWNGRADING a lead: the ordinary history path resolves declined/lost statuses just
    // fine, so without this floor a warm match on an already-booked prospect would cut its score.
    @Test func aPerformerMatchWeakerThanTheCurrentRelationshipIsRefused() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx, prior: "booked")
        #expect(p.fitScore == 27)

        // The performer's history says merely "warm" (10), against a prospect already booked (20).
        _ = PrepImporter.ingest(performerResults(p.naturalKey), into: ctx, clients: [],
                                history: [HistoryRecord(groupName: "Larkin Sable", status: "warm")])

        #expect(p.priorRelationship == "booked")
        #expect(p.fitScore == 27)
        #expect(!p.relationshipCorrectedByPerformerMatch)
    }

    // #1362 (revised from #751's 2026-07-11 call): a past decline is now neutral (0), below warm (10),
    // so a declined performer match is not "worth correcting" (isWorthCorrecting reads the ranker's own
    // floor) and must NOT overwrite a genuinely warm prospect. Whether Dan declined a group before is
    // irrelevant to a future pitch, so the warm lead stands, unchanged.
    @Test func aDeclinedPerformerMatchDoesNotDowngradeAWarmProspect() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx, prior: "warm")
        #expect(p.fitScore == 17)

        _ = PrepImporter.ingest(performerResults(p.naturalKey), into: ctx, clients: [],
                                history: [HistoryRecord(groupName: "Larkin Sable", status: "declined")])

        #expect(p.priorRelationship == "warm")
        #expect(p.fitScore == 17)
        #expect(!p.relationshipCorrectedByPerformerMatch)
    }

    @Test func anAgencyProducedProspectIsNeverPerformerMatched() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx, production: "agency")

        _ = PrepImporter.ingest(performerResults(p.naturalKey), into: ctx,
                                clients: [larkin()], history: [])

        #expect(p.priorRelationship == "none")
        #expect(!p.relationshipCorrectedByPerformerMatch)
    }

    // Only a contact the Prep run identified as the PERFORMER is a person; an act or presenter
    // contact is an org's staffer, and matching their name against the client list would be nonsense.
    @Test func aNonPerformerContactNeverTriggersAMatch() throws {
        let ctx = ModelContext(try container())
        let p = performerProspect(ctx)

        _ = PrepImporter.ingest(performerResults(p.naturalKey, provenance: "act"),
                                into: ctx, clients: [larkin()], history: [])

        #expect(p.priorRelationship == "none")
        #expect(!p.relationshipCorrectedByPerformerMatch)
    }
}
