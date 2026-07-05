import Testing
import Foundation
import SwiftData
@testable import Overture

// #338: the stage pills (Prep/Review/Send/Follow-ups) become real navigation. This pins down
// which prospects each pill's tap should focus the queue on, using the SAME criteria AgentRoster
// already uses to compute that pill's count/state, so what Dan taps always matches what he sees.
@Suite("Stage navigation (#338)")
struct StageNavigationTests {
    @MainActor
    private func prospect(_ ctx: ModelContext, key: String, status: ReviewStatus,
                          hasDraft: Bool = true, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @MainActor
    private func makeContext() -> ModelContext {
        ModelContext(try! ModelContainer(for: Schema([Prospect.self]),
                                         configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @MainActor
    @Test func prepStageIsQueuedWithNoDraft() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "kept-no-draft", status: .queued, hasDraft: false)
        _ = prospect(ctx, key: "kept-with-draft", status: .queued, hasDraft: true)
        _ = prospect(ctx, key: "drafted", status: .drafted)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = StageNavigation.naturalKeys(forStage: "Prep", in: all)
        #expect(keys == ["kept-no-draft"])
    }

    @MainActor
    @Test func reviewStageIsDrafted() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "drafted-1", status: .drafted)
        _ = prospect(ctx, key: "drafted-2", status: .drafted)
        _ = prospect(ctx, key: "queued", status: .queued, hasDraft: false)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = Set(StageNavigation.naturalKeys(forStage: "Review", in: all))
        #expect(keys == Set(["drafted-1", "drafted-2"]))
    }

    @MainActor
    @Test func sendStageIsApprovedAndNotYetSent() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "waiting-to-send", status: .approved, sentAt: nil)
        _ = prospect(ctx, key: "legacy-sent", status: .approved, sentAt: Date(timeIntervalSince1970: 10))
        _ = prospect(ctx, key: "drafted", status: .drafted)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = StageNavigation.naturalKeys(forStage: "Send", in: all)
        #expect(keys == ["waiting-to-send"])
    }

    @MainActor
    @Test func unknownStageNameReturnsNoKeys() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "x", status: .queued, hasDraft: false)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(StageNavigation.naturalKeys(forStage: "Follow-ups", in: all).isEmpty)
        #expect(StageNavigation.naturalKeys(forStage: "Nonsense", in: all).isEmpty)
    }
}
