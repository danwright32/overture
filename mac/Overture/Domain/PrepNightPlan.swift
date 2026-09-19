import Foundation
import SwiftData

// #3325, plan section 3: what the Prep picker shows for each night of each run, built ONCE when the sheet
// opens and never inside it.
//
// #3311: nothing outside a scout could say which shoot blocks a given night, because the calendar is
// built during a scout and never kept. It is rebuilt here, on every open, from the same
// `ScoutService.blockedCalendar` every other surface builds through, and asked through the one per-night
// predicate, `BlockedCalendar.blockedNights`, so the picker, the confirm and the card cannot give three
// answers to one question (L261, L342). A calendar that could not be READ is its own state: no night is
// marked, and the sheet says why once, rather than rendering every night as clear (L98, L11).
//
// Built outside the sheet deliberately. The sheet is a plain `VStack` inside `CappedScrollView`, not a
// lazy container, and holding the calendar or the store in it would put a file read and a fetch on every
// redraw.
struct PrepNightPlan: Equatable {

    // Whether the calendar this plan was checked against could be read at all.
    enum CalendarRead: Equatable, Sendable {
        case read
        case couldNotRead
    }

    // What the calendar says about one night, and what Dan has already said about it.
    enum Clash: Equatable, Sendable {
        case clear
        // The calendar blocks this night and nothing Dan has done answers it.
        case blocked(BlockedCalendar.Day)
        // The card level "I can shoot this anyway" names this very clash (`conflictClearedKey`). Consulted,
        // never bypassed: an acknowledgement has to be read by every rule raising the same question, or it
        // goes on asking after it was answered (L330, #3307).
        case waived(BlockedCalendar.Day)
        // An earlier commit pitched this night despite this exact clash (`NightDecision.acceptedClashKey`).
        // A DIFFERENT clash on the same night does not match and reads as `.blocked` again (#718's pattern).
        case accepted(BlockedCalendar.Day)

        var day: BlockedCalendar.Day? {
            switch self {
            case .clear: return nil
            case .blocked(let d), .waived(let d), .accepted(let d): return d
            }
        }
    }

    struct Night: Equatable, Identifiable, Sendable {
        let date: String
        let clash: Clash
        let defaultTicked: Bool
        var id: String { date }
    }

    enum Nights: Equatable, Sendable {
        // Two or more recorded nights: the picker has something to offer.
        case perNight([Night])
        // A span with no recorded nights. 22 rows, 9 live, measured 2026-09-17, and none has EVER gained
        // nights (#3963), so this is their permanent state and the sheet says so rather than drawing an
        // empty list (L10).
        case notRecorded
        // One night, or no date at all: the row's own checkbox is the only decision there is.
        case single
    }

    struct Run: Equatable, Sendable {
        let key: String
        let groupName: String
        let nights: Nights
        // Answer 7 (Dan, 2026-09-17): the disclosure OPENS when the run has a night the calendar blocks and
        // he has not answered, and stays closed otherwise, so a clean run keeps its single press and a
        // warning is never hidden behind a disclosure nobody opened (L610, L678).
        let opensByDefault: Bool

        var perNight: [Night]? {
            if case .perNight(let n) = nights { return n }
            return nil
        }
    }

    let calendar: CalendarRead
    let runs: [String: Run]

    static let empty = PrepNightPlan(calendar: .read, runs: [:])

    // #3312: `today` is REQUIRED (L168). A night already behind us is never offered: the drafter is told
    // to leave a passed night out (`PrepQueueItem.openingNightPassed`), so offering it here would be a
    // choice the next step overrules, which is worse than not offering it. Chronology wins over a tick,
    // and the kept nights sent to the drafter come from the same `upcoming` filter (`KeptNights`).
    @MainActor
    static func build(prospects: [Prospect], calendar: BlockedCalendar,
                      availability: BlockedCalendar.Availability, today: String) -> PrepNightPlan {
        let read: CalendarRead = availability == .measured ? .read : .couldNotRead
        var runs: [String: Run] = [:]
        for p in prospects {
            runs[p.naturalKey] = run(for: p, calendar: calendar, read: read, today: today)
        }
        return PrepNightPlan(calendar: read, runs: runs)
    }

