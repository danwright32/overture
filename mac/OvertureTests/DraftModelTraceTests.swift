import Testing
import Foundation
import SwiftData

// #804: which model wrote this draft.
//
// Dan pinned drafting to the strong TIER rather than an exact version (2026-07-12), so he picks up each
// new Opus as it ships and accepts that his voice can shift with it. That trade is only reasonable
// because the model is recorded: when an email reads oddly, he can tell whether the model changed
// underneath him, rather than sensing that something did and having no way to check.
//
// Recorded by the SCRIPT, not by the model. Asking a model to write down which model it is invites it to
// be confidently wrong about the one fact the record exists to establish.
@MainActor
@Suite("A draft records what wrote it (#804)")
struct DraftModelTraceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, key: String = "show") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Brooklyn Youth Chorus", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2099-09-19", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        return p
    }

    private func results(model: String?, key: String = "show") -> PrepResults {
        PrepResults(version: 2, generatedAt: "2026-07-12T00:00:00Z",
                    results: [PrepResult(naturalKey: key,
                                         draft: PrepDraft(subject: "Photographs of your concert",
                                                          body: "Hello, I photograph performances.",
                                                          variant: "rate_stated"))],
                    model: model)
    }

    @Test func aDraftRemembersTheModelThatWroteIt() throws {
        let ctx = try context()
        let p = prospect(ctx)

        PrepImporter.ingest(results(model: "opus"), into: ctx)

        #expect(p.draftBody?.isEmpty == false)
        #expect(p.draftModel == "opus")
    }

    // A results file from before this existed (or one whose stamp failed to write) must still ingest
    // perfectly. A missing trace is a gap in the record, never a reason to drop Dan's draft on the floor.
    @Test func aResultsFileWithNoModelStillIngestsItsDraft() throws {
        let ctx = try context()
        let p = prospect(ctx)

        PrepImporter.ingest(results(model: nil), into: ctx)

        #expect(p.draftBody?.isEmpty == false)
        #expect(p.draftModel == nil)
    }

    // THE reason this exists. A redraft by a different model overwrites the trace, so what the row says
    // is what wrote the text that is actually there now, not what wrote some earlier version of it.
    @Test func aRedraftByADifferentModelUpdatesTheTrace() throws {
        let ctx = try context()
        let p = prospect(ctx)

        PrepImporter.ingest(results(model: "opus"), into: ctx)
        #expect(p.draftModel == "opus")

        p.status = .queued                       // re-queued for a fresh draft
        PrepImporter.ingest(results(model: "sonnet"), into: ctx)

        #expect(p.draftModel == "sonnet")
    }

    // A draft Dan hand-edited is HIS text, and the importer already refuses to overwrite it. The trace
    // must not be overwritten either, or the row would name a model for words Dan wrote himself.
    @Test func aDraftDanEditedKeepsItsOwnTraceRatherThanClaimingAModelWroteIt() throws {
        let ctx = try context()
        let p = prospect(ctx)
        PrepImporter.ingest(results(model: "opus"), into: ctx)

        p.draftEditedByDan = true
        p.status = .queued
        PrepImporter.ingest(results(model: "sonnet"), into: ctx)

        #expect(p.draftModel == "opus")   // the model that wrote the text he then edited, not the new run
    }
}
