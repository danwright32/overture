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
        // #331: a real send always has a contact address; a sent timestamp without one is a
        // staged/corrupt record that was never actually emailed, so it doesn't belong here.
        guard p.contactEmail != nil else { return nil }
        guard p.outcome != .booked, p.outcome != .lostSoft, p.outcome != .lostHard else { return nil }

        let reminderDate = ConversationReminder.nextReminderDate(
            state: p.conversationState, setAt: p.conversationStateSetAt, remindedAt: p.conversationRemindedAt,
            performanceDate: p.performanceDate, outcome: p.outcome, source: p.conversationStateSource,
            now: now, config: reminderConfig)
        return [nextFollowUp(for: p, now: now, config: followUpConfig), reminderDate]
            .compactMap { $0 }
            .min()
    }

    // Contacted prospects with outreach still active, each paired with its next-reach-out date,
    // soonest first. The view formats the date with timingLabel.
    static func activeWithDates(from prospects: [Prospect], now: Date,
                                followUpConfig: FollowUpConfig = .init(),
                                reminderConfig: ConversationReminderConfig = .init()) -> [(prospect: Prospect, next: Date)] {
        prospects
            .compactMap { p -> (prospect: Prospect, next: Date)? in
                nextReachOut(for: p, now: now, followUpConfig: followUpConfig,
                             reminderConfig: reminderConfig).map { (prospect: p, next: $0) }
            }
            .sorted { $0.next < $1.next }
    }

    // Contacted prospects with outreach still active, soonest next-reach-out first.
    static func active(from prospects: [Prospect], now: Date,
                       followUpConfig: FollowUpConfig = .init(),
                       reminderConfig: ConversationReminderConfig = .init()) -> [Prospect] {
        activeWithDates(from: prospects, now: now, followUpConfig: followUpConfig,
                        reminderConfig: reminderConfig).map(\.prospect)
    }

    // Plain-language "when to next reach out", shown on each reached-out row (#223). Anything due
    // now or overdue reads "Reach out now"; future dates read "in N day(s)" (whole days, rounded up).
    static func timingLabel(next: Date, now: Date) -> String {
        let seconds = next.timeIntervalSince(now)
        if seconds <= 0 { return "Reach out now" }
        let days = Int((seconds / 86_400).rounded(.up))
        return days == 1 ? "in 1 day" : "in \(days) days"
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
