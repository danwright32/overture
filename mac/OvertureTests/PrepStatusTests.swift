import Testing
import Foundation
@testable import Overture

@Suite("Prep status summary")
struct PrepStatusTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

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

    @Test func relativeTimeBuckets() {
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-30), to: now) == "just now")
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-600), to: now) == "10m ago")
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-7200), to: now) == "2h ago")
        #expect(PrepStatus.relative(from: now.addingTimeInterval(-172800), to: now) == "2d ago")
    }
}
