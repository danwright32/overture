import Testing
import Foundation
import SwiftData

// #623: mirrors ModelContextSaveOrWarnTests (#618). QueueView.sendReply/performSend and
// FollowUpsView's follow-up-send/conversation-nudge handlers each hand-rolled the identical
// do/catch + feedback.acknowledge(ActionAck.sendNotConfirmed(org:), tone: .warning) block added
// by #477/#499, for the case where a Gmail send succeeds but the local record of it fails to
// save. saveOrWarnSendNotConfirmed collapses that into one line, the sendNotConfirmed sibling of
// saveOrWarn.
@MainActor
@Suite("ModelContext.saveOrWarnSendNotConfirmed (#623)")
struct ModelContextSaveOrWarnSendNotConfirmedTests {
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

        let saved = ctx.saveOrWarnSendNotConfirmed(org: "Aurora Strings", feedback: feedback)

        #expect(saved)
        #expect(feedback.message == nil)
    }

    // Forces a genuine save() throw (not a simulated one) via ImmutableStoreFixture (#617), the
    // same technique ModelContextSaveOrWarnTests uses for #618.
    @Test("a failing save returns false and warns via ActionAck.sendNotConfirmed")
    func failure() async throws {
        let feedback = ActionFeedback()

        let saved = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self]),
            seed: { self.make($0, naturalKey: "a") },
            body: { ctx in
                self.make(ctx, naturalKey: "b")
                return ctx.saveOrWarnSendNotConfirmed(org: "Aurora Strings", feedback: feedback)
            })

        #expect(!saved)
        #expect(feedback.message
                == "Couldn't save what happened sending to Aurora Strings: check Gmail to see if it went out.")
        #expect(feedback.tone == .warning)
    }
}
