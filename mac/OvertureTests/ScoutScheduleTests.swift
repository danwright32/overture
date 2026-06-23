import Testing
import Foundation
@testable import Overture

// #33: the scout should run on its own about once a day, not only when Dan clicks. This
// is the pure "is a scheduled run due?" decision; the app checks it on launch and
// periodically while open.
@Suite("Scout schedule")
struct ScoutScheduleTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func dueWhenNeverScouted() {
        #expect(ScoutSchedule.isDue(lastScoutedAt: nil, now: now) == true)
    }

    @Test func notDueRightAfterAScout() {
        #expect(ScoutSchedule.isDue(lastScoutedAt: now.addingTimeInterval(-3600), now: now) == false)
    }

    @Test func dueOnceTheIntervalHasPassed() {
        let dayAndChange = now.addingTimeInterval(-25 * 3600)
        #expect(ScoutSchedule.isDue(lastScoutedAt: dayAndChange, now: now) == true)
    }

    @Test func autoScoutGateRespectsToggleInFlightAndSchedule() {
        let stale = now.addingTimeInterval(-25 * 3600)
        // Enabled, idle, due -> go.
        #expect(ScoutSchedule.shouldAutoScout(enabled: true, isScanning: false, lastScoutedAt: stale, now: now) == true)
        // Toggle off -> never.
        #expect(ScoutSchedule.shouldAutoScout(enabled: false, isScanning: false, lastScoutedAt: stale, now: now) == false)
        // Already scouting -> don't double up.
        #expect(ScoutSchedule.shouldAutoScout(enabled: true, isScanning: true, lastScoutedAt: stale, now: now) == false)
        // Not due yet -> wait.
        #expect(ScoutSchedule.shouldAutoScout(enabled: true, isScanning: false, lastScoutedAt: now.addingTimeInterval(-3600), now: now) == false)
    }
}
