import Testing
import Foundation
import Darwin
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

    // #618: forces a genuine save() throw (not a simulated one) by writing the store to disk,
    // flagging it immutable (the same chflags/UF_IMMUTABLE technique #524 used to force a real
    // chmod failure), then opening a FRESH container against that now-immutable store: SwiftData
    // reuses the first container's already-open file handle across saves, so only a save from a
    // newly opened container actually observes the permission failure.
    @Test("a failing save returns false and warns via ActionAck.saveFailed")
    func failure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("saveorwarn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("default.store")
        defer {
            for suffix in ["", "-wal", "-shm"] { _ = chflags(storeURL.path + suffix, 0) }
            try? FileManager.default.removeItem(at: dir)
        }

        let firstContext = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]), configurations: [ModelConfiguration(url: storeURL)]))
        make(firstContext, naturalKey: "a")
        try firstContext.save()   // creates default.store(+wal/shm) on disk

        for suffix in ["", "-wal", "-shm"] {
            #expect(chflags(storeURL.path + suffix, UInt32(UF_IMMUTABLE)) == 0)
        }

        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]), configurations: [ModelConfiguration(url: storeURL)]))
        let feedback = ActionFeedback()
        make(ctx, naturalKey: "b")

        let saved = ctx.saveOrWarn(org: "Aurora Strings", feedback: feedback)

        #expect(!saved)
        #expect(feedback.message == "Couldn't save the change for Aurora Strings")
        #expect(feedback.tone == .warning)
    }
}
