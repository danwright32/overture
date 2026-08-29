import Testing
import Foundation
import SwiftData

// #1038: the detached-run half of cancel for Prep and reply-classify. Both runs are launched through the
// same DetachedRunner as scout, so neither has a trackable PID and neither could be stopped at all before
// this. The app writes a cancel sentinel the runner reads on its heartbeat (the SAME cooperative-stop
// pattern scout got in #1037). This covers the Swift side of both contracts: writing the sentinel, and
// clearing a stale one before a fresh run so a leftover from a cancelled run can never stop the next one
// instantly (assume-it-runs-twice). Driven with injected temp paths and a fake launcher, no real run.
@MainActor
@Suite("Cancelling the detached Prep and reply-classify runs (#1038)")
// #3065: `final class` so the sandbox goes with each test. This suite was leaving 4 per run.
final class PrepReplyCancelServiceTests {
    private let sandboxes = TemporarySandboxes()

    private func tempDir() throws -> URL {
        try sandboxes.make(named: "prep-reply-cancel")
    }

    // --- Prep ---------------------------------------------------------------------------------------

    private func prepContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func keptProspect(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Kept Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Kept Choir", discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-07-01", sourceListingURL: "https://src",
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func prepRequestCancelWritesTheSentinelTheRunnerReads() throws {
        let cancel = try tempDir().appendingPathComponent("prep-cancel")
        #expect(!FileManager.default.fileExists(atPath: cancel.path))
        PrepQueueService.requestCancel(slot: .prep, cancelURL: cancel)
        #expect(FileManager.default.fileExists(atPath: cancel.path))
    }

    // A sentinel left over from a previously cancelled run must be gone before a new run starts, or the
    // new run's heartbeat would read it and stop on its first tick. startPrep clears it as it takes the run.
    @Test func startPrepClearsAStaleCancelSentinelBeforeLaunching() async throws {
        let ctx = try prepContext()
        keptProspect(ctx)
        let dir = try tempDir()
        let cancel = dir.appendingPathComponent("prep-cancel")
        try Data().write(to: cancel)   // a leftover from a prior cancelled run
        var launched = false

        _ = try await PrepQueueService.startPrep(
                  from: ctx, now: Date(),
                  queueURL: dir.appendingPathComponent("queue.json"),
                  markerURL: dir.appendingPathComponent("marker"),
                  voiceFeedbackURL: dir.appendingPathComponent("voice-feedback.json"),
                  recentOpenersURL: dir.appendingPathComponent("recent-openers.json"),
                  cancelURL: cancel,
                  launch: { launched = true })

        #expect(launched == true)
        #expect(!FileManager.default.fileExists(atPath: cancel.path))   // cleared before the run began
    }

    // --- reply-classify -----------------------------------------------------------------------------

    private func replyContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func repliedContact(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k1", groupName: "G", discipline: "music", venue: "Carnegie Hall",
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        p.lastReplyText = "Yes, let's book."
        ctx.insert(p)
        let r = Recipient(id: "k1@act.example", email: "k1@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = true
        r.lastReplyText = "Yes, let's book."
        p.addRecipient(r)
        try? ctx.save()
        return p
    }

    @Test func replyClassifyRequestCancelWritesTheSentinelTheRunnerReads() throws {
        let cancel = try tempDir().appendingPathComponent("reply-classify-cancel")
        #expect(!FileManager.default.fileExists(atPath: cancel.path))
        ReplyClassifyService.requestCancel(cancelURL: cancel)
        #expect(FileManager.default.fileExists(atPath: cancel.path))
    }

    @Test func startClassifyClearsAStaleCancelSentinelBeforeLaunching() throws {
        let ctx = try replyContext()
        repliedContact(ctx)
        let dir = try tempDir()
        let cancel = dir.appendingPathComponent("reply-classify-cancel")
        try Data().write(to: cancel)   // a leftover from a prior cancelled run
        var launched = false

        _ = try ReplyClassifyService.startClassify(
            from: ctx, now: Date(),
            queueURL: dir.appendingPathComponent("queue.json"),
            markerURL: dir.appendingPathComponent("marker"),
            cancelURL: cancel,
            launch: { launched = true })

        #expect(launched == true)
        #expect(!FileManager.default.fileExists(atPath: cancel.path))   // cleared before the run began
    }
}
