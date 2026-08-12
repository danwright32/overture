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

    /// #2551: the night the show is actually on, which this row never said.
    ///
    /// The date HEADINGS on this stage are reach-out dates, and #1233 added the caption "Grouped by when
    /// to reach out next" precisely because the two were being confused. The caption did its job and the
    /// effect was that the stage named one date clearly and the other not at all. Dan, 2026-08-11: "it
    /// doesn't give me any indication of when the show is, just when to reach out. Both are needed I
    /// think." On the row he was reading, the two dates happened to be the same day.
    ///
    /// It matters for triage: a show that has gone quiet three months out is fine, one that is tonight is
    /// a different decision, and that is the decision he is standing in front of on this stage.
    ///
    /// ABSOLUTE, where the timing slot beside it is RELATIVE ("in 5 days", "tonight"). That is what stops
    /// the two collapsing into one sentence (#843), and it is why this says the date rather than a
    /// countdown even though a countdown would be shorter.
    ///
    /// Dated through `QueueModel.runDateLabel`, the same helper the queue card uses, so one run cannot be
    /// described in two different words on two screens. #2551 proposed naming only the OPENING night on
    /// the grounds that #1540 dates a run at its opening; that rule governs how a run SORTS and when it
    /// counts as opened, and it is untouched here. What the row has to answer is how far out the show is,
    /// and for a run the honest answer is the window, which is what the card already prints.
    ///
    /// An undated show says so. "Date to be confirmed" is a normal state on a season page, so a
    /// fabricated night would send Dan looking for a show nobody published (L11), and silence would leave
    /// the row exactly as mute as the one he complained about. It names the SHOW's date, because the
    /// headings above it are reach-out dates and a bare "date to be confirmed" would read as those.
    static func showDateLine(performanceDate: String?, runEndDate: String?) -> String {
        // The same parse `runDateLabel` makes (`QueueModel.day` IS `EasternDate.date(from:)`), so this
        // cannot decide the show is dated and then be handed "Date to be confirmed" to prefix.
        guard let performanceDate, EasternDate.date(from: performanceDate) != nil else {
            return "Show date to be confirmed"
        }
        return "Performs \(QueueModel.runDateLabel(start: performanceDate, end: runEndDate))"
    }
}
