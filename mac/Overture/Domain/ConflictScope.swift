import Foundation

// #1501: whether a date conflict is on the night this card is filed under, or on a LATER night of a
// multi-night run. Decided once, so the pill and the sentence can never disagree about which case it is
// (#863/#885: two rules for one fact eventually contradict each other on screen).
//
// The defect this exists for: the sentence was true and read false. Dan saw, under a `FRI Jul 24 2026`
// header, a Shifters card (Jul 24 to 31) saying "You're already shooting The One-Man Odyssey on Jul 31."
// while the two Jul 24 to 25 shows beside it said nothing. Jul 31 is a night inside Shifters' run, and the
// only blocked day in July, so the shorter runs never reach it and were correctly quiet. But with nothing
// on the card saying the clash was on a later night, the eye bound the date to the header above it and the
// neighbours looked broken.
enum ConflictScope: Equatable, Sendable {
    // The blocked night IS the date this card groups under: a one-night show, or a run whose opening night
    // is the problem. What Dan has always read, and it was right.
    case thisNight
    // A later night inside a multi-night run. `BlockedCalendar.conflict` walks the whole run, so the night
    // it returns can be days after the one the card is filed under.
    case laterInTheRun

    // Nil when there is nothing to scope, rather than a default case: a caller must not be able to render a
    // conflict pill for a show that has no conflict.
    static func of(blockedDate: String?, performanceDate: String?) -> ConflictScope? {
        guard let blockedDate, let performanceDate else { return nil }
        return blockedDate == performanceDate ? .thisNight : .laterInTheRun
    }

    // #1501: `Unavailable` overstated the run case. Dan is free on the night that card is filed under, and a
    // run bookable on seven of its eight nights is not unavailable; reading the same as a show he cannot make
    // at all is what made the pill untrustworthy.
    var pillLabel: String {
        switch self {
        case .thisNight:     return "Unavailable"
        case .laterInTheRun: return "Partly booked"
        }
    }

    // #1527: the pill's hover text, off the same two cases as its label. #1501 made the label and the
    // sentence under it honest about WHICH night is blocked and left this one saying "that night" for both,
    // so on a run flagged for Jul 31 under a Jul 24 header the hover pointed at the night Dan is free on:
    // the exact misreading #1501 exists to stop, surviving in the one place that issue did not look.
    //
    // The run case borrows the card sentence's own words ("a later night of this run is out"), so the two
    // things Dan reads about one clash describe it the same way.
    // Both sentences are written out whole, including the override clause they share, rather than composed
    // from one interpolated tail. `docs/copy-inventory.md` exists to show a copy change in the words Dan
    // reads, and it lists what the source literally contains: composing these left the inventory holding
    // two fragments and a stray "Tap if you can shoot it after all." instead of the two real sentences.
    // `ConflictPillColourTests.bothHoverTextsOfferTheSameWayOut` is what stops the shared half drifting.
    var pillHelp: String {
        switch self {
        case .thisNight:
            return "Overture won't draft or send this while you're unavailable that night. Tap if you can shoot it after all."
        case .laterInTheRun:
            return "Overture won't draft or send this while a later night of this run is out. Tap if you can shoot it after all."
        }
    }

    // Both cases still hold the show back from a draft and a send. The words got more honest; the gate did
    // not move. It remains `hasUnclearedConflict`, so nothing here can let a pitch through for a run Dan
    // cannot finish, which is the whole reason #901 tests every night of a run rather than its opening one.
    var isBlocking: Bool { true }
}
