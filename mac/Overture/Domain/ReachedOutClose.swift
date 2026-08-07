import Foundation

// #2112 / #2224: closing a pitch out from the stage Dan actually stands on.
//
// Dan, 2026-08-05: "if a show passes it should give me a hint to mark it as lost. also I want a new
// option here called 'No Response' to indicate that they never even responded to my outreach."
// And 2026-08-06, on being told the only control that records a booking is the Archive card: "I'm almost
// NEVER going to the archive. I want to leave it there in case I need it but I don't want to ever HAVE
// to go to the archive."
//
// Two triggers, one affordance. A show that has been and gone needs closing out as lost; a show that got
// a yes needs recording as booked. Both were only reachable from the full card in Archive, which is his
// reference shelf and not a workflow step, so in practice neither outcome got recorded at all. That
// empties the reporting the whole funnel exists to produce (#16).
//
// Nothing here CUTS anything. The hint is a hint: Overture does not decide a pitch is lost on Dan's
// behalf, which is the same rule that keeps `WentByRetirement` off shows he actually pitched, because
// retiring one silently would throw away the record of what happened.
enum ReachedOutClose {
    // The line that appears once the show is over and the pitch is still open, or nil.
    //
    // Keyed on `hasOpened`, the rule #1540 settled: a client's need for photos is over once the run has
    // OPENED, whatever nights remain on it. So a multi-night run passing is ONE event, dated at its
    // opening night, not one per night. A run opening tonight has not opened yet; an undated show never
    // has, because "date to be confirmed" is a normal state on a season page.
    static func passedHint(hasOpened: Bool, isStillOpen: Bool) -> String? {
        guard hasOpened, isStillOpen else { return nil }
        return "This show has been and gone."
    }

    // What the row's outcome control offers, in the order Dan meets them.
    //
    // Deliberately NOT the same list as the Archive card's Mark… menu. That menu also carries "In
    // conversation" and "Bounced", which are not outcomes at all: one is where a live conversation
    // stands (the state control beside this one already sets it, and #1139 exists because the two must
    // never read as the same dropdown) and the other is a delivery fact Overture detects for itself.
    // What is left is the four ways a pitch actually ENDS.
    enum Outcome: String, CaseIterable, Equatable, Sendable {
        case booked
        case neverHeardBack
        case closedNotNow
        case closedNotInterested

        // The words the app already uses for these outcomes, on the Archive card's own menu and on the
        // status line every surface reads. Naming one outcome two ways in two places is the duplicate-copy
        // trap (#843) from the other direction: not the same thing said twice, but the same thing said
        // differently, which is worse, because it reads as two outcomes.
        //
        // `neverHeardBack` takes its words from `InquiryLostReason.neverHeardBack` for the same reason:
        // the two halves of the funnel are answering one question and a second vocabulary for it is how a
        // report ends up unable to add them together.
        var label: String {
            switch self {
            case .booked: return "Booked"
            case .neverHeardBack: return "Never heard back"
            case .closedNotNow: return "Closed (not now)"
            case .closedNotInterested: return "Closed (not interested)"
            }
        }

        var resolution: RecipientResolution {
            switch self {
            case .booked: return .booked
            case .neverHeardBack: return .neverHeardBack
            case .closedNotNow: return .declinedSoft
            case .closedNotInterested: return .declinedHard
            }
        }
    }

    // What the control itself is called. Names the act rather than the field, since "Mark…" beside "Set a
    // state" is two labels for what reads as one kind of thing.
    static let menuLabel = "Close this out"

    // The acknowledgment after one is recorded. Names the outcome back, because the row it was pressed
    // on leaves the stage immediately and a banner that only said "Saved" would be the sole evidence that
    // anything happened at all.
    static func recordedLine(_ outcome: Outcome, org: String) -> String {
        switch outcome {
        case .booked: return "\(org) recorded as booked."
        case .neverHeardBack: return "\(org) closed out: never heard back."
        case .closedNotNow: return "\(org) closed out, not now."
        case .closedNotInterested: return "\(org) closed out, not interested."
        }
    }
}
