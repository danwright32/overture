import Testing
import Foundation
@testable import Overture

@Suite("Send throttle")
struct SendThrottleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let cfg = SendThrottleConfig(minInterval: 180, maxPerHour: 8, maxPerDay: 20)

    @Test func allowsSendWhenNothingRecent() {
        #expect(SendThrottle.canSendNow(recentSends: [], now: now, config: cfg) == true)
    }

    @Test func blocksWithinMinimumGap() {
        let recent = [now.addingTimeInterval(-60)] // 1 min ago, gap is 3 min
        #expect(SendThrottle.canSendNow(recentSends: recent, now: now, config: cfg) == false)
        // After the gap elapses, it's allowed again.
        #expect(SendThrottle.canSendNow(recentSends: [now.addingTimeInterval(-200)], now: now, config: cfg) == true)
    }

    @Test func blocksWhenHourlyCapReached() {
        // 8 sends all within the last hour (every 6 min), last 6 min ago (gap ok) -> capped.
        let recent = (1...8).map { now.addingTimeInterval(-Double($0) * 360) }
        #expect(SendThrottle.canSendNow(recentSends: recent, now: now, config: cfg) == false)
    }

    @Test func blocksWhenDailyCapReached() {
        // 20 sends spread over the last 20 hours: hourly ok, daily capped.
        let recent = (1...20).map { now.addingTimeInterval(-Double($0) * 3600) }
        #expect(SendThrottle.canSendNow(recentSends: recent, now: now, config: cfg) == false)
    }

    @Test func nextSlotWaitsForTheGap() {
        let recent = [now.addingTimeInterval(-60)] // 1 min ago
        let wait = SendThrottle.secondsUntilNextSlot(recentSends: recent, now: now, config: cfg)
        #expect(wait == 120) // 180 - 60
    }

    @Test func nextSlotIsZeroWhenAllowed() {
        #expect(SendThrottle.secondsUntilNextSlot(recentSends: [], now: now, config: cfg) == 0)
    }
}
