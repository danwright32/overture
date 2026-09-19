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

    // #3298: whether the export this calendar was built from could be READ at all.
    //
    // `DownbeatBridge.loadWithHealth` answers a refusal with empty clients, empty bookings AND an empty
    // `blockedDates`, and an empty blocked-date list is indistinguishable from a diary with nothing in it
    // (L98). Without this, a corrupt or missing export makes every night look free and the scout stops
    // suppressing nights Dan is already shooting. It happened on 2026-08-30: 16 blocked dates and 31
    // clients went invisible, and the only thing that reported it was a line inside a sheet.
    //
    // A STALE export is `.measured`, deliberately. Its nights are known and merely old, so folding it in
    // here would replace a real answer with "we do not know", which is false. What a stale export owes Dan
    // is its own sentence (#3299), not this one.
    enum Availability: Equatable, Sendable {
        case measured
        case unknown

        // Derived from the health verdict rather than set by hand, so a caller cannot get the two out of
        // step. Exhaustive over `Health`, so a fifth case has to decide which side it is on.
        init(health: DownbeatBridge.Health) {
            switch health {
            case .ok, .stale: self = .measured
            case .missing, .unreadable: self = .unknown
            }
        }
    }

    enum Kind: String, Equatable, Sendable, Codable {
        case bookedShoot        // Downbeat says he is working
        case dayOff             // Dan says he is away

        // #1421: how hard a clash of this kind is, higher is harder. A booked shoot is work he has taken
        // and cannot move; a day off is his own and he can wave it through. Read by `Day.decidesBefore`,
        // the one ordering `conflict` uses. Exhaustive, so a third kind has to say where it sits.
        var severity: Int {
            switch self {
            case .bookedShoot: return 1
            case .dayOff: return 0
            }
        }
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
        // below returns the most severe blocked night, earliest among equals, #1421), so Overture does not
        // know whether one night
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

        // #1421: which of two blocked nights of one run decides it. The harder kind first, then the earlier
        // date. The name is the last tie break only so the answer never depends on the order the nights
        // arrived in; two days on one date cannot both reach here, since `decidingDay` hands on one.
        static func decidesBefore(_ a: Day, _ b: Day) -> Bool {
            if a.kind.severity != b.kind.severity { return a.kind.severity > b.kind.severity }
            return (a.date, a.name ?? "") < (b.date, b.name ?? "")
        }

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
    // Every entry under a date shares that date and that kind: `build` either puts Dan's days off there
    // (every overlapping range, #2792) or replaces the whole list with booked shoots, so this and a scan of
    // the whole list can never disagree
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
        !upcomingBookedShoots(today: today).isEmpty
    }

    // #2694: the booked shoots from today on, for the Days off sheet's list. A shoot Dan already worked is
    // clutter on a list whose job is the nights he cannot be pitched for, and Downbeat exports every booking
    // with no date floor, so each finished shoot would join it for good. Filtered HERE rather than in `build`,
    // deliberately: a past date blocking nothing costs nothing, and narrowing the calendar would move the
    // conflict keys. One predicate for the list and for `hasUpcomingBookedShoot` above, so the sheet's
    // "nothing booked" sentence and the rows beneath it cannot disagree (L16). Tonight is still ahead.
    func upcomingBookedShoots(today: String) -> [Day] {
        days.filter { $0.kind == .bookedShoot && $0.date >= today }
    }

    // Nothing blocked at all: the state Overture has been in its whole life.
    static let empty = BlockedCalendar()

    // #2692: `cancelledBookingIds` are the shoots Dan has said are not happening. They are FILTERED here
    // rather than deleted anywhere, because this function re-reads `bookings` and `blockedDates` from the
    // export on every call, so a local deletion would come back with the next export. A cancellation is a
    // preference, and a preference is enforced by filtering what is shown (L116).
    //
    // It carries a default, and the default is the SAFE direction rather than a convenience: an empty set
    // means nothing is cancelled, so a caller that forgets it blocks MORE nights than it should. Blocking
    // a night Dan is free on costs him one show he could have pitched; failing to block one he is working
    // costs him a pitch for a night that is taken, which is the failure this whole calendar exists to
    // prevent (L42's direction).
    //
    // #3298: `availability` has NO default. A caller that could omit it would silently claim the export was
    // read, which is exactly the claim this parameter exists to stop anybody making by accident (L168).
    static func build(availability: Availability,
                      bookings: [OvertureBooking],
                      exportedBlockedDates: [String],
                      daysOff: [DayOffRange],
                      cancelledBookingIds: Set<String> = []) -> BlockedCalendar {
        var cal = BlockedCalendar()
        // #3298 stored `availability` on the calendar as a `blockedDaysAreUnknown` flag. Dan's call,
        // 2026-09-02: removed. Nothing read it. The masthead notice reads the export's health directly and
        // is the surface that actually tells him the nights are unknown, so the flag was a second value
        // for the same fact with no reader, which is the shape this repo's own PR rule exists to catch.
        //
        // The PARAMETER stays, and is still required. It is what makes a caller say which it is holding,
        // and `Availability(health:)` is still the one place that decides. If a reader is ever needed, put
        // the flag back here rather than re-deriving the verdict at the call site.
        _ = availability
        // Which dates a cancellation has actually touched, and which of those still hold a shoot. The flat
        // `blockedDates` rule below needs both: a date whose every booking is cancelled must lose its flat
        // entry too, and a date that never had a booking must keep one.
        let live = bookings.filter { !cancelledBookingIds.contains($0.id) }
        let datesWithACancellation = Set(bookings.filter { cancelledBookingIds.contains($0.id) }
            .flatMap { EasternDate.days(from: $0.startDate, through: $0.endDate) })
        let datesStillHoldingAShoot = Set(live
            .flatMap { EasternDate.days(from: $0.startDate, through: $0.endDate) })

        // Dan's own days first, so a booked shoot lands on top of one where they collide.
        //
        // #2792: EVERY range on a date, the same treatment #2791 gave the bookings below, so the file has
        // one rule rather than two. It used to keep one entry per date and discard the other range's note.
        //
        // Sorted for the same reason the bookings are, and the deciding day is the one that decided BEFORE
        // this change: the last range in sort order, which used to overwrite the others. Each range is
        // therefore put in FRONT of what the date already holds, so index 0 is still that range and every
        // stored key and every "I can shoot this anyway" across an overlap is exactly what it was. Keeping
        // the list in the other order would have re-blocked those runs for no change in his calendar.
        for range in daysOff.sorted(by: { ($0.startDate, $0.endDate, $0.note ?? "")
                                          < ($1.startDate, $1.endDate, $1.note ?? "") }) {
            for date in EasternDate.days(from: range.startDate, through: range.endDate) {
                let day = Day(date: date, kind: .dayOff, name: range.note)
                // Two ranges alike in note on one date are ONE fact, as two alike bookings are: the same key
                // and the same row. The later one still moves to the front, as it would have overwritten.
                cal.byDate[date, default: []].removeAll { $0 == day }
                cal.byDate[date, default: []].insert(day, at: 0)
            }
        }

        // Named bookings, in an order settled here rather than by the export: by shoot name, then by the
        // booking's own id so two shoots sharing a name still land the same way round every time.
        var booked: [String: [Day]] = [:]
        for b in live.sorted(by: { ($0.shootName, $0.id) < ($1.shootName, $1.id) }) {
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
        //
        // #2692: and NOT where every booking on that date has been cancelled. 2027-04-20 arrives twice on
        // Dan's export, once as a named booking and once as a flat entry, so cancelling only the named
        // half would leave the day blocked by the other while the sheet reported success (L38: a removal
        // has to reach every derived thing). The condition is deliberately "this date had a booking and
        // none of them survives", not the bare "no booking remains": a date carrying a flat entry and no
        // booking at all satisfies the bare form vacuously, and suppressing that one would unblock a night
        // Downbeat blocked with nothing to name it by, which is the opposite of what it asked for.
        for date in exportedBlockedDates
        where booked[date] == nil
            && !(datesWithACancellation.contains(date) && !datesStillHoldingAShoot.contains(date)) {
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
    // An empty `nights` falls back to the old span walk, deliberately. For those rows the span is genuinely
    // all we know: clearing their conflicts on no evidence would be the one direction of this change that
    // could lose a real clash.
    //
    // #3963, measured 2026-09-17: this used to end "They pick up their nights on the next scout." That is
    // FALSE and was never measured. Across 29 dated snapshots back to 2026-06-28, ZERO of the 22 rows in
    // this state has ever gained nights, and the cohort has sat at exactly 22 (9 of them live) for twelve
    // consecutive daily snapshots. The one row that ever held nights lost them to drops. The mechanism is
    // not wholly dead (the cohort was 36 on 2026-07-28 and a few gained nights as the scout first
    // re-touched pre-#1523 rows) but it has not reached one of today's 22 in seven weeks.
    //
    // And this is NOT only a pre-#1523 legacy population, which is the other thing the old sentence
    // implied. 2 of the 22 carry `droppedRunNights`, so they arrived here through today's machinery:
    // `ScoutService.swift:1821` sets `runNights = DroppedNight.keeping(...)`, and when the drops subtract
    // every night the list empties while the `runEndDate` correction on the next line only runs
    // `if !existing.runNights.isEmpty`. So the row keeps a span it has no nights for, and an empty night
    // list means two different things to every reader that branches on it.
    //
    // #1421: the night that decides is the most SEVERE blocked night of the run, and the earliest only among
    // equals. It used to be the earliest alone. A run stores ONE conflict key and Dan's "I can shoot this
    // anyway" is recorded against it, so a day off he had waved through on an early night kept the key
    // unchanged when a booked shoot landed on a later night, and the run stayed clear over a night he is
    // working: #901's trap, reopened across kinds.
    //
    // #3286: the empty-list fallback is decided by `PlayingNights`, and this function only picks from
    // `blockedNights`, so the card's one stored key and the per-night set can never disagree about which
    // nights are out (L342, L261).
    func conflict(_ playing: PlayingNights) -> Day? {
        blockedNights(playing).min(by: Day.decidesBefore)
    }

    // The same question in its unpacked form, for a caller holding the three fields rather than a row
    // (the scout's assembled prospect, and the tests). A forwarder, never a second rule.
    func conflict(performanceDate: String?, runEndDate: String?, nights: [String] = []) -> Day? {
        conflict(PlayingNights.of(runNights: nights, performanceDate: performanceDate, runEndDate: runEndDate))
    }

    // #3961 / plan 2.5: EVERY blocked night of this run, one deciding day per night, in date order.
    //
    // `conflict` returns one `Day?` and the card stores one key, so the card level vocabulary cannot say
    // "the 12th is out and so is the 14th". Measured 2026-09-17 through the shipped predicates, 16 of 89
    // live multi-night runs carry TWO OR MORE blocked nights, one of them all twelve of twelve. A picker
    // that asks per night needs the set, and it needs it from HERE: `decidingDay` is private, so without
    // this member the picker and the confirm dialog would each write their own loop and could disagree.
    //
    // A span-only row walks its span, for the reason `conflict` always has: for those rows the span is
    // all that is known, and clearing a clash on no evidence is the direction that loses safety.
    func blockedNights(_ playing: PlayingNights) -> [Day] {
        let candidates: [String]
        switch playing {
        case .recorded(let nights): candidates = nights
        case .spanOnly(let opening, let lastNight): candidates = EasternDate.days(from: opening, through: lastNight)
        case .undated: return []   // "date to be confirmed" collides with nothing
        }
        return candidates.compactMap(decidingDay).sorted { $0.date < $1.date }
    }

    // Everything blocked, for the Days off sheet: EVERY booked shoot, not one per date (#2693). Sorted by
    // date, then by name so two shoots on one night keep their order, and so the list cannot reshuffle
    // between redraws the way a dictionary's would.
    var days: [Day] {
        byDate.values.flatMap { $0 }.sorted { ($0.date, $0.name ?? "") < ($1.date, $1.name ?? "") }
    }
}
