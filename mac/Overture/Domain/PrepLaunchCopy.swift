import Foundation

// #3366/#3369: one show about to be prepped that sits on a night Dan's calendar has spoken for, with the
// sentence the CARD is already showing him about it.
//
// The note is quoted rather than rebuilt, so the confirm and the card can never describe the same clash
// differently (#843), and rewording `BlockedCalendar.Day.reason` can never leave this saying the old thing.
struct PrepCalendarClash: Equatable {
    let groupName: String
    let note: String
}

// What a Prep launch says before it spends anything.
//
// Dan's call, 2026-09-01 (this session, in chat), on whether a calendar clash should keep holding a show
// out of Prep: "Maybe warn me, but let me do it." So the gate became this sentence. #901's saving is not
// abandoned by that, it is relocated: the spend still needs a deliberate press, and now the press is
// available, which it was not before.
//
// It shares `SelfBookingConfirmSheet` with the self-booking warning (#1219) rather than raising a second
// dialog. Two sheets over one press is how a confirm becomes something to click past, and both are the
// same question anyway: is this night really free.
enum PrepLaunchCopy {
    // The calendar half. Nil when nothing selected carries an open clash, which is the ordinary case.
    static func calendarClashMessage(_ clashes: [PrepCalendarClash]) -> String? {
        guard !clashes.isEmpty else { return nil }
        return clashes.map { clash in
            let show = clash.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This show" : clash.groupName
            return "\(show): \(clash.note)"
        }.joined(separator: "\n")
    }

    // Three titles, because a confirm saying one thing about two different situations tells Dan less than
    // the one he is in (L11). Nil when there is nothing to confirm, so a caller cannot raise the sheet
    // over an empty question.
    static func confirmTitle(selfBooking: Bool, calendar: Bool) -> String? {
        switch (selfBooking, calendar) {
        case (true, false): return "Prep a show on a date you're already pitching?"
        case (false, true): return "Prep a show on a night you're not free?"
        case (true, true): return "Prep a show on a night that's already spoken for?"
        case (false, false): return nil
        }
    }

    // Both halves in one message, self-booking first: that is the one that can double-book him on a night
    // he is otherwise free, so it is the one he most needs to read.
    static func combinedMessage(selfBooking: String?, calendar: String?) -> String? {
        switch (selfBooking, calendar) {
        case (nil, nil): return nil
        case (let s?, nil): return s
        case (nil, let c?): return c
        case (let s?, let c?): return "\(s)\n\n\(c)"
        }
    }

    static let proceedLabel = "Prep anyway"
}
