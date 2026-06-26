import Testing
import Foundation
import SwiftData
@testable import Overture

// Ingesting the classify workflow's results (#185): match each by naturalKey and SUGGEST the
// conversation state (auto), never overwriting a state Dan set by hand (#60). Mirrors PrepImporter.
@MainActor
@Suite("Reply classify importer")
struct ReplyClassifyImporterTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func lead(_ ctx: ModelContext, key: String,
                      state: ConversationState? = nil, source: OutcomeSource? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        if let state { p.conversationState = state }
        p.conversationStateSourceRaw = source?.rawValue
        ctx.insert(p); try? ctx.save()
        return p
    }

    private func results(_ pairs: [(String, String)]) -> ReplyClassifyResults {
        ReplyClassifyResults(version: 1, generatedAt: "2026-06-26T00:00:00.000Z",
                             results: pairs.map { ReplyClassifyResult(naturalKey: $0.0, intent: $0.1) })
    }

    @Test func suggestsTheStateForAMatchedLead() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "k1")
        let out = ReplyClassifyImporter.ingest(results([("k1", "wants_to_book")]), into: ctx)
        #expect(p.conversationState == .wantsToBook)
        #expect(p.conversationStateSource == .auto)
        #expect(out.suggested == 1)
        #expect(out.matched == 1)
    }

    @Test func neverOverwritesAManualState() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "k2", state: .interested, source: .manual)
        let out = ReplyClassifyImporter.ingest(results([("k2", "declined")]), into: ctx)
        #expect(p.conversationState == .interested)   // Dan's hand-set state untouched (#60)
        #expect(out.skippedManual == 1)
    }

    @Test func surfacesUnmatchedKeys() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k3")
        let out = ReplyClassifyImporter.ingest(results([("nope", "interested")]), into: ctx)
        #expect(out.unmatchedKeys == ["nope"])
        #expect(out.suggested == 0)
    }
}