    @MainActor
    static func run(for p: Prospect, calendar: BlockedCalendar, read: CalendarRead, today: String) -> Run {
        let playing = p.playingNights
        let nights: [String]
        switch playing {
        case .undated: return Run(key: p.naturalKey, groupName: p.groupName, nights: .single, opensByDefault: false)
        case .spanOnly:
            return Run(key: p.naturalKey, groupName: p.groupName, nights: .notRecorded, opensByDefault: false)
        case .recorded(let all):
            let recorded = all.filter { $0 >= today }
            guard recorded.count > 1 else {
                return Run(key: p.naturalKey, groupName: p.groupName, nights: .single, opensByDefault: false)
            }
            nights = recorded
        }
        // A calendar that could not be read marks nothing. It is not evidence any night is clear, which is
        // why the sheet says so in words rather than letting the unmarked rows imply it.
        let blocked: [String: BlockedCalendar.Day] = read == .read
            ? Dictionary(calendar.blockedNights(playing).map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
            : [:]
        let built = nights.map { night -> Night in
            let state = p.nightState(night)
            let clash: Clash
            if let day = blocked[night] {
                if case .pitched(let d) = state, d.acceptedClashKey == day.key {
                    clash = .accepted(day)
                } else if day.key == p.conflictClearedKey {
                    clash = .waived(day)
                } else {
                    clash = .blocked(day)
                }
            } else {
                clash = .clear
            }
            let ticked: Bool
            switch state {
            case .skipped: ticked = false
            // A night pitched before still starts ticked, UNLESS the calendar now blocks it with a clash he
            // never accepted: that is a fact he has not seen, so it starts unticked like any blocked night.
            case .pitched: if case .blocked = clash { ticked = false } else { ticked = true }
            default: if case .blocked = clash { ticked = false } else { ticked = true }
            }
            return Night(date: night, clash: clash, defaultTicked: ticked)
        }
        let opens = built.contains { if case .blocked = $0.clash { return true } else { return false } }
        return Run(key: p.naturalKey, groupName: p.groupName, nights: .perNight(built), opensByDefault: opens)
    }

    // MARK: the commit

    struct Commit: Equatable, Sendable {
        let pitched: [NightDecision]
        let skipped: [NightDecision]
    }

    // What one run's picker writes. Opened writes `chosen` for every night of the run, closed writes
    // `default` (plan 2.3): only a run Dan actually looked at may later be read as nights he judged. A run
    // that opened by itself over a clash counts as looked at, since it was shown to him.
    //
    // A night ticked while the calendar blocks it carries that clash's key, whether he answered it here or
    // on the card, so the record explains itself without the card (#3961).
    func commit(key: String, ticked: Set<String>, opened: Bool, now: Date) -> Commit? {
        guard let nights = runs[key]?.perNight else { return nil }
        let origin: NightDecision.Origin = opened ? .chosen : .byDefault
        var pitched: [NightDecision] = []
        var skipped: [NightDecision] = []
        for night in nights {
            if ticked.contains(night.date) {
                pitched.append(NightDecision(night: night.date, at: now, origin: origin,
                                             acceptedClashKey: night.clash.day?.key))
            } else {
                skipped.append(NightDecision(night: night.date, at: now, origin: origin))
            }
        }
        return Commit(pitched: pitched, skipped: skipped)
    }

    // MARK: the confirm

    // The calendar half of the confirm Dan sees before a run spends anything. ONE predicate for both kinds
    // of row: a per-night run is judged on the nights he left ticked (a night he unticked is no longer being
    // pitched, and a night he already answered is not asked again), and every other row on the card's own
    // stored clash, which is the earliest of the same `blockedNights` set.
    func calendarClashes(forKeys keys: Set<String>, ticks: [String: Set<String>],
                         among items: [QueueItem]) -> [PrepCalendarClash] {
        let perNightKeys = Set(keys.filter { runs[$0]?.perNight != nil })
        var clashes = QueueModel.calendarClashesForPrep(forKeys: keys.subtracting(perNightKeys), among: items)
        for key in keys.sorted() where perNightKeys.contains(key) {
            guard let run = runs[key], let nights = run.perNight else { continue }
            let chosen = ticks[key] ?? []
            for night in nights where chosen.contains(night.date) {
                guard case .blocked(let day) = night.clash else { continue }
                clashes.append(PrepCalendarClash(groupName: run.groupName, note: day.reason(scope: .thisNight)))
            }
        }
        return clashes
    }
}
