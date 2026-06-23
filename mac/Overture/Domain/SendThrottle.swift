import Foundation

// Decides whether an approved email may be sent right now, so a batch Dan approves
// at once drips out instead of bursting (deliverability rides on his real Gmail
// reputation, PLAN.md sections 2 and 6). Pure and testable; the sender calls
// canSendNow before each release and records the timestamp on success.

struct SendThrottleConfig: Equatable, Sendable {
    var minInterval: TimeInterval   // minimum gap between two sends
    var maxPerHour: Int
    var maxPerDay: Int

    // Conservative defaults: at most one every few minutes, modest hourly/daily caps.
    // These protect a personal Gmail; Dan can loosen them later.
    static let `default` = SendThrottleConfig(minInterval: 180, maxPerHour: 8, maxPerDay: 20)
}

enum SendThrottle {
    // `recentSends` are the timestamps of already-sent emails (any order).
    static func canSendNow(recentSends: [Date], now: Date, config: SendThrottleConfig = .default) -> Bool {
        // Respect the minimum gap since the most recent send.
        if let last = recentSends.max(), now.timeIntervalSince(last) < config.minInterval {
            return false
        }
        let inLastHour = recentSends.filter { now.timeIntervalSince($0) < 3600 }.count
        if inLastHour >= config.maxPerHour { return false }
        let inLastDay = recentSends.filter { now.timeIntervalSince($0) < 86_400 }.count
        if inLastDay >= config.maxPerDay { return false }
        return true
    }

    // How long until the next send is allowed (0 if now), so a scheduler can wait.
    static func secondsUntilNextSlot(recentSends: [Date], now: Date, config: SendThrottleConfig = .default) -> TimeInterval {
        if canSendNow(recentSends: recentSends, now: now, config: config) { return 0 }
        var waits: [TimeInterval] = []
        if let last = recentSends.max() {
            waits.append(max(0, config.minInterval - now.timeIntervalSince(last)))
        }
        let hour = recentSends.filter { now.timeIntervalSince($0) < 3600 }.sorted()
        if hour.count >= config.maxPerHour, let oldest = hour.first {
            waits.append(max(0, 3600 - now.timeIntervalSince(oldest)))
        }
        let day = recentSends.filter { now.timeIntervalSince($0) < 86_400 }.sorted()
        if day.count >= config.maxPerDay, let oldest = day.first {
            waits.append(max(0, 86_400 - now.timeIntervalSince(oldest)))
        }
        return waits.max() ?? 0
    }
}
