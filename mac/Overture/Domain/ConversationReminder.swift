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

// Persistence for the cadence (#178). The intervals and lead buffer are sensible baked defaults, but
// Dan may want to retune them once he sees them in real use, without a code change. They round-trip
// through UserDefaults under these keys; any key he hasn't touched falls back to the baked default,
// so behavior is unchanged until he edits. Injected defaults keep test side effects contained, the
// same pattern ScoutService uses. The values stay whole days, matching the rest of the calculator.
extension ConversationReminderConfig {
    enum Keys {
        static let wantsToBook = "reminderWantsToBookDays"
        static let hasQuestion = "reminderHasQuestionDays"
        static let interested = "reminderInterestedDays"
        static let leadBuffer = "reminderLeadBufferDays"
    }

    static func loaded(from defaults: UserDefaults = .standard) -> ConversationReminderConfig {
        let baked = ConversationReminderConfig()
        return ConversationReminderConfig(
            interestedDays: stored(defaults, Keys.interested) ?? baked.interestedDays,
            wantsToBookDays: stored(defaults, Keys.wantsToBook) ?? baked.wantsToBookDays,
            hasQuestionDays: stored(defaults, Keys.hasQuestion) ?? baked.hasQuestionDays,
            leadBufferDays: stored(defaults, Keys.leadBuffer) ?? baked.leadBufferDays)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(interestedDays, forKey: Keys.interested)
        defaults.set(wantsToBookDays, forKey: Keys.wantsToBook)
        defaults.set(hasQuestionDays, forKey: Keys.hasQuestion)
        defaults.set(leadBufferDays, forKey: Keys.leadBuffer)
    }

