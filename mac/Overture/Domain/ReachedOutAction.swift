import Foundation

// #2130: what the reached-out row's action control is actually FOR.
//
// Dan pressed "Send a follow-up" on 2026-08-05 and landed on a list that could send nothing. The control
// could not be fixed by wiring it to a send, because "due now" on that row is `min` of three separate
// clocks (the nudge sequence, the form decision, the conversation reminder) and so means any of six
// different things. Two of them are not sendable at all: ConversationReminder.nudgeContent returns nil
// for a state that needs setting and for an AI guess that needs confirming.
//
// So the row asks what is due and labels itself accordingly, exactly as the Due sheet already does.
// His rule: "buttons need to do what they say."
// Deliberately NOT answering a reply. That has its own control on the row (#2128) and its own panel; this
// is the slot for what Overture would SEND or ASK next, and folding the two together is what let one
// button stand for six different things in the first place.
enum ReachedOutAction: String, Equatable, Sendable, CaseIterable {
    case sendNudge           // a silent contact, due a gentle prod
    case sendClosingNote     // the show has passed: the gracious note that keeps the relationship warm
    case confirmState        // an AI guess awaiting Dan's confirm or correction
    case sayWhatHappened     // a form pitch Overture can neither send nor detect a reply to
    case none

    // The row's label. nil means the slot shows nothing at all, which is the honest answer when nothing
    // is due: an always-present button that refuses on press is the defect this replaces.
    var label: String? {
        switch self {
        case .sendNudge: return "Send a follow-up"
        case .sendClosingNote: return "Send a closing note"
        // #2154: no button. The row drew Confirm TWICE, from this slot and from the state control
        // beside it, both calling the same mutation with the same arguments. The state control owns the
        // guess and shows what the guess actually IS, while a bare second "Confirm" says nothing about
        // what it confirms, so this is the copy that goes (#843, the same reasoning `.sayWhatHappened`
        // already carries). The case itself stays: it is still what the row is waiting for.
        case .confirmState: return nil
        // No button: the row's own timing text already reads "Say what happened" for a form pitch, and
        // the state control beside it is how he says it. A second control with the same words is the
        // duplicate-copy trap #843 exists for.
        case .sayWhatHappened: return nil
        case .none: return nil
        }
    }

    // Whether pressing it puts an email in front of Dan to approve and send. The wording and this flag are
    // tested against each other, so a label that says Send cannot come to mean something that does not.
    var sendsAnEmail: Bool {
        switch self {
        case .sendNudge, .sendClosingNote: return true
        case .confirmState, .sayWhatHappened, .none: return false
        }
    }

    // Asked of the row the list stands on.
    static func of(_ recipient: Recipient, in prospect: Prospect, now: Date, today: String,
                   followUpConfig: FollowUpConfig = .init(),
                   reminderConfig: ConversationReminderConfig = .init()) -> ReachedOutAction {
        // A form pitch has no thread and no send: the only thing that moves it forward is Dan saying where
        // it stands, and a send button here would promise something Overture cannot do.
        if recipient.outreachChannel == .contactForm {
            guard let next = ReachedOutQueue.nextReachOut(for: recipient, of: prospect, now: now,
                                                          followUpConfig: followUpConfig,
                                                          reminderConfig: reminderConfig),
                  ReachedOutQueue.isDueNow(next: next, now: now) else { return .none }
            return .sayWhatHappened
        }

        // The conversation track, which owns the closing note and the AI guess.
        let standing = recipient.standing
        if let due = ConversationReminder.reminder(
            state: recipient.conversationState, setAt: recipient.conversationStateSetAt,
            remindedAt: recipient.conversationRemindedAt, performanceDate: prospect.performanceDate,
            isClosed: !standing.isInPlay && recipient.resolution != .stoodDown,
            hasUnhandledReply: recipient.hasUnhandledReply, repliedAt: recipient.replyArrivedAt,
            source: recipient.conversationStateSource, now: now, config: reminderConfig) {
            switch due.kind {
            case .closing: return .sendClosingNote
            case .suggested: return .confirmState
            case .active: return .sendNudge
            // Replied and uncategorised. The Answer control and the state control beside this slot both
            // already cover it, so this slot stays empty rather than asking the same thing a third time.
            // Crucially it is never a nudge: a generic prod is exactly the wrong email to send somebody
            // who has already written and is waiting.
            case .needsState: return .none
            }
        }

        // The silent-nudge sequence.
        if FollowUp.isDue(eligible: FollowUp.isAwaitingNudge(recipient, in: prospect),
                          sentAt: recipient.sentAt, lastFollowUpAt: recipient.lastFollowUpAt,
                          followUpCount: recipient.followUpCount, remindedAt: recipient.nudgeRemindedAt,
                          now: now, config: followUpConfig) {
            return .sendNudge
        }
        return .none
    }
}
