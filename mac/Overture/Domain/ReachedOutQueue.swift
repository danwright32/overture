import Foundation

// The "reached out" pipeline (#217): contacted prospects Dan is still working, ordered by when he
// should next reach out. Combines the silent follow-up sequence (FollowUp) and the conversation
// reminder track (ConversationReminder), taking whichever is sooner. Returns nil — the prospect
// drops off the list — once outreach should stop: booked, lost, or nothing left scheduled.
enum ReachedOutQueue {
    // The soonest moment Dan should next reach out to this prospect, or nil if outreach has stopped.
    // A past date (overdue) is returned as-is so it sorts to the top of the list.
    static func nextReachOut(for p: Prospect, now: Date,
                             followUpConfig: FollowUpConfig = .init(),
                             reminderConfig: ConversationReminderConfig = .init()) -> Date? {
        guard p.sentAt != nil else { return nil }                 // only contacted prospects
        guard p.outcome != .booked, p.outcome != .lostSoft, p.outcome != .lostHard else { return nil }

        let reminderDate = ConversationReminder.nextReminderDate(
            state: p.conversationState, setAt: p.conversationStateSetAt, remindedAt: p.conversationRemindedAt,
            performanceDate: p.performanceDate, outcome: p.outcome, source: p.conversationStateSource,
            now: now, config: reminderConfig)
        return [nextFollowUp(for: p, now: now, config: followUpConfig), reminderDate]
            .compactMap { $0 }
            .min()
    }

    // Contacted prospects with outreach still active, soonest next-reach-out first.
    static func active(from prospects: [Prospect], now: Date,
                       followUpConfig: FollowUpConfig = .init(),
                       reminderConfig: ConversationReminderConfig = .init()) -> [Prospect] {
        prospects
            .compactMap { p -> (Prospect, Date)? in
                nextReachOut(for: p, now: now, followUpConfig: followUpConfig,
                             reminderConfig: reminderConfig).map { (p, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // The next silent nudge for a no-response lead, mirroring FollowUp.isDue: paced by gapDays from
    // the last touch, up to maxFollowUps; nothing once it replied/booked/lost or the cap is reached.
    private static func nextFollowUp(for p: Prospect, now: Date, config: FollowUpConfig) -> Date? {
        guard let sentAt = p.sentAt else { return nil }
        guard p.outcome == .noResponse else { return nil }
        guard p.followUpCount < config.maxFollowUps else { return nil }
        let lastTouch = p.lastFollowUpAt ?? sentAt
        return lastTouch.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
    }

}
