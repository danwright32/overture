import Foundation

// #2130: what the reached-out row's action control is actually FOR.
//
// Dan pressed "Send a follow-up" on 2026-08-05 and landed on a list that could send nothing. The control
// could not be fixed by wiring it to a send, because "due now" on that row is `min` of several separate
// clocks (the nudge sequence, the form decision, the post-event prompt) and so means several different
// things. Not all of them are sendable: #2397's close-out prompt asks Dan to record a decision, and there
// is no email to put in front of him at all.
//
// So the row asks what is due and labels itself accordingly, exactly as the Due sheet already does.
// His rule: "buttons need to do what they say."
// Deliberately NOT answering a reply. That has its own control on the row (#2128) and its own panel; this
// is the slot for what Overture would SEND or ASK next, and folding the two together is what let one
// button stand for six different things in the first place.
enum ReachedOutAction: String, Equatable, Sendable, CaseIterable {
    case sendNudge           // a silent contact, due a gentle prod
    case sendClosingNote     // the show has passed: the gracious note that keeps the relationship warm
    case sayHowItEnded       // #2397: the show has passed and somebody replied, so Dan records the ending
    case sayWhatHappened     // a form pitch Overture can neither send nor detect a reply to
    case none

    // The row's label. nil means the slot shows nothing at all, which is the honest answer when nothing
    // is due: an always-present button that refuses on press is the defect this replaces.
    var label: String? {
        switch self {
        case .sendNudge: return "Send a follow-up"
        case .sendClosingNote: return "Send a closing note"
        // #2397: no button here. The close-out menu beside this slot is how Dan records an ending, and a
        // second control with the same purpose is the duplicate-copy trap #843 exists for. The case stays,
        // because it is still what the row is waiting for.
        case .sayHowItEnded: return nil
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
        case .sayHowItEnded, .sayWhatHappened, .none: return false
        }
    }

    // Asked of the row the list stands on.
    static func of(_ recipient: Recipient, in prospect: Prospect, now: Date, today: String,
                   followUpConfig: FollowUpConfig = .init()) -> ReachedOutAction {
        // A form pitch with no conversation attached has no thread and no send: the only thing that moves
        // it forward is Dan saying where it stands, and a send button here would promise something
        // Overture cannot do.
        //
        // #2716: asked of `isUnwatchedFormPitch` rather than of the channel. This branch used to return
        // `.sayWhatHappened` or `.none` FOREVER for a form pitch, and its old comment ("a form pitch has
        // no thread and no send") became false the moment #2715 let one be attached, so no post-event
        // prompt could ever be offered on a contact holding a live conversation (L55).
        if recipient.isUnwatchedFormPitch {
            guard let next = ReachedOutQueue.nextReachOut(for: recipient, of: prospect, now: now,
                                                          followUpConfig: followUpConfig),
                  ReachedOutQueue.isDueNow(next: next, now: now) else { return .none }
            return .sayWhatHappened
        }

        // #2397: the post-event track, which is the closing note and the close-out prompt.
        if let prompt = PostEventPrompt.prompt(for: recipient, of: prospect, now: now) {
            switch prompt.kind {
            case .closingNote:
                // #2716: the closing note is a real email that threads off `gmailMessageId`, and an
                // attached conversation never carries one by design (Overture sent nothing on it). So on
                // that one row the send is impossible and offering it would put a button there that can
                // only refuse (L109); Dan records the ending instead, exactly as he does for an
                // unwatched form pitch. #2717 makes the send path itself refuse, which is the other half.
                //
                // Reachable ONLY from an attached form or DM pitch: every emailed contact in this queue
                // has passed `hasProvenOutreach`, which demands a message id, so this cannot quietly
                // swallow the closing note on an ordinary row.
                return recipient.gmailMessageId == nil ? .sayWhatHappened : .sendClosingNote
            case .closeOut: return .sayHowItEnded
            }
        }

        // The silent-nudge sequence.
        if FollowUp.isDue(eligible: FollowUp.isAwaitingNudge(recipient, in: prospect, now: now),
                          sentAt: recipient.sentAt, lastFollowUpAt: recipient.lastFollowUpAt,
                          followUpCount: recipient.followUpCount, remindedAt: recipient.nudgeRemindedAt,
                          now: now, config: followUpConfig) {
            return .sendNudge
        }
        return .none
    }
}
