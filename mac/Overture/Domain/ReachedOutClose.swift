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
// #2395: this no longer owns a list of outcomes. The endings come from `ShowOutcome`, the one vocabulary,
// so the four ways a pitch can end are named once for every surface instead of once per control. What is
// left here is the affordance's own copy: when to hint that a show has been and gone, and what the control
// is called.
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

    // What the control itself is called. Names the act rather than the field, since "Mark…" beside "Set a
    // state" is two labels for what reads as one kind of thing.
    static let menuLabel = "Close this out"
}