    // nil when the key was never set (so the caller keeps the baked default), distinguishing an
    // absent key from a deliberately stored 0 (a valid lead buffer meaning "due by the event day").
    private static func stored(_ defaults: UserDefaults, _ key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
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

    // The single source of truth for WHEN the next conversation reminder is due (#224): shared by
    // reminder() (the Due gate) and ReachedOutQueue (the reached-out schedule) so the two can't drift.
    // nil means no reminder applies (booked/lost, no active state, or nothing scheduled). An immediate
    // case (needs a state, an unconfirmed AI state, or the event has passed) returns `now`. Otherwise
    // the timed track: the earlier of (anchor + interval) and (event - lead buffer).
    static func nextReminderDate(state: ConversationState?, setAt: Date?, remindedAt: Date?,
                                 performanceDate: String?, isClosed: Bool, hasUnhandledReply: Bool,
                                 source: OutcomeSource?,
                                 now: Date, config: ConversationReminderConfig = .init()) -> Date? {
        guard !isClosed else { return nil }
        guard let state else {
            return hasUnhandledReply ? now : nil   // replied but uncategorized: needs a state now
        }
        guard state.isActive, let interval = config.intervalDays(for: state) else { return nil }
        if source == .auto { return now }             // unconfirmed AI state: surface immediately
        let daysToEvent = performanceDate.flatMap { EasternDate.daysUntil(from: EasternDate.today(now), to: $0) }
        if let d = daysToEvent, d < 0 { return now }  // the day after the show: closing note
        var dates: [Date] = []
        if let anchor = remindedAt ?? setAt {
            dates.append(anchor.addingTimeInterval(TimeInterval(interval) * 86_400))
        }
        if let d = daysToEvent {
            dates.append(now.addingTimeInterval(TimeInterval(d - config.leadBufferDays) * 86_400))
        }
        return dates.min()
    }

    static func reminder(state: ConversationState?, setAt: Date?, remindedAt: Date?,
                         performanceDate: String?, isClosed: Bool, hasUnhandledReply: Bool,
                         source: OutcomeSource?, now: Date,
                         config: ConversationReminderConfig = .init()) -> DueReminder? {
        guard let date = nextReminderDate(state: state, setAt: setAt, remindedAt: remindedAt,
                                          performanceDate: performanceDate, isClosed: isClosed,
                                          hasUnhandledReply: hasUnhandledReply,
                                          source: source, now: now, config: config) else { return nil }
        guard now >= date else { return nil }   // scheduled, but not due yet

        // Due: classify the kind. No state yet means a replied lead needs categorizing (#112).
        guard let state else { return DueReminder(kind: .needsState, reason: reason(for: .needsState)) }
        // An unconfirmed AI state surfaces as a suggestion until Dan confirms it (the #112 blocker).
        if source == .auto { return DueReminder(kind: .suggested(state), reason: reason(for: .suggested(state))) }
        let daysToEvent = performanceDate.flatMap { EasternDate.daysUntil(from: EasternDate.today(now), to: $0) }
        if let d = daysToEvent, d < 0 { return DueReminder(kind: .closing, reason: reason(for: .closing)) }
        return DueReminder(kind: .active(state), reason: reason(for: .active(state)))
    }

    static func due(from prospects: [Prospect], now: Date,
                    config: ConversationReminderConfig = .init()) -> [(Prospect, DueReminder)] {
        prospects.compactMap { p in
            guard p.status != .dismissed else { return nil }   // #238: dismissed leads stop nagging
            return reminder(state: p.conversationState, setAt: p.conversationStateSetAt,
                            remindedAt: p.conversationRemindedAt, performanceDate: p.performanceDate,
                            isClosed: p.isClosed, hasUnhandledReply: p.hasUnhandledReply,
                            source: p.conversationStateSource, now: now, config: config).map { (p, $0) }
        }
        .sorted {
            let ra = urgencyRank($0.1.kind), rb = urgencyRank($1.1.kind)
            if ra != rb { return ra < rb }
            return ($0.0.performanceDate ?? "9999") < ($1.0.performanceDate ?? "9999")
        }
    }

    struct DueRecipient { let prospect: Prospect; let recipient: Recipient }

    // Per-recipient due calculation (#650 Phase 1), mirroring FollowUp.dueRecipients' shape exactly:
    // a hand-resolved or booked show stops ALL its reminders (matches the lead-level auto-stop), then
    // each recipient is evaluated independently through the same pure reminder() calculator, using
    // Recipient.standing (already-established in PerformanceStatus.swift) for the per-recipient
    // "closed" and "unhandled reply" inputs that Prospect.isClosed/hasUnhandledReply provide at the
    // lead level.
    static func dueRecipients(from prospects: [Prospect], now: Date,
                             config: ConversationReminderConfig = .init()) -> [DueRecipient] {
        var due: [DueRecipient] = []
        for p in prospects {
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue || p.outcome == .booked { continue }
            for r in p.recipients {
                let standing = r.standing
                let unhandledReply = r.replied && standing.resolution == nil && !standing.bounced
                guard reminder(state: r.conversationState, setAt: r.conversationStateSetAt,
                              remindedAt: r.conversationRemindedAt, performanceDate: p.performanceDate,
                              isClosed: !standing.isInPlay, hasUnhandledReply: unhandledReply,
                              source: r.conversationStateSource, now: now, config: config) != nil
                else { continue }
                due.append(DueRecipient(prospect: p, recipient: r))
            }
        }
        return due
    }

    // The pre-written, reviewable nudge per active state, in Dan's level voice (no performative
    // enthusiasm, no em dashes, contractions throughout). Dan edits before sending; the hasQuestion
    // copy is deliberately generic since it cannot know the specific question. Follows the
    // dan-wright-brand-voice skill. Mirrors FollowUp.nudgeBody.
    static func nudgeBody(for state: ConversationState, contactName: String?, groupName: String, venue: String?) -> String {
        let greeting = Salutation.greeting(for: contactName)
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
        let greeting = Salutation.greeting(for: contactName)
        let g = groupName + venueClause(venue)
        let signoff = "\n\nBest,\nDan Wright\nDan Wright Photography"
        return greeting + "\n\nI know \(g) has come and gone, and the timing didn't line up this round. "
            + "No worries at all. If there's a future performance you'd like documented, I'd be glad to help "
            + "then. Either way, it was good to be in touch." + signoff
    }

    private static func venueClause(_ venue: String?) -> String {
        (venue?.isEmpty == false) ? " at \(venue!)" : ""
    }
}
