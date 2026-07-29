import SwiftUI

// #1527: the COLOUR a date clash is drawn in, decided by the same two cases (`ConflictScope`) as the
// sentence describing it, so the two can never disagree about which kind of clash the card is showing.
//
// It lives here rather than beside `ConflictScope` itself because nothing in `Domain/` imports SwiftUI, and
// a colour token is a UI fact.
//
// #1583 retired the pill this originally filled, along with its `pillForeground` companion (the pill was
// the only thing that ever drew text ON the fill; the sentence draws it on the card). What survives is the
// one decision that outlived the badge: which of the two colours this kind of clash gets.
extension ConflictScope {

    // Rust is this app's colour for something that FAILED, so it belongs only on the case that actually
    // failed: a night Dan cannot work. A run bookable on seven of its eight nights takes gold, the colour
    // Overture already uses for a thing that wants a look rather than a thing that is broken
    // (#1428/#1472/#1498 each moved a case out of the alarm colour on exactly this reasoning).
    //
    // `goldText`, not `gold`: this is the one place gold is drawn as TEXT rather than as a fill with dark
    // ink on it, and plain gold measured 3.24 to 1 on the light-theme card, under the bar text has to clear.
    // Same signal colour, same meaning, readable. `rust` needs no such variant; it clears the bar as text in
    // both themes already. See the token's own note, and ConflictNoteColourTests, which measures both.
    var noteTint: Color {
        switch self {
        case .thisNight:     return OVColor.rust
        case .laterInTheRun: return OVColor.goldText
        }
    }
}
