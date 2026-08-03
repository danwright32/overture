import Testing
import Foundation

// #35: the masthead should show when the scout last ran, so freshness is visible at a
// glance (and a quietly-stale queue is obvious).
@Suite("Scout status")
struct ScoutStatusTests {
    @Test func saysNotScoutedYetWhenNoRunRecorded() {
        #expect(ScoutStatus(lastScoutedAt: nil).summary(now: Date()) == "Not scouted yet")
    }

    @Test func showsRelativeTimeOfTheLastRun() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        #expect(ScoutStatus(lastScoutedAt: twoHoursAgo).summary(now: now) == "Scouted 2h ago")
    }

    @MainActor
    @Test func recordsAndReadsBackTheLastScoutTime() {
        let suite = "scout-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ScoutService.lastScoutedAt(in: defaults) == nil)
        let when = Date(timeIntervalSince1970: 1_500_000)
        ScoutService.recordScout(at: when, in: defaults)
        #expect(ScoutService.lastScoutedAt(in: defaults) == when)
    }
}
