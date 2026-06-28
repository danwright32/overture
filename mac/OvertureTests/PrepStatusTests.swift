import Testing
import Foundation
import SwiftData
@testable import Overture

@Suite("Prep status summary")
struct PrepStatusTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @MainActor
    private func prospect(_ ctx: ModelContext, group: String, status: ReviewStatus,
                          hasDraft: Bool = true, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
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

    // #200: the approved count means "approved and still waiting to send", so an already-sent
    // prospect (now .contacted, or legacy .approved with a send date) must not inflate it.
    @MainActor
    @Test func fromCountsApprovedWaitingToSendOnly() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        _ = prospect(ctx, group: "WaitingToSend", status: .approved, hasDraft: true, sentAt: nil)
        _ = prospect(ctx, group: "LegacySent", status: .approved, hasDraft: true,
                     sentAt: Date(timeIntervalSince1970: 10))
        _ = prospect(ctx, group: "NewlySent", status: .contacted, hasDraft: true,
                     sentAt: Date(timeIntervalSince1970: 10))
        _ = prospect(ctx, group: "ToPrep", status: .queued, hasDraft: false, sentAt: nil)
        _ = prospect(ctx, group: "ToReview", status: .drafted, hasDraft: true, sentAt: nil)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let s = PrepStatus.from(prospects: all, lastRunStartedAt: nil, running: false)
        #expect(s.approved == 1)   // only WaitingToSend
        #expect(s.kept == 1)       // only ToPrep (queued, no draft)
        #expect(s.drafted == 1)    // only ToReview
    }

    @Test func runningTakesPrecedence() {
        let s = PrepStatus(kept: 3, drafted: 1, approved: 0, lastRunStartedAt: now, running: true)
        #expect(s.summary(now: now).hasPrefix("Prepping 3"))
    }

    @Test func showsWorkWaitingAndReviewAndLastRun() {
        let last = now.addingTimeInterval(-7200) // 2h ago
        let s = PrepStatus(kept: 2, drafted: 1, approved: 1, lastRunStartedAt: last, running: false)
        let out = s.summary(now: now)
        #expect(out.contains("2 to prep"))
        #expect(out.contains("1 to review"))
        #expect(out.contains("1 approved"))
        #expect(out.contains("last prep 2h ago"))
    }

    @Test func allCaughtUpWhenNothingPending() {
        let s = PrepStatus(kept: 0, drafted: 0, approved: 0, lastRunStartedAt: nil, running: false)
        #expect(s.summary(now: now) == "All caught up")
    }

    // #333: a fresh store can carry a sentinel/epoch timestamp under the last-run key. That must
    // read as "never ran" (nil) so the header omits the clause instead of rendering "20632d ago".
    @Test func implausiblyOldLastRunReadsAsNever() {
        #expect(PrepQueueService.sanitizedLastRun(nil) == nil)
        #expect(PrepQueueService.sanitizedLastRun(Date(timeIntervalSince1970: 0)) == nil)
        let recent = Date(timeIntervalSince1970: 1_700_000_000) // late 2023
        #expect(PrepQueueService.sanitizedLastRun(recent) == recent)
    }

    @Test func relativeTimeBuckets() {
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-30), to: now) == "just now")
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-600), to: now) == "10m ago")
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-7200), to: now) == "2h ago")
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-172800), to: now) == "2d ago")
    }
}
