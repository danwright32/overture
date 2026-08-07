import SwiftUI

// #2166: what the reached-out row's trailing column shows, decided out here where it can be tested.
//
// Dan, reading a live row on 2026-08-05, found "Reach out now" stacked directly above an Answer button.
// The button is offered only when somebody is waiting on him, so its existence already means now, and
// the line above it was the same sentence in worse words (#843).
//
// Two rules, and the second is why this is not simply a deletion.
enum ReachedOutRowChrome {
    /// Whether the row prints its timing label. It yields to Answer, which says the same thing better.
    ///
    /// A suppression, not a deletion: on a row with nobody waiting this label is the ONLY thing saying
    /// when the next touch is due, and it also renders the future case ("in N days").
    static func showsTimingLabel(replyOffered: Bool) -> Bool { !replyOffered }

    /// The Answer control's fill. It inherits the urgency the timing label used to carry in rust, so
    /// dropping the label moves the signal rather than losing it.
    ///
    /// Never gold: gold means "Dan can act on this" everywhere else in the app, and a second meaning
    /// here would blunt it.
    static func answerFill(dueNow: Bool) -> Color { dueNow ? OVColor.rust : OVColor.forest }

    /// The label drawn ON that fill.
    ///
    /// Paired with the fill rather than fixed, because of what #1527 found: the warm fills are light
    /// enough in dark mode that white text washes out on them, so a warm fill takes near-black warm ink
    /// instead. A rust capsule wearing the forest label reads perfectly in light mode and is unreadable
    /// in dark, which is the shape of defect a single-background look at it cannot catch (L69).
    static func answerLabel(dueNow: Bool) -> Color { dueNow ? OVColor.onRust : OVColor.onForest }

    /// The conversation-state control's tint.
    ///
    /// #2169: on a form row the timing slot names the night rather than repeating the instruction the
    /// control already gives, so the urgency has to ride on the control or it is simply lost. The same
    /// move #2166 made for Answer: the signal follows the thing Dan presses.
    ///
    /// Nil rather than a quiet colour, because nil is what the control already means by "no accent".
    static func stateControlAccent(isDue: Bool) -> Color? { isDue ? OVColor.rust : nil }
}
