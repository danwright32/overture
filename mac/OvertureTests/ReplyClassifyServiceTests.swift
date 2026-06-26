import Testing
import Foundation
import SwiftData
@testable import Overture

// Building and launching the reply-classify work-list (#184), mirroring PrepQueueService: only
// replied leads with captured text that Dan hasn't hand-classified, re-queued when a fresh reply
// lands after a state was set. The detached launch is injected so the logic is testable without
// spawning a process.
@MainActor
@Suite("Reply classify service")
struct ReplyClassifyServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func lead(_ ctx: ModelContext, key: String, replyText: String? = "Yes, let's book.",
                      source: OutcomeSource? = nil, state: ConversationState? = nil,
                      replyAt: Date? = nil, setAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "Carnegie Hall",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        p.lastReplyText = replyText
        p.lastReplyAt = replyAt
        if let state { p.conversationState = state }
        p.conversationStateSourceRaw = source?.rawValue
        p.conversationStateSetAt = setAt
        ctx.insert(p); try? ctx.save()
        return p
    }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func queuesARepliedLeadWithTextAndNoState() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k1", replyText: "Yes please")
        let q = ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x")
        #expect(q.items.map(\.naturalKey) == ["k1"])
        #expect(q.items.first?.replyText == "Yes please")
    }

    @Test func skipsAHandSetState() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k2", source: .manual, state: .interested)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    @Test func skipsWhenThereIsNoReplyTextYet() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k3", replyText: nil)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    @Test func requeuesOnAFreshReplyAfterAStateWasSet() throws {
        let ctx = ModelContext(try container())
        let t = Date(timeIntervalSince1970: 1000)
        lead(ctx, key: "k4", source: .auto, state: .interested,
             replyAt: t.addingTimeInterval(100), setAt: t)   // reply AFTER the state was set
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.map(\.naturalKey) == ["k4"])
    }

    @Test func doesNotRequeueWhenTheReplyPredatesTheState() throws {
        let ctx = ModelContext(try container())
        let t = Date(timeIntervalSince1970: 1000)
        lead(ctx, key: "k5", source: .auto, state: .interested,
             replyAt: t, setAt: t.addingTimeInterval(100))   // state set AFTER the reply
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    @Test func startWritesTheQueueLaunchesAndGuardsADoubleRun() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k6", replyText: "Yes")
        let queueURL = tmp(); let markerURL = tmp()
        var launches = 0

        let n = try ReplyClassifyService.startClassify(from: ctx, now: Date(),
                                                       queueURL: queueURL, markerURL: markerURL,
                                                       launch: { launches += 1 })
        #expect(n == 1)
        #expect(launches == 1)
        #expect(FileManager.default.fileExists(atPath: queueURL.path))

        // Marker is fresh now: a second start must refuse (double-run guard).
        #expect(throws: (any Error).self) {
            try ReplyClassifyService.startClassify(from: ctx, now: Date(),
                                                   queueURL: queueURL, markerURL: markerURL,
                                                   launch: { launches += 1 })
        }
        #expect(launches == 1)
    }
}
