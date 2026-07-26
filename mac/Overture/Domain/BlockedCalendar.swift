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
        var reason: String { reason(scope: .thisNight) }

        // #1501: the same fact, framed for WHICH night of the run is the problem.
        //
        // `.thisNight` is the sentence Dan has always read, unchanged. `.laterInTheRun` leads with the fact
        // the card was missing, because that is what stops the eye binding the date to the group header
        // above it: under a `FRI Jul 24` header, "You're already shooting X on Jul 31" reads as a statement
        // about Jul 24 and makes the quiet cards beside it look broken.
        //
        // It says "a later night", never "one night". The stored conflict key holds ONE day (`conflict`
        // below returns the earliest blocked night via `.min`), so Overture does not know whether one night
        // of the run is out or three, and claiming a count would be false about Dan's calendar the first
        // time two were. That is the same class of error as copying the line onto every card in the date
        // group, which is what #1501 was asked for and declined.
        func reason(scope: ConflictScope) -> String {
            let day = EasternDate.dayLabel(date) ?? date
            switch scope {
            case .thisNight:     return tonight(day)
            case .laterInTheRun: return laterInTheRun(day)
            }
        }

        // Each case's sentence written out IN FULL, in both frames, rather than one clause slotted into two
        // templates. That is the standing rule in this codebase (SourceReadability states it, and #1032 is
        // its reason), and it is not merely style here: `docs/copy-inventory.md` is generated from these
        // literals and is supposed to be every sentence Overture can say. Assembling from a fragment made
        // the four sentences Dan reads most often stop appearing in it at all.
        private func tonight(_ day: String) -> String {
            switch kind {
            case .bookedShoot:
                guard let name, !name.isEmpty else { return "You're already shooting on \(day)." }
                return "You're already shooting \(name) on \(day)."
            case .dayOff:
                guard let name, !name.isEmpty else { return "You blocked \(day)." }
                return "You blocked \(day) (\(name))."
            }
        }

        private func laterInTheRun(_ day: String) -> String {
            switch kind {
            case .bookedShoot:
                guard let name, !name.isEmpty else {
                    return "A later night of this run is out: you're already shooting on \(day)."
                }
                return "A later night of this run is out: you're already shooting \(name) on \(day)."
            case .dayOff:
                guard let name, !name.isEmpty else {
                    return "A later night of this run is out: you blocked \(day)."
                }
                return "A later night of this run is out: you blocked \(day) (\(name))."
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

    // Whether Downbeat has told us about any shoot from today ONWARD (#925).
    //
    // Deliberately not "have we ever seen a booking". Downbeat exports every committed booking it holds,
    // with no date filter (its OvertureExportService.swift:45), so a shoot booked last March keeps that
    // answer true forever, including in September when it is long past and Overture is once again
    // protecting nothing. A past shoot is evidence the pipe once worked. It is not evidence that Dan's
    // schedule is known TODAY, which is the only thing this question is for.
    //
    // His own days off are deliberately not counted: a vacation says nothing about the work he has taken
    // on, and letting one silence this would hide the gap the moment he blocked his first week.
    func hasUpcomingBookedShoot(today: String) -> Bool {
        byDate.values.contains { $0.kind == .bookedShoot && $0.date >= today }
    }

    // Nothing blocked at all: the state Overture has been in its whole life.
    static let empty = BlockedCalendar()

    static func build(bookings: [OvertureBooking],
                      exportedBlockedDates: [String],
                      daysOff: [DayOffRange]) -> BlockedCalendar {
        var cal = BlockedCalendar()

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
    // #1523: judged on the nights the run ACTUALLY plays, when it knows them.
    //
    // Walking every day of the span is right for a run that plays every night and wrong for everything
    // else. `The Lineup with Susie Mosher` plays sixteen Tuesdays across 106 days, so a shoot on any
    // Wednesday in October used to flag a show that is dark on Wednesdays. Measured 2026-07-26, three shows
    // carried an open conflict against one booked Friday, and at least two of them do not play Fridays.
    //
    // Dan's call, and it is why this fixes the CHECK and not the grouping: "I think I'd want it to be one
    // long run. I'm not going to send them an email every week pitching the show. I'm going to pitch it
    // once." Splitting a weekly series into its nights would have given him sixteen cards for one pitch,
    // which is the clutter measured in #1558.
    //
    // An empty `nights` falls back to the old span walk, deliberately. Every prospect already in the store
    // predates this and records none, and for those the span is genuinely all we know: clearing their
    // conflicts on no evidence would be the one direction of this change that could lose a real clash. They
    // pick up their nights on the next scout.
    func conflict(performanceDate: String?, runEndDate: String?, nights: [String] = []) -> Day? {
        guard let performanceDate else { return nil }   // "date to be confirmed" collides with nothing
        guard nights.isEmpty else {
            return nights.compactMap { byDate[$0] }.min { $0.date < $1.date }
        }
        let lastNight = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate)
        return EasternDate.days(from: performanceDate, through: lastNight ?? performanceDate)
            .compactMap { byDate[$0] }
            .min { $0.date < $1.date }
    }

    // Everything blocked, for the Days off sheet. Sorted by date so the list cannot reshuffle between
    // redraws the way a dictionary's order would.
    var days: [Day] { byDate.values.sorted { $0.date < $1.date } }
}
