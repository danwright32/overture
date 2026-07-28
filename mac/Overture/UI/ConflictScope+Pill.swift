import SwiftUI

// #1527: the conflict pill's COLOUR, decided by the same two cases as its label (`ConflictScope.pillLabel`,
// in Domain) so the two can never disagree about which kind of clash the card is showing.
//
// It lives here rather than beside `pillLabel` because nothing in `Domain/` imports SwiftUI, and a colour
// token is a UI fact. The pair is one switch on one enum either way; the doc comment on `pillLabel` points
// back here so neither half can be changed without meeting the other.
extension ConflictScope {

    // The capsule behind the label. Rust is this app's colour for something that FAILED, so it belongs only
    // on the case that actually failed: a night Dan cannot work. A run bookable on seven of its eight nights
    // takes gold, the colour Overture already uses for a thing that wants a look rather than a thing that is
    // broken (#1428/#1472/#1498 each moved a case out of the alarm colour on exactly this reasoning).
    var pillFill: Color {
        switch self {
        case .thisNight:     return OVColor.rust
        case .laterInTheRun: return OVColor.gold
        }
    }

    // The label drawn on that capsule. Paired with `pillFill` rather than picked at the call site: which
    // foreground is readable depends entirely on which fill it sits on, and `ConflictPillColourTests`
    // measures every pairing this returns.
    var pillForeground: Color {
        switch self {
        case .thisNight:     return OVColor.onRust
        case .laterInTheRun: return OVColor.onGold
        }
    }
}
