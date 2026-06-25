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

        let results = PrepResults(version: 1, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contact: PrepContact(name: "Jane Doe", role: "Artistic Director", email: "jane@choir.org",
                                            method: "named_decision_maker", confidence: "high", formUrl: nil),
                       draft: PrepDraft(subject: "Photographing your Carnegie performance", body: "Hi Jane,\n...", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)
        #expect(outcome.matched == 1)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.contactName == "Jane Doe")
        #expect(p?.contactEmail == "jane@choir.org")
        #expect(p?.contactConfidence == .high)
        #expect(p?.contactMethod == .namedDecisionMaker)
        #expect(p?.draftSubject == "Photographing your Carnegie performance")
        #expect(p?.hasDraft == true)
        #expect(p?.status == .drafted)
    }

    @Test func reportsUnmatchedKeysInsteadOfSilentlyDropping() throws {
        let ctx = ModelContext(try container())
        let results = PrepResults(version: 1, generatedAt: "now", results: [
            PrepResult(naturalKey: "ghost|2026-01-01|nowhere", contact: nil,
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
        let firstRun = PrepResults(version: 1, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contact: nil, draft: PrepDraft(subject: "S1", body: "B1", variant: "A"))
        ])
        _ = PrepImporter.ingest(firstRun, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        p?.draftBody = "Dan's hand-tuned version"
        p?.draftEditedByDan = true
        try ctx.save()

        // A second Prep run must NOT overwrite Dan's edit.
        let secondRun = PrepResults(version: 1, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contact: nil, draft: PrepDraft(subject: "S2", body: "B2 regenerated", variant: "B"))
        ])
        let outcome = PrepImporter.ingest(secondRun, into: ctx)

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(after?.draftBody == "Dan's hand-tuned version")
        #expect(after?.draftEditedByDan == true)
        #expect(outcome.skippedEdited == 1)
    }

    @Test func decodesAndVersionGates() throws {
        let json = """
        {"version":1,"generatedAt":"now","results":[{"naturalKey":"k","contact":null,"draft":{"subject":"s","body":"b"}}]}
        """
        let decoded = try PrepResultsDecoder.decode(Data(json.utf8))
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].draft?.subject == "s")

        #expect(throws: PrepResultsError.unsupportedVersion(5)) {
            try PrepResultsDecoder.decode(Data(#"{"version":5,"generatedAt":"x","results":[]}"#.utf8))
        }
        // Below the minimum is rejected too — the gate is a closed range, not an exact match (#140).
        #expect(throws: PrepResultsError.unsupportedVersion(0)) {
            try PrepResultsDecoder.decode(Data(#"{"version":0,"generatedAt":"x","results":[]}"#.utf8))
        }
    }
}
