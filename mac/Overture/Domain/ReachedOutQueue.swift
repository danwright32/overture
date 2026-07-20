import Foundation

// The "reached out" pipeline (#217, per-recipient since #652): contacted RECIPIENTS Dan is still
// working, ordered by when he should next reach out to that specific contact. Combines the silent
// follow-up sequence (FollowUp) and the conversation reminder track (ConversationReminder), taking
// whichever is sooner. Returns nil: the recipient drops off the list, once outreach to them should
// stop: booked, lost, bounced, or nothing left scheduled.
enum ReachedOutQueue {
    // The soonest moment Dan should next reach out to this recipient, or nil if outreach to them has
    // stopped. A past date (overdue) is returned as-is so it sorts to the top of the list.
    static func nextReachOut(for r: Recipient, of p: Prospect, now: Date,
                             followUpConfig: FollowUpConfig = .init(),
                             reminderConfig: ConversationReminderConfig = .init()) -> Date? {
        guard r.sentAt != nil else { return nil }                 // only contacted recipients
        // #331: a real send always has a contact address; a sent timestamp without one is a
        // staged/corrupt record that was never actually emailed, so it doesn't belong here.
        guard let email = r.email, !email.isEmpty else { return nil }
        // #378: a sent timestamp is not proof of a real send either. Every genuine send (deliver,
        // and DebugStaging's synthetic stand-in for one) stamps a Gmail message id along with
        // sentAt; a record with a timestamp but no message id was never actually sent.
        guard r.gmailMessageId != nil else { return nil }
        let standing = r.standing
        guard standing.isInPlay else { return nil }

        let unhandledReply = r.hasUnhandledReply
        let reminderDate = ConversationReminder.nextReminderDate(
            state: r.conversationState, setAt: r.conversationStateSetAt, remindedAt: r.conversationRemindedAt,
            performanceDate: p.performanceDate, isClosed: !standing.isInPlay, hasUnhandledReply: unhandledReply,
            source: r.conversationStateSource, now: now, config: reminderConfig)
        return [nextFollowUp(for: r, now: now, config: followUpConfig), reminderDate]
            .compactMap { $0 }
            .min()
    }

    // Contacted recipients with outreach still active, each paired with its own next-reach-out date,
    // soonest first. The view formats the date with timingLabel.
    static func activeWithDates(from prospects: [Prospect], now: Date,
                                followUpConfig: FollowUpConfig = .init(),
                                reminderConfig: ConversationReminderConfig = .init()) -> [(prospect: Prospect, recipient: Recipient, next: Date)] {
        prospects
            .flatMap { p in
                p.recipients.compactMap { r -> (prospect: Prospect, recipient: Recipient, next: Date)? in
                    nextReachOut(for: r, of: p, now: now, followUpConfig: followUpConfig,
                                 reminderConfig: reminderConfig).map { (prospect: p, recipient: r, next: $0) }
                }
            }
            .sorted { $0.next < $1.next }
    }

    // Contacted recipients with outreach still active, soonest next-reach-out first.
    static func active(from prospects: [Prospect], now: Date,
                       followUpConfig: FollowUpConfig = .init(),
                       reminderConfig: ConversationReminderConfig = .init()) -> [(prospect: Prospect, recipient: Recipient)] {
        activeWithDates(from: prospects, now: now, followUpConfig: followUpConfig, reminderConfig: reminderConfig)
            .map { (prospect: $0.prospect, recipient: $0.recipient) }
    }

    // #1194: how many SHOWS Dan has active outreach on, counting each show once no matter how many of
    // its contacts he has pitched. The Reached-out stage pill uses this so its number reads like the
    // other stage pills (Scout/Prep/Review all count shows), while the list under it stays per-recipient.
    static func showCount(from prospects: [Prospect], now: Date,
                          followUpConfig: FollowUpConfig = .init(),
                          reminderConfig: ConversationReminderConfig = .init()) -> Int {
        Set(activeWithDates(from: prospects, now: now, followUpConfig: followUpConfig,
                            reminderConfig: reminderConfig).map { $0.prospect.naturalKey }).count
    }

    // #1232: the reached-out list shows one row per contacted RECIPIENT, but its stage pill counts distinct
    // SHOWS (#1194), so a show pitched to two contacts makes the pill read one lower than the visible rows.
    // This quiet note reconciles the two, and appears ONLY when there are genuinely more contacts than
    // shows (equal counts need no note). Pure on the two counts, so it is tested without SwiftData.
    static func contactsAcrossShowsNote(contactCount: Int, showCount: Int) -> String? {
        guard contactCount > showCount else { return nil }
        return "\(contactCount) contacts across \(showCount) \(showCount == 1 ? "show" : "shows")"
    }

    // Plain-language "when to next reach out", shown on each reached-out row (#223). Anything due
    // now or overdue reads "Reach out now"; future dates read "in N day(s)" (whole days, rounded up).
    static func timingLabel(next: Date, now: Date) -> String {
        let seconds = next.timeIntervalSince(now)
        if seconds <= 0 { return "Reach out now" }
        let days = Int((seconds / 86_400).rounded(.up))
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    // The same "overdue or now" threshold timingLabel's "Reach out now" case uses (#661), so a row's
    // "Send a follow-up" action and its timing text can never disagree about whether it's due yet.
    static func isDueNow(next: Date, now: Date) -> Bool {
        next <= now
    }

    // The next silent nudge for a still-silent recipient, mirroring FollowUp.dueRecipients' own
    // eligibility check (r.isAwaitingFollowUp) rather than reimplementing it: paced by gapDays from
    // the last touch, up to maxFollowUps; nothing once this recipient replied/resolved or the cap is
    // reached. Closed recipients are already excluded by the standing.isInPlay guard in nextReachOut.
    private static func nextFollowUp(for r: Recipient, now: Date, config: FollowUpConfig) -> Date? {
        guard let sentAt = r.sentAt else { return nil }
        guard r.isAwaitingFollowUp else { return nil }
        guard r.followUpCount < config.maxFollowUps else { return nil }
        let lastTouch = r.lastFollowUpAt ?? sentAt
        return lastTouch.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
    }
}
