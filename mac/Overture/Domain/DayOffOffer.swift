import Foundation

// #924: whether dismissing a show should offer to block its date as a day off, and over what range.
//
// Dan telling Overture "not this day" (a date conflict, a day that doesn't work, an already-booked date)
// is the most natural moment there is to capture a day off, instead of making him say it twice: once by
// dismissing the show and again by typing the date into the Days off sheet.
//
// The rule lives here, not in a view, so it is testable and shared by both paths (the #863 lesson): a
// single-night show blocks that one day in a tap; a multi-night run opens a date picker pre-filled with
// the whole run so Dan narrows it himself (his call, 2026-07-14). It is always an OFFER, never automatic.
enum DayOffOffer {
    struct Offer: Equatable, Sendable {
        let start: String   // yyyy-MM-dd, the show's opening night
        let end: String     // yyyy-MM-dd, its closing night (== start for a single-night show)
        var isMultiNight: Bool { end != start }
    }

    // The reasons that mean "I can't shoot on this date", mirroring the three DismissReason cases the
    // engine already carries. Every other reason (not a fit, don't want to shoot, duplicate, went by) is
    // about the show, not the calendar, so it offers nothing.
    private static let calendarReasons: Set<DismissReason> = [.dateConflict, .alreadyBooked]

    // `alreadyBlocked` is the show's own conflict state: when its date is already a day off or a booked
    // shoot, the show already reads "unavailable", so there is nothing to capture and the picker must not
    // pop. This is what stops a second dismissal on a date Dan just blocked from asking him to block it
    // again (2026-07-15).
    static func offer(reason: DismissReason, performanceDate: String?, runEndDate: String?,
                      alreadyBlocked: Bool = false) -> Offer? {
        guard !alreadyBlocked else { return nil }
        guard calendarReasons.contains(reason), let start = performanceDate else { return nil }
        // The closing night, judged the same way the conflict calculator and the feed reconcile judge it,
        // so one definition of "the last night of this run" serves all three.
        let end = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: start) ?? start
        return Offer(start: start, end: end)
    }

    // The picker sheet's subtitle. Here rather than in the view so it is testable and the org it names
    // cannot drift from what the row was actually dismissed for (the #863/#885 lesson).
    static func pickerSubtitle(org: String) -> String {
        "You dismissed \(org) because the dates don't work. Block the days you can't shoot, and Overture will stop pitching you for them."
    }
}
