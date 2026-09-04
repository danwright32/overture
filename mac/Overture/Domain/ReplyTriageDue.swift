import Foundation

// #3422: when a reply triage task is due, measured from when the reply actually ARRIVED.
//
// It used to be a fixed 6:00 PM Eastern on the Eastern calendar day of the arrival, so the time of
// day was thrown away and every reply arriving after 6:00 PM produced a task that was already
// overdue the moment it existed. Measured 2026-08-31 in Dan's OmniFocus: created 10:12 PM, due
// 6:00 PM, seven hours red, on work nobody could have done. Not an edge case: it is every evening
// reply, and evening is exactly when he is away from his desk reading OmniFocus rather than the app.
//
// Dan's rule, 2026-08-31, made in the working session rather than on an issue, with the two
// boundaries decided rather than measured and cheap to reverse: 7:00 AM exactly takes the four hour
// band, 11:00 PM exactly takes the twelve hour band.
//
// This is REPLY TRIAGE only. The post-event prompt is anchored to `PostEventPrompt.nextPromptDate`,
// which is Eastern midnight the day after the show: there is no arrival to measure from, and running
// midnight through this would read it as the before-seven band and move every closing note from
// 6:00 PM to 9:00 AM, which nobody asked for. That kind keeps its fixed hour (#3422).
enum ReplyTriageDue {
    // Hours added, by the Eastern hour the reply landed in.
    static let daytimeBandHours = 4      // 7:00 AM through 10:59 PM
    static let earlyMorningBandHours = 9 // before 7:00 AM
    static let lateNightBandHours = 12   // 11:00 PM onward

    static let dayStartsAtHour = 7       // below this is early morning
    static let lateNightStartsAtHour = 23
    // Anything landing between midnight and `dayStartsAtHour` is moved here. Dan's other two bands
    // both exist to push an arrival into the working day; the evening did not get that treatment
    // until this closed the gap, and it mirrors what the before-seven band already does by arithmetic.
    static let morningFloorHour = 9

    static func due(replyArrivedAt arrival: Date) -> Date {
        let cal = EasternDate.calendar
        let hour = cal.component(.hour, from: arrival)
        let band: Int
        if hour < dayStartsAtHour {
            band = earlyMorningBandHours
        } else if hour >= lateNightStartsAtHour {
            band = lateNightBandHours
        } else {
            band = daytimeBandHours
        }
        // Calendar arithmetic rather than a count of seconds, so a band that crosses a daylight saving
        // change still means four hours on the clock Dan reads (L39).
        let raw = cal.date(byAdding: .hour, value: band, to: arrival) ?? arrival
        let rounded = roundedToTheNearestHour(raw, calendar: cal)
        let roundedHour = cal.component(.hour, from: rounded)
        guard roundedHour < dayStartsAtHour else { return rounded }
        return cal.date(bySettingHour: morningFloorHour, minute: 0, second: 0, of: rounded) ?? rounded
    }

    // The task's defer date: when it stops being hidden in OmniFocus.
    //
    // #3422's second blocker. The old defer was a fixed 11:00 AM on the anchor day, and under the new
    // rule a reply arriving just after midnight is due between 9:00 and 11:00 AM, so it would have
    // stayed hidden until after its own deadline and surfaced overdue. That is the very complaint,
    // surviving in a narrower window and looking identical to Dan.
    //
    // So it is the ordinary hour, or the deadline, whichever comes first. The ordinary hour is kept
    // rather than surfacing every task at its arrival, because the defer is what stops OmniFocus
    // filling with work that does not matter yet.
    static func surfacesAt(due: Date) -> Date {
        let cal = EasternDate.calendar
        let ordinary = cal.date(bySettingHour: OmniFocusSync.deferHour, minute: 0, second: 0, of: due) ?? due
        return min(ordinary, due)
    }

    // Nearest hour, with an exact half hour going UP.
    private static func roundedToTheNearestHour(_ date: Date, calendar cal: Calendar) -> Date {
        guard let truncated = truncatedToTheHour(date, calendar: cal) else { return date }
        guard cal.component(.minute, from: date) >= 30 else { return truncated }
        return cal.date(byAdding: .hour, value: 1, to: truncated) ?? truncated
    }

    // Rebuilt from components rather than `date(bySetting:)`, which searches FORWARD for the next
    // instant matching the value and so lands on the following hour instead of truncating.
    private static func truncatedToTheHour(_ date: Date, calendar cal: Calendar) -> Date? {
        var parts = cal.dateComponents([.year, .month, .day, .hour], from: date)
        parts.minute = 0
        parts.second = 0
        parts.nanosecond = 0
        return cal.date(from: parts)
    }
}
