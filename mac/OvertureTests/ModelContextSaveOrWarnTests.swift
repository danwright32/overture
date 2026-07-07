import Testing
import Foundation
import SwiftData
@testable import Overture

// #618: roughly two dozen QueueView/FollowUpsView/DismissedView handlers each hand-rolled the
// identical do/catch + feedback.acknowledge(ActionAck.saveFailed(org:), tone: .warning) block
// added by #499 (PR #616). ModelContext.saveOrWarn collapses that into one line; unlike the
// SwiftUI view handlers it wraps, it's a plain extension a test can call directly.
@MainActor
@Suite("ModelContext.saveOrWarn (#618)")
struct ModelContextSaveOrWarnTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, naturalKey: String) {
        let p = Prospect(naturalKey: naturalKey, groupName: "Aurora Strings", discipline: "music",
                         venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
    }

    @Test("a successful save returns true and leaves feedback untouched")
    func success() throws {
        let ctx = ModelContext(try container())
        let feedback = ActionFeedback()
        make(ctx, naturalKey: "a")

        let saved = ctx.saveOrWarn(org: "Aurora Strings", feedback: feedback)

        #expect(saved)
        #expect(feedback.message == nil)
    }

    // #618: forces a genuine save() throw (not a simulated one) via ImmutableStoreFixture (#617).
    @Test("a failing save returns false and warns via ActionAck.saveFailed")
    func failure() async throws {
        let feedback = ActionFeedback()

        let saved = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self]),
            seed: { self.make($0, naturalKey: "a") },
            body: { ctx in
                self.make(ctx, naturalKey: "b")
                return ctx.saveOrWarn(org: "Aurora Strings", feedback: feedback)
            })

        #expect(!saved)
        #expect(feedback.message == "Couldn't save the change for Aurora Strings")
        #expect(feedback.tone == .warning)
    }
}
