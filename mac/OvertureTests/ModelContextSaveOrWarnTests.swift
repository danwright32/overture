import Testing
import Foundation
import SwiftData

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
                         venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
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

    // #1417: the load-bearing fact behind gating a success banner on saveOrWarn at the call site.
    // The domain editing helpers (WatchlistEditing, ExcludedTownEditing, DayOffEditing) persist with a
    // bare `try? context.save()` that swallows the error, and their UI callers then acknowledge success.
    // Gating those callers works ONLY if a failed save leaves the change pending, so a second attempt
    // fails the same way instead of reporting a clean context. If SwiftData ever rolled the change back
    // (or cleared the pending state) on failure, the gate would report success over a lost write, which
    // is the exact defect being fixed. Pinned here rather than assumed.
    @Test("a swallowed save failure leaves the change pending, so a later saveOrWarn still catches it")
    func swallowedFailureStaysDetectable() async throws {
        let feedback = ActionFeedback()

        let (stillPending, confirmed) = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self]),
            seed: { self.make($0, naturalKey: "a") },
            body: { ctx in
                self.make(ctx, naturalKey: "b")
                try? ctx.save()   // exactly what the domain helpers do today: the error goes nowhere
                return (ctx.hasChanges, ctx.saveOrWarn(org: "Aurora Strings", feedback: feedback))
            })

        #expect(stillPending)
        #expect(!confirmed)
        #expect(feedback.message == "Couldn't save the change for Aurora Strings")
        #expect(feedback.tone == .warning)
    }
}
