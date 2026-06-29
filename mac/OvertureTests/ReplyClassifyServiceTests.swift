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
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show with one replied CONTACT carrying the reply/draft state the per-recipient queue reads (#420 C2).
    @discardableResult
    private func show(_ ctx: ModelContext, key: String, replied: Bool = true,
                      replyText: String? = "Yes, let's book.", manual: Bool = false,
                      draftBody: String? = nil, repliedAt: Date? = nil, draftRequestedAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "Carnegie Hall",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        p.lastReplyText = replyText
        ctx.insert(p)
        let r = Recipient(id: key + "@act.example", email: key + "@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = replied
        r.lastReplyText = replyText
        r.repliedAt = repliedAt
        r.replyDraftBody = draftBody
        r.replyDraftRequestedAt = draftRequestedAt
        if manual { r.outcomeSource = .manual }
        p.addRecipient(r)
        try? ctx.save()
        return p
    }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func queuesARepliedContactWithTextAndNoDraft() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", replyText: "Yes please")
        let q = ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x")
        #expect(q.items.map(\.naturalKey) == ["k1"])
        #expect(q.items.first?.replyText == "Yes please")
        #expect(q.items.first?.recipientId == "k1@act.example")   // v3: discriminator populated
    }

    @Test func skipsAHandMarkedContact() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k2", manual: true)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    @Test func skipsWhenThereIsNoReplyTextYet() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k3", replyText: nil)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    @Test func requeuesOnAFreshReplyAfterADraftWasMade() throws {
        let ctx = ModelContext(try container())
        let t = Date(timeIntervalSince1970: 1000)
        show(ctx, key: "k4", draftBody: "a prior draft",
             repliedAt: t.addingTimeInterval(100), draftRequestedAt: t)   // reply AFTER the draft request
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.map(\.naturalKey) == ["k4"])
    }

    @Test func doesNotRequeueWhenTheReplyPredatesTheDraft() throws {
        let ctx = ModelContext(try container())
        let t = Date(timeIntervalSince1970: 1000)
        show(ctx, key: "k5", draftBody: "a prior draft",
             repliedAt: t, draftRequestedAt: t.addingTimeInterval(100))   // draft requested AFTER the reply
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    @Test func startWritesTheQueueLaunchesAndGuardsADoubleRun() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k6", replyText: "Yes")
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

    // #435 — a successful start records when the run began, so the completion watcher can ask
    // DetachedRunOutcome whether the run produced a fresh result or finished empty (mirrors Prep).
    @Test func startRecordsTheRunStartTime() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k8", replyText: "Yes")
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // well past the plausibility floor
        _ = try ReplyClassifyService.startClassify(from: ctx, now: now,
                                                   queueURL: tmp(), markerURL: tmp(), launch: {})
        #expect(ReplyClassifyService.lastRunStartedAt == now)
    }

    // #420 C5 — the stale window is 10 minutes (a cold merged classify+drafter run): a marker younger
    // than that still reads as running; older than it is stale and frees the run.
    @Test func theStaleWindowIsTenMinutes() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Separate files per case: URL resource values cache per URL, so reusing one would read stale.
        func marker(ageMinutes: Double) throws -> URL {
            let url = tmp()
            try Data().write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ageMinutes * 60)],
                                                  ofItemAtPath: url.path)
            return url
        }
        #expect(ReplyClassifyService.isRunning(markerURL: try marker(ageMinutes: 5), now: now) == true)    // within 10m
        #expect(ReplyClassifyService.isRunning(markerURL: try marker(ageMinutes: 11), now: now) == false)  // past 10m: stale
    }

    // #420 C5 — if the launch fails, the atomic lock is released so a retry isn't permanently blocked.
    @Test func aFailedLaunchReleasesTheLock() throws {
        struct LaunchFailed: Error {}
        let ctx = ModelContext(try container())
        show(ctx, key: "k7", replyText: "Yes")
        let queueURL = tmp(); let markerURL = tmp()
        #expect(throws: LaunchFailed.self) {
            try ReplyClassifyService.startClassify(from: ctx, now: Date(),
                                                   queueURL: queueURL, markerURL: markerURL,
                                                   launch: { throw LaunchFailed() })
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)   // lock released
    }
}
