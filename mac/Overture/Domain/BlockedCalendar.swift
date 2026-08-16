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

    // date -> every reason it is blocked. A booked shoot outranks a day off on the same date (naming the
    // real shoot tells Dan more than "you're away", and it is the one he cannot move).
    //
    // #2693: a LIST, not one Day. This used to hold one entry per date, under a comment reading "a day
    // cannot be blocked twice", which is true of the blocking DECISION and false of the facts behind it.
    // Dan's export really does carry two bookings on one night: measured on 2026-08-15, two of his fifteen
    // bookings (2027-02-14 and 2027-05-30) shared a date with another, so the second overwrote the first
    // and the days off sheet, whose whole job is telling him what he already has on, showed him 13.
    //
    // The order inside a date is decided HERE, and index 0 is the day that DECIDES: the one whose key a
    // prospect stores and whose sentence Dan reads. It must not move when Downbeat lists the same two
    // bookings the other way round, because that key is his "I can shoot this anyway", and a key that
    // moved would re-block a night he had already waved through for no change in his calendar at all.
    private var byDate: [String: [Day]] = [:]

    // The one day that answers "is this date blocked, and why". Everything else on the date is a fact for
    // the sheet to list, never a second answer to that question.
    //
    // Every entry under a date shares that date and that kind: `build` either puts one day off there or
    // replaces the whole list with booked shoots, so this and a scan of the whole list can never disagree
    // about whether the date is blocked or by which kind. The list is only ever richer in NAMES.
    private func decidingDay(_ date: String) -> Day? { byDate[date]?.first }

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
        byDate.values.contains { days in
            days.contains { $0.kind == .bookedShoot && $0.date >= today }
        }
    }

    // Nothing blocked at all: the state Overture has been in its whole life.
    static let empty = BlockedCalendar()

    static func build(bookings: [OvertureBooking],
                      exportedBlockedDates: [String],
                      daysOff: [DayOffRange]) -> BlockedCalendar {
        var cal = BlockedCalendar()

        // Dan's own days first, so a booked shoot lands on top of one where they collide. One entry per
        // date: two of his own ranges overlapping is one decision of his, and both ranges are listed in
        // full on the sheet from the stored rows, so nothing here is the only record of either.
        //
        // Sorted for the same reason the bookings below are: where two of his ranges cover one date, the
        // last one written decides which note the stored key quotes, and a key that moved with the order
        // the rows came back in would re-block a night he had already waved through.
        for range in daysOff.sorted(by: { ($0.startDate, $0.endDate, $0.note ?? "")
                                          < ($1.startDate, $1.endDate, $1.note ?? "") }) {
            for date in EasternDate.days(from: range.startDate, through: range.endDate) {
                cal.byDate[date] = [Day(date: date, kind: .dayOff, name: range.note)]
            }
        }

        // Named bookings, in an order settled here rather than by the export: by shoot name, then by the
        // booking's own id so two shoots sharing a name still land the same way round every time.
        var booked: [String: [Day]] = [:]
        for b in bookings.sorted(by: { ($0.shootName, $0.id) < ($1.shootName, $1.id) }) {
            for date in EasternDate.days(from: b.startDate, through: b.endDate) {
                let day = Day(date: date, kind: .bookedShoot, name: b.shootName)
                // Two bookings alike in name and date are ONE fact to everything downstream: the same
                // key, the same sentence, the same row. Keeping both would hand the sheet two rows
                // sharing an id, which is the one thing its list cannot render.
                guard !(booked[date]?.contains(day) ?? false) else { continue }
                booked[date, default: []].append(day)
            }
        }
        // A flat exported date with no booking behind it can only have come from one, so it blocks. It
        // just has nothing to name it with, and does not pretend otherwise. Only where no booking already
        // names the date: on the live export every blocked date is also a booking's date (measured
        // 2026-08-15, all 12 of them), so listing it beside them would show every shoot twice.
        for date in exportedBlockedDates where booked[date] == nil {
            booked[date] = [Day(date: date, kind: .bookedShoot, name: nil)]
        }
        // Bookings last: a date Downbeat has him working replaces the day off he had blocked there.
        for (date, days) in booked {
            cal.byDate[date] = days
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
            return nights.compactMap(decidingDay).min { $0.date < $1.date }
        }
        let lastNight = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate)
        return EasternDate.days(from: performanceDate, through: lastNight ?? performanceDate)
            .compactMap(decidingDay)
            .min { $0.date < $1.date }
    }

    // Everything blocked, for the Days off sheet: EVERY booked shoot, not one per date (#2693). Sorted by
    // date, then by name so two shoots on one night keep their order, and so the list cannot reshuffle
    // between redraws the way a dictionary's would.
    var days: [Day] {
        byDate.values.flatMap { $0 }.sorted { ($0.date, $0.name ?? "") < ($1.date, $1.name ?? "") }
    }
}
