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

// A UI-agnostic accent for a reminder/state, so the colour decision is testable without SwiftUI.
// The view maps each token to a brand colour. onTrack = heading to a booking, attention = someone
// waiting on a reply, warm = interested/uncategorized, neutral = winding down.
enum ReminderAccent: Equatable, Sendable {
    case onTrack, attention, warm, neutral
}

extension ConversationState {
    var accent: ReminderAccent {
        switch self {
        case .wantsToBook: return .onTrack
        case .hasQuestion: return .attention
        case .interested: return .warm
        case .declined: return .neutral
        }
    }
}

enum ConversationReminder {
    enum Kind: Equatable, Sendable {
        case active(ConversationState)     // a timed interval/event reminder for a CONFIRMED state
        case suggested(ConversationState)  // an AUTO (AI) guess awaiting Dan's confirm/correct (#112)
        case closing                       // post-event "perhaps another time" note
        case needsState                    // replied but uncategorized: prompt Dan to set a state
    }

    static func accent(for kind: Kind) -> ReminderAccent {
        switch kind {
        case .active(let state): return state.accent
        case .suggested(let state): return state.accent
        case .needsState: return .warm
        case .closing: return .neutral
        }
    }

    // Due-queue order (Dan's call): a verbal yes is the lead most likely to book, so it leads;
    // then someone awaiting a reply, then warm-but-cooling, then a reply still to triage, and the
    // lapsed-event closing note last (least time-sensitive). due() applies this, ties broken by
    // soonest event, so the ordering is owned and tested here, not in the view.
    static func urgencyRank(_ kind: Kind) -> Int {
        switch kind {
        case .active(.wantsToBook): return 0
        case .active(.hasQuestion): return 1
        case .active(.interested): return 2
        case .needsState: return 3
        case .closing: return 4
        case .active(.declined): return 5   // unreachable: declined is never due
        case .suggested(let s): return urgencyRank(.active(s))   // a suggestion ranks like its state
        }
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
        case .suggested(let s): return "Suggested: \(s.label)"
        case .closing: return "Event passed, send a closing note"
        case .needsState: return "Replied, needs a state"
        }
    }

    static func reminder(state: ConversationState?, setAt: Date?, remindedAt: Date?,
                         performanceDate: String?, outcome: Outcome, source: OutcomeSource?, now: Date,
                         config: ConversationReminderConfig = .init()) -> DueReminder? {
        // A booking or a lost outcome clears every conversation reminder.
        guard outcome != .booked, outcome != .lostSoft, outcome != .lostHard else { return nil }

        guard let state else {
            // No state yet: a replied lead needs categorizing (so it can't go cold before #112);
            // anything else belongs to the silent FollowUp sequence, not here.
            return outcome == .replied ? DueReminder(kind: .needsState, reason: reason(for: .needsState)) : nil
        }

        guard state.isActive, let interval = config.intervalDays(for: state) else { return nil }

        // An AUTO (AI-classified) state is unconfirmed: surface it IMMEDIATELY as a suggestion so the
        // lead never silently drops out of Due before its timed reminder would come due (the #112
        // blocker). Confirming flips the source to manual and hands off to the timed track below.
        if source == .auto {
            return DueReminder(kind: .suggested(state), reason: reason(for: .suggested(state)))
        }

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
                     outcome: p.outcome, source: p.conversationStateSource, now: now, config: config).map { (p, $0) }
        }
        .sorted {
            let ra = urgencyRank($0.1.kind), rb = urgencyRank($1.1.kind)
            if ra != rb { return ra < rb }
            return ($0.0.performanceDate ?? "9999") < ($1.0.performanceDate ?? "9999")
        }
    }

    // The pre-written, reviewable nudge per active state, in Dan's level voice (no performative
    // enthusiasm, no em dashes, contractions throughout). Dan edits before sending; the hasQuestion
    // copy is deliberately generic since it cannot know the specific question. Follows the
    // dan-wright-brand-voice skill. Mirrors FollowUp.nudgeBody.
    static func nudgeBody(for state: ConversationState, contactName: String?, groupName: String, venue: String?) -> String {
        let greeting = "Hi \(firstName(contactName)),"
        let g = groupName + venueClause(venue)
        let signoff = "\n\nBest,\nDan Wright\nDan Wright Photography"
        let middle: String
        switch state {
        case .interested:
            middle = "\n\nI wanted to follow up about photographing \(g). If documentary coverage of the "
                + "performance would be useful, I'm glad to share a few sample frames or talk through specifics. "
                + "No problem if the timing isn't right."
        case .wantsToBook:
            middle = "\n\nFollowing up on photographing \(g). Whenever you're ready to set the date I can hold it "
                + "and send over the details. Let me know what works on your end."
        case .hasQuestion:
            middle = "\n\nI wanted to make sure I answered your question about photographing \(g). Happy to clarify "
                + "anything on coverage, timing, or rate. Let me know what would help."
        case .declined:
            middle = "\n\nFollowing up on photographing \(g)."   // unreachable: declined is never active
        }
        return greeting + middle + signoff
    }

    // The gracious post-event close: a kind "perhaps another time" that keeps the relationship warm
    // for a future season. Sending it resolves the lead to lost-soft.
    static func closingNudgeBody(contactName: String?, groupName: String, venue: String?) -> String {
        let greeting = "Hi \(firstName(contactName)),"
        let g = groupName + venueClause(venue)
        let signoff = "\n\nBest,\nDan Wright\nDan Wright Photography"
        return greeting + "\n\nI know \(g) has come and gone, and the timing didn't line up this round. "
            + "No worries at all. If there's a future performance you'd like documented, I'd be glad to help "
            + "then. Either way, it was good to be in touch." + signoff
    }

    private static func venueClause(_ venue: String?) -> String {
        (venue?.isEmpty == false) ? " at \(venue!)" : ""
    }

    private static func firstName(_ name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "there" }
        return n.split(separator: " ").first.map(String.init) ?? "there"
    }
}
