import Foundation
import SwiftData

// #1436: the inquiry actions that CHANGE something, moved out of QueueView, InquiryRowView, and
// the inquiry reply sheet so each is a plain function a test can call (#863, the ExcludedTownMutations /
// WatchlistMutations idiom). Marking an inquiry booked or lost removes it from the queue on screen, so
// the write behind it has to be confirmed rather than attempted: the previous bare
// `try? context.save()` discarded a genuine failure and left the screen showing an outcome the store
// did not have. Persisting goes through the shared `saveOrWarn` (#618) rather than a fifth hand-rolled
// do/catch.
@MainActor
enum InquiryMutations {
    // Dan's two manual closes. Lost is the SOFT case: he is closing something that went quiet, which is
    // not a hard refusal, and #16's outcome reporting keeps the two apart.
    enum MarkAction: Equatable {
        case booked
        case lost(ShowOutcome)

        // #2400: the legacy outcome, still written so every existing reader of `isOpen` and the year-end
        // query keeps working. Their refusal is the hard case; Dan's own pass and a silence both leave the
        // door open, which is what the soft case means.
        //
        // #2863: `theySaidPriceTooHigh` takes the SOFT branch, and it is named here because this is the one
        // reader of the vocabulary the compiler cannot make anybody look at: it is a comparison against a
        // single value, not an exhaustive switch, so a new ending arrives at the soft case with nothing
        // going red. Soft is the right answer, matching `lostDoorOpen` on the show side, because an
        // inquirer who could not meet the rate has not refused the work. `LostOnPriceOutcomeTests` pins it.
        var outcome: Outcome {
            switch self {
            case .booked: return .booked
            case .lost(let ending): return ending == .theySaidNo ? .lostHard : .lostSoft
            }
        }

        // #2400: the ending itself, in the one vocabulary. A booking is an ending too, and the same stored
        // value a booked show carries, so the report can add the two halves.
        var ending: ShowOutcome {
            switch self {
            case .booked: return .booked
            case .lost(let ending): return ending
            }
        }
    }

    // Returns whether the change is confirmed on disk. A false means Dan has already been warned and
    // the caller must not treat the inquiry as closed.
    @discardableResult
    static func mark(_ inquiry: Inquiry, as action: MarkAction, context: ModelContext,
                     feedback: ActionFeedback, now: Date = Date()) -> Bool {
        inquiry.markOutcomeManually(action.outcome, now: now)
        // Always assigned, so marking a previously-lost inquiry booked clears the stale reason rather
        // than leaving one behind for #16 to double-count.
        // Always assigned, so marking a previously-lost inquiry booked replaces the stale ending rather than
        // leaving one behind for #16 to count in two groups.
        inquiry.showOutcome = action.ending
        return context.saveOrWarn(org: inquiry.inquirerName, feedback: feedback)
    }

    // The reply sheet's Send enablement. An inquiry logged without an address cannot be replied to from
    // here at all, which is the case the sheet calls out in its header.
    static func canSend(email: String?, subject: String, body: String) -> Bool {
        guard let email, !email.isEmpty else { return false }
        return !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // #1513: Dan can answer before the first send, and again whenever they have written back. What he
    // cannot do is send into silence: while he is waiting on them the action is absent, because chasing
    // is the follow-up nudge's job, not a second reply.
    // #2145: and never on a thread that BOUNCED, which is the one case where the two halves of the
    // Reached out list disagreed. A show refuses to offer an answer on a bounced thread
    // (Recipient.hasUnhandledReply guards it); an inquiry offered one, so Dan could write a reply to an
    // address that had already proved dead and only learn at the send. Found by asserting both rules
    // against the same state rather than describing the difference in a comment (L57).
    // #2943: asked of the UNANSWERED reply, not of `replied`. Once the answer became its own fact rather
    // than the absence of a reply, `replied` stays true for the rest of the conversation, so a control
    // keyed on it would go on offering itself after it had been pressed and succeeded, which is the exact
    // defect #2170 fixed on the show side (L44). It is the same predicate the row's own state line reads,
    // so the control and the words beside it cannot disagree.
    static func showsReplyAction(sentAt: Date?, hasUnhandledReply: Bool, bounced: Bool) -> Bool {
        guard !bounced else { return false }
        return sentAt == nil || hasUnhandledReply
    }

    // What the reply sheet should do next. `.sent` means the mail is gone and the sheet closes, whether
    // or not the local record of it saved: a save failure there is warned through the shared banner
    // (the mail cannot be un-sent, so holding the sheet open would misdescribe what happened).
    enum SendResult: Equatable {
        case sent
        case sendFailed
    }

    static func sendReply(_ inquiry: Inquiry, subject: String, body: String, now: Date,
                          sender: MailSender, context: ModelContext,
                          feedback: ActionFeedback) async -> SendResult {
        let sent = await InquiryReplySender.sendReply(inquiry, subject: subject, body: body,
                                                      now: now, sender: sender)
        guard sent else { return .sendFailed }
        // #623's shared "sent, but the local record didn't save" path, not a hand-rolled copy of it.
        _ = context.saveOrWarnSendNotConfirmed(org: inquiry.inquirerName, feedback: feedback)
        return .sent
    }
}
