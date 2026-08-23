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
        // #2863: `theySaidPriceTooHigh` takes the SOFT branch. Soft is the right answer, matching
        // `lostDoorOpen` on the show side, because an inquirer who could not meet the rate has not refused
        // the work. `LostOnPriceOutcomeTests` pins it, and #2950 made the mapping below exhaustive so the
        // compiler names the next ending rather than leaving it to be noticed.
        var outcome: Outcome {
            switch self {
            case .booked: return .booked
            case .lost(let ending): return Self.legacyOutcome(for: ending)
            }
        }

        // #2950: EXHAUSTIVE, as every other reader of this vocabulary is (#2586, `countedPhrase`).
        //
        // It used to be `ending == .theySaidNo ? .lostHard : .lostSoft`, a comparison against one value,
        // so every ending added later landed on the soft case with nothing going red and nobody asked.
        // #2863's `theySaidPriceTooHigh` walked straight into it: soft was the right answer, but that was
        // luck rather than a decision, and only a test written for that one case pinned it. A comparison
        // answers for cases nobody has considered; a switch makes the compiler name them (L113).
        private static func legacyOutcome(for ending: ShowOutcome) -> Outcome {
            switch ending {
            // The hard case is a refusal of the work itself, and it is the only one.
            case .theySaidNo: return .lostHard
            // Soft: a silence, a "not now", and a budget answer all leave the door open, and Dan's own
            // refusal closes it from his side rather than theirs. Matches `lostDoorOpen` on the show side.
            case .neverHeardBack, .theySaidNotNow, .theySaidPriceTooHigh, .turnedThemDown: return .lostSoft
            // An ending that says the inquiry BOOKED is not a loss whatever it arrived wrapped in, so it
            // answers what it says. `InquiryEnding.danCanChoose` filters it out of the menu, and the row
            // has its own Booked control, so this is unreachable today rather than a second way in.
            case .booked: return .booked
            // The never-pitched half and Overture's own two. None can reach an inquiry close-out: the
            // menu is `InquiryEnding.danCanChoose`, which is `ShowOutcome.pitched` minus booked. They are
            // named rather than defaulted so that adding a case to EITHER half breaks the build here and
            // this decision gets made again, which is the whole of what a comparison could not do.
            case .dateConflict, .hadPaidWork, .pitchingOtherShows, .tooSoon, .notAFit, .dontWantToShoot,
                 .noWayToReachThem, .duplicate, .wentBy, .tooFar:
                return .lostSoft
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
        // #2915: WHEN, so a reply arriving afterwards can be compared against it. Without this every
        // inquiry ending is undateable and the reopen rule can never fire for one.
        inquiry.showOutcomeAt = Date()
        return context.saveOrWarn(org: inquiry.inquirerName, feedback: feedback)
    }

    // The reply sheet's Send enablement. An inquiry logged without an address cannot be replied to from
    // here at all, which is the case the sheet calls out in its header.
    // #2797: undo an automatic attach that landed on the wrong inquiry. #2712 links these WITHOUT
    // asking, because the match is address identity rather than a guess, and that is exactly what made
    // the missing undo the remaining risk: a wrong attach had no way back at all (L9, L97).
    //
    // The refusal is SPOKEN, never a silent no-op. `DetachConversation` decides and supplies the reason,
    // so a control that declines and the sentence beside it cannot disagree (L109). A success says what
    // it could NOT take back, because an away alert and an OmniFocus task may already have left the app
    // and a detach that stayed quiet would be claiming an exactness it does not have (L38).
    static func detachConversation(_ inquiry: Inquiry, context: ModelContext,
                                   feedback: ActionFeedback, now: Date = Date()) {
        switch DetachConversation.detach(inquiry, now: now) {
        case .refused(let reason):
            feedback.acknowledge(reason, tone: .warning)
        case .detached(let couldNotUndo):
            guard context.saveOrWarn(org: inquiry.inquirerName, feedback: feedback) else { return }
            // OPTIONAL, and nil means there was nothing it could not take back. Saying something anyway
            // would name a consequence that did not happen (L11).
            if let couldNotUndo { feedback.acknowledge(couldNotUndo) }
        }
    }

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
