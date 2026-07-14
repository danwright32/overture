import Foundation

// #901: the days Dan cannot shoot, and WHY.
//
// This replaces a bare `Set<String>` of dates. That set could only answer yes or no, so the only thing
// the scout could do with it was drop the show, silently. Dan's decision (2026-07-13) is the opposite: a
// clash is surfaced, named, and handed to him. That needs a reason attached to the day, which is what
// this type is.
//
// Two sources feed it, and they are kept apart on purpose:
//
//   bookedShoot  Downbeat's. A booking he took. He cannot move it, and Overture can name it.
//   dayOff       Dan's own. A vacation, typed into Overture, that nothing else in his world knows about.
//
// The UI has to say which it is (he can edit one and not the other), so one flat set of dates with the
// reasons thrown away would have to guess, and would guess wrong the first time it mattered.

// A range of days off, as Dan enters it: "the 14th through the 22nd", not nine separate clicks. The pure
// mirror of the `DayOff` SwiftData row, so every rule here is testable without a store.
struct DayOffRange: Equatable, Sendable {
    var startDate: String       // yyyy-MM-dd, inclusive
    var endDate: String         // yyyy-MM-dd, inclusive
    var note: String?
}

struct BlockedCalendar: Equatable, Sendable {

    enum Kind: String, Equatable, Sendable, Codable {
        case bookedShoot        // Downbeat says he is working
        case dayOff             // Dan says he is away
    }

    struct Day: Equatable, Sendable {
        var date: String        // yyyy-MM-dd
        var kind: Kind
        var name: String?       // the shoot's name, or Dan's note. Absent when there is nothing to name.

        // What Dan reads on the flagged show. Composed here rather than stored on the prospect, so a
        // wording change never leaves old prospects quoting the old sentence back at him.
        var reason: String {
            let day = EasternDate.dayLabel(date) ?? date
            switch kind {
            case .bookedShoot:
                guard let name, !name.isEmpty else { return "You're already shooting on \(day)." }
                return "You're already shooting \(name) on \(day)."
            case .dayOff:
                guard let name, !name.isEmpty else { return "You blocked \(day)." }
                return "You blocked \(day) (\(name))."
            }
        }

        // MARK: Identity
        //
        // The prospect stores this key, not the sentence above, and Dan's "I can shoot this anyway"
        // stores the exact key he accepted (the #718 pattern). So a conflict that CHANGES under him (the
        // vacation moved, a shoot was booked over the day he already waved through) no longer matches
        // what he cleared, and blocks again, which is the whole point. Comparing sentences would also
        // re-block every cleared show the day somebody rewords the copy.
        //
        // The name goes LAST and is never escaped: it is free text Dan typed in another app, so it can
        // contain the separator, and splitting at most twice keeps it whole.
        private static let separator: Character = "|"

        var key: String { "\(kind.rawValue)\(Day.separator)\(date)\(Day.separator)\(name ?? "")" }

        init(date: String, kind: Kind, name: String?) {
            self.date = date
            self.kind = kind
            self.name = name
        }

        init?(key: String) {
            let parts = key.split(separator: Day.separator, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])) else { return nil }
            self.init(date: String(parts[1]), kind: kind,
                      name: parts[2].isEmpty ? nil : String(parts[2]))
        }
    }

    // date -> the reason it is blocked. One entry per day: a day cannot be blocked twice, and a booked
    // shoot outranks a day off on the same date (naming the real shoot tells Dan more than "you're away",
    // and it is the one he cannot move).
    private var byDate: [String: Day] = [:]

    // Whether Downbeat has told us about ANY committed work. False means the booked-shoot half of the
    // guard is protecting nothing, which is exactly the state that produced #901 and went unsaid for the
    // app's whole life.
    private(set) var hasBookedShootData = false

    // Nothing blocked, and no booked-shoot data either: the state Overture has been in its whole life.
    static let empty = BlockedCalendar()

    static func build(bookings: [OvertureBooking],
                      exportedBlockedDates: [String],
                      daysOff: [DayOffRange]) -> BlockedCalendar {
        var cal = BlockedCalendar()
        cal.hasBookedShootData = !bookings.isEmpty || !exportedBlockedDates.isEmpty

        // Dan's own days first, so a booked shoot lands on top of one where they collide.
        for range in daysOff {
            for date in EasternDate.days(from: range.startDate, through: range.endDate) {
                cal.byDate[date] = Day(date: date, kind: .dayOff, name: range.note)
            }
        }
        // A flat exported date with no booking behind it can only have come from one, so it blocks. It
        // just has nothing to name it with, and does not pretend otherwise.
        for date in exportedBlockedDates {
            cal.byDate[date] = Day(date: date, kind: .bookedShoot, name: nil)
        }
        // Named bookings last: they overwrite the unnamed exported day for the same date.
        for b in bookings {
            for date in EasternDate.days(from: b.startDate, through: b.endDate) {
                cal.byDate[date] = Day(date: date, kind: .bookedShoot, name: b.shootName)
            }
        }
        return cal
    }

    // The first night of this run Dan cannot make, or nil if he can make all of them.
    //
    // #901's trap: this tests the WHOLE run, not its opening night. The old check compared
    // performanceDate alone, so a four-night run whose third night sat on a booked shoot went through
    // clean, and Dan would have pitched a show he could not finish.
    func conflict(performanceDate: String?, runEndDate: String?) -> Day? {
        guard let performanceDate else { return nil }   // "date to be confirmed" collides with nothing
        let lastNight = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate)
        return EasternDate.days(from: performanceDate, through: lastNight ?? performanceDate)
            .compactMap { byDate[$0] }
            .min { $0.date < $1.date }
    }

    // Everything blocked, for the Days off sheet. Sorted by date so the list cannot reshuffle between
    // redraws the way a dictionary's order would.
    var days: [Day] { byDate.values.sorted { $0.date < $1.date } }
}
