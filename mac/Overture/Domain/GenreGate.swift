import Foundation

// #2687: nothing leaves the queue without a genre.
//
// Dan, 2026-08-13: "file a p1 issue that won't let me keep/dismiss an event if it says no genre read. I
// should have to correct the genre before acting on them." Scope confirmed in the same conversation after
// seeing the numbers: Keep and every Dismiss, including the whole-night bulk dismiss.
//
// The numbers are the point of the issue rather than an objection to it, and they set the bar for the
// implementation. Measured on the live store 2026-08-13: 357 of 584 undecided rows carry no genre, three
// in five. So the correcting control has to be ONE GESTURE from the blocked action, never a detour, or
// triage stops being possible at all. It already is: "Set this show's genre" sits on the same row, and
// setting it re-scores the show on the spot and marks the genre as Dan's so no later run overwrites it.
//
// What the genre buys, recorded here so the gate is not later softened by somebody who assumes it buys
// more or less than it does: up to 3 points of fit score (and the high-fit cutoff is 5), the genre filter
// chip, the outcomes report's grouping, and the drafting run's payload. What it does NOT buy is
// visibility, and setting it can COST visibility: `.other` is on the permissive side of the geographic
// rule, so leaving a genre unread shows Dan more, never less. #1658 already guards that a row currently
// visible stays visible after a genre change, and this gate must not create a path around it.
enum GenreGateCopy {
    // The refusal, named for the act it blocks and pointing at the control that clears it. The wording of
    // that pointer is deliberately the same as the control's own help text ("Set this show's genre"), so a
    // sentence and the button it sends him to cannot come to describe two different things.
    static let blocked = "Set this show's genre before you keep or dismiss it."

    // The same refusal for a whole night, which is one confirm covering many shows, so it has to say HOW
    // MANY rather than speak in the singular about a list (#2687's own requirement 3). Failing silently
    // here would be the worst of the three, since the bulk control is the one that looks like it worked.
    static func nightBlocked(count: Int) -> String {
        count == 1
            ? "1 show tonight has no genre read. Set it before dismissing the night."
            : "\(count) shows tonight have no genre read. Set them before dismissing the night."
    }
}

enum GenreGate {
    // One predicate, in the domain rather than in a view, because three call sites that share nothing
    // today have to ask it: the row's Keep, the row's Dismiss menu, and the whole-night dismiss. Two
    // implementations of it is two places the gate can go missing (L30).
    //
    // `.other` renders as "No genre read" (`Ranker.swift`), and an unrecognised or empty raw value is the
    // same state: nothing readable was stored. Both fail CLOSED, into the gate, because the cost of a
    // wrong block is one click on a control already on the row and the cost of a wrong pass is a show
    // leaving the queue with the thing Dan asked to be forced to set still unset.
    static func blocks(discipline: String) -> Bool {
        (Discipline(rawValue: discipline) ?? .other) == .other
    }

    // The sentence, from the SAME function that decides, so a greyed control can never sit beside no
    // reason. #2544 is the defect this shape exists to prevent: a refusal that only the blocked action
    // could speak was therefore never spoken, and Dan met a disabled button with nothing on screen
    // connecting it to the field it was waiting on (L109).
    static func refusal(discipline: String) -> String? {
        blocks(discipline: discipline) ? GenreGateCopy.blocked : nil
    }

    // How many of a night's shows are blocked, and the sentence naming that count. Nil when the night can
    // be dismissed, so the caller has one thing to ask rather than a count it has to interpret.
    static func nightRefusal(disciplines: [String]) -> String? {
        let blocked = disciplines.filter { blocks(discipline: $0) }.count
        guard blocked > 0 else { return nil }
        return GenreGateCopy.nightBlocked(count: blocked)
    }
}
