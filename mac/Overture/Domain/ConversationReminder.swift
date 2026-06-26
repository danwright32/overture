import Foundation

// The pure conversation-reminder calculator (#111), the sibling of FollowUp for ACTIVE conversations
// (FollowUp only nudges silent, no-response leads). Decides who is due and why, with event-aware
// timing: the show date is the real deadline, so a near event pulls the reminder forward of its
// interval, and once the event passes the due item becomes a gracious closing note. Pure, never
// sends. All date math goes through EasternDate (#116). Booked/lost clear every reminder for free.
struct ConversationReminderConfig: Sendable {
    var interestedDays: Int = 10
    var wantsToBookDays: Int = 7
    var hasQuestionDays: Int = 2
    // The latest a reminder may fire before the event: due no later than (event - leadBufferDays).
    var leadBufferDays: Int = 3

    func intervalDays(for state: ConversationState) -> Int? {
        switch state {
        case .interested: return interestedDays
        case .wantsToBook: return wantsToBookDays
        case .hasQuestion: return hasQuestionDays
        case .declined: return nil
        }
    }
}

enum ConversationReminder {
    enum Kind: Equatable, Sendable {
        case active(ConversationState)   // an interval/event reminder for an active state
        case closing                     // post-event "perhaps another time" note
        case needsState                  // replied but uncategorized: prompt Dan to set a state
    }

    struct DueReminder: Equatable, Sendable {
        let kind: Kind
        let reason: String
    }

    static func reason(for kind: Kind) -> String {
        switch kind {
        case .active(.interested): return "Interested, going quiet"
        case .active(.wantsToBook): return "Verbal yes, not booked"
        case .active(.hasQuestion): return "Owes a reply"
        case .active(.declined): return ""   // unreachable: declined is never active
        case .closing: return "Event passed, send a closing note"
        case .needsState: return "Replied, needs a state"
        }
    }

    static func reminder(state: ConversationState?, setAt: Date?, remindedAt: Date?,
                         performanceDate: String?, outcome: Outcome, now: Date,
                         config: ConversationReminderConfig = .init()) -> DueReminder? {
        // A booking or a lost outcome clears every conversation reminder.
        guard outcome != .booked, outcome != .lostSoft, outcome != .lostHard else { return nil }

        guard let state else {
            // No state yet: a replied lead needs categorizing (so it can't go cold before #112);
            // anything else belongs to the silent FollowUp sequence, not here.
            return outcome == .replied ? DueReminder(kind: .needsState, reason: reason(for: .needsState)) : nil
        }

        guard state.isActive, let interval = config.intervalDays(for: state) else { return nil }

        // Event-aware: how many Eastern days from today to the show (nil if no date).
        let daysToEvent = performanceDate.flatMap { EasternDate.daysUntil(from: EasternDate.today(now), to: $0) }
        if let d = daysToEvent, d < 0 {
            return DueReminder(kind: .closing, reason: reason(for: .closing))   // the day after the show
        }

        // Due when the interval has elapsed since the anchor, OR we have reached the lead buffer
        // before the event (whichever is earlier), i.e. now >= min(anchor + interval, event - buffer).
        let intervalDue: Bool = {
            guard let anchor = remindedAt ?? setAt else { return false }
            return now.timeIntervalSince(anchor) >= TimeInterval(interval) * 86_400
        }()
        let eventForcesDue = (daysToEvent.map { $0 <= config.leadBufferDays }) ?? false

        guard intervalDue || eventForcesDue else { return nil }
        return DueReminder(kind: .active(state), reason: reason(for: .active(state)))
    }

    static func due(from prospects: [Prospect], now: Date,
                    config: ConversationReminderConfig = .init()) -> [(Prospect, DueReminder)] {
        prospects.compactMap { p in
            reminder(state: p.conversationState, setAt: p.conversationStateSetAt,
                     remindedAt: p.conversationRemindedAt, performanceDate: p.performanceDate,
                     outcome: p.outcome, now: now, config: config).map { (p, $0) }
        }
    }
}
