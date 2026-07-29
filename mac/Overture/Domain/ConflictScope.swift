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

}
