import Foundation

// #924: whether dismissing a show should offer to block its date as a day off, and over what range.
//
// Dan telling Overture "not this day" (a date conflict, a day that doesn't work, an already-booked date)
// is the most natural moment there is to capture a day off, instead of making him say it twice: once by
// dismissing the show and again by typing the date into the Days off sheet.
//
// The rule lives here, not in a view, so it is testable and shared by both paths (the #863 lesson). It is
// always an OFFER, never automatic.
//
// #2373 (Dan's call, 2026-08-09): the offer is ALWAYS the single night that was dismissed, and both of the
// pickers it fills open on that date. This supersedes #924's prefill of the whole run and #939's widening
// to every linked date of a touring engagement, both of which proposed days Dan never mentioned while the
// sheet's DEFAULT button blocked them. A screening series showed the cost: dismissing one night of NT Live:
// Inter Alia (Encore) proposed 8/15 through 9/29, 46 days, one press away. Blocking a longer stretch is
// still available by typing it into the two pickers, which is what they are for.
enum DayOffOffer {
    struct Offer: Equatable, Sendable {
        let start: String   // yyyy-MM-dd, the night that was dismissed
        let end: String     // yyyy-MM-dd, the same night: the offer never proposes a night Dan did not name
    }

    // The reasons that mean "I can't shoot on this date", mirroring the three DismissReason cases the
    // engine already carries. Every other reason (not a fit, don't want to shoot, duplicate, went by) is
    // about the show, not the calendar, so it offers nothing.
    //
    // #1821: `pitchingOtherShows` sits beside `dateConflict` everywhere else (both are scheduling misses
    // that keep the org hot) and deliberately NOT here. It is the one place the two mean opposite things:
    // a date conflict says the night is spoken for, while pitching other shows that night says Dan is
    // working it. Blocking it as a day off would stop Overture pitching him for a night he actively wants.
    private static let calendarReasons: Set<ShowOutcome> = [.dateConflict, .hadPaidWork]

    // `alreadyBlocked` is the show's own conflict state: when its date is already a day off or a booked
    // shoot, the show already reads "unavailable", so there is nothing to capture and the picker must not
    // pop. This is what stops a second dismissal on a date Dan just blocked from asking him to block it
    // again (2026-07-15).
    //
    // #2373: the only date this takes is the dismissed row's own. It used to take the run's end and the
    // engagement's linked dates as well (the latter as an #1960 @autoclosure, so the two guards below
    // could decline to pay for the sweep that built it); with the widening gone there is no wider range
    // to compute and no cost left to guard.
    static func offer(reason: ShowOutcome, performanceDate: String?,
                      alreadyBlocked: Bool = false) -> Offer? {
        guard !alreadyBlocked else { return nil }
        guard calendarReasons.contains(reason), let date = performanceDate else { return nil }
        return Offer(start: date, end: date)
    }

    // The picker sheet's subtitle. Here rather than in the view so it is testable and the org it names
    // cannot drift from what the row was actually dismissed for (the #863/#885 lesson).
    static func pickerSubtitle(org: String) -> String {
        "You dismissed \(org) because the dates don't work. Block the days you can't shoot, and Overture will stop pitching you for them."
    }
}
