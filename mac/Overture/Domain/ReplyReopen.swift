import Foundation

// #2915: whether a reply arriving after a close-out refutes the ending that was recorded.
//
// ONE definition, called by both `Prospect.reopenOnReply` and `Inquiry.reopenOnReply`. Both carry the
// same `showOutcome` from the same vocabulary and both ride the same reply check, so a rule written
// twice would be two rules that agree today (L16). An inquiry closed as "never heard back" whose sender
// writes back is the same situation as a scouted show's, and it would have been the half nobody covered.
enum ReplyReopen {

    // Dan's call, 2026-08-23: only "never heard back". That ending's whole content is "nobody ever
    // answered", so a reply flatly refutes it. Every other ending records something that HAPPENED, and a
    // later message does not make it not have happened: a courtesy note, a change of address or a
    // mailing list blast would otherwise resurrect a correctly closed show and overwrite his own
    // judgement. It is the same call #1840 made at the contact level, where `Recipient.reopenOnReply`
    // clears a stand-down and leaves a booking or a real decline alone.
    //
    // EXHAUSTIVE over the vocabulary rather than `== .neverHeardBack`, so an ending added later has to be
    // judged here rather than falling into the safe branch unread (L113). The compiler is what asks.
    static func endingIsRefuted(by outcome: ShowOutcome) -> Bool {
        switch outcome {
        case .neverHeardBack: return true
        case .booked, .theySaidNo, .theySaidNotNow, .theySaidPriceTooHigh, .turnedThemDown,
             .dateConflict, .hadPaidWork, .pitchingOtherShows, .tooSoon, .notAFit,
             .dontWantToShoot, .noWayToReachThem, .duplicate, .wentBy, .tooFar:
            return false
        }
    }

    // And only a reply NEWER than the ending. A reply that predates the close-out is the evidence Dan
    // already had when he closed it, and reopening on it would undo his decision using the very thing he
    // made it in spite of, on every check for ever.
    //
    // An ending carrying NO stamp is left alone, which is the same rule pointing the other way: refusing
    // is the safe direction when the comparison cannot be made at all. Everything closed out before
    // #2915 shipped is in that state, and Dan can still reopen any of them by hand.
    static func shouldClear(outcome: ShowOutcome?, closedAt: Date?, repliedAt: Date) -> Bool {
        guard let outcome, endingIsRefuted(by: outcome) else { return false }
        guard let closedAt else { return false }
        return repliedAt > closedAt
    }
}
