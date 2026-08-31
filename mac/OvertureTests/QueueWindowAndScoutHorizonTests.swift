import Testing
import Foundation

// #1571: the queue window and the scout horizon are two numbers, in two units, in two files, and
// nothing related them.
//
// `QueueModel.leadTimeWindowDays` (90) is DEMAND: how far ahead Dan wants to look at shows.
// `CalendarMonthIndex.defaultHorizon` (4) is SUPPLY: how many whole calendar months a watched source
// is read to. `ClientHorizon.clientMonths` (12) is the wider supply for a known client's own calendar.
//
// Dan's call, 2026-08-09: the 90 day window stays. The scout deliberately reads further so a show is
// already found by the time it rolls into the window. This suite is what stops the two drifting apart
// silently, by measuring the supply in the unit the demand is written in.
//
// The month arithmetic here comes from Foundation's own calendar rather than from
// `CalendarMonthIndex`, deliberately: a guard whose two sides come from one implementation can only
// prove that implementation is self-consistent, never that it is right (L70).
@Suite("The queue window against the scout horizon (#1571)")
struct QueueWindowAndScoutHorizonTests {

    // Whole calendar months, the current one plus the next `horizon - 1`, is what a source is read to.
    // This answers how many days ahead of `from` the last of those months ends, which is the supply
    // expressed in the same unit as the queue window.
    private func daysOfCalendarRead(from day: DateComponents, horizon: Int) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        guard let start = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let firstOfLastMonth = cal.date(byAdding: .month, value: horizon - 1,
                                              to: cal.date(from: DateComponents(year: day.year,
                                                                                month: day.month,
                                                                                day: 1))!),
              let range = cal.range(of: .day, in: .month, for: firstOfLastMonth),
              let lastDay = cal.date(bySetting: .day, value: range.count, of: firstOfLastMonth)
        else { return -1 }
        return cal.dateComponents([.day], from: start, to: cal.startOfDay(for: lastDay)).day ?? -1
    }

    // Every start date across a span long enough to hold leap years and every month length.
    private func everyStartDay() -> [DateComponents] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        var days: [DateComponents] = []
        for year in 2026...2033 {
            for month in 1...12 {
                let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
                for day in cal.range(of: .day, in: .month, for: first)! {
                    days.append(DateComponents(year: year, month: month, day: day))
                }
            }
        }
        return days
    }

    @Test("The scout reads at least 89 days ahead, and that floor falls on the last day of January")
    func theScoutsWorstCaseReachIsKnown() {
        let horizon = CalendarMonthIndex.defaultHorizon
        var worst = Int.max
        var worstDays: [String] = []
        for day in everyStartDay() {
            let reach = daysOfCalendarRead(from: day, horizon: horizon)
            #expect(reach > 0, "every start date must reach a real number of days")
            if reach < worst {
                worst = reach
                worstDays = []
            }
            if reach == worst {
                worstDays.append(String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!))
            }
        }
        // 89 is February plus March plus April, measured from 31 January of a year that is not a leap
        // year. It is the shortest run of whole months the horizon can land on.
        #expect(worst == 89, "the horizon's floor moved; the relationship recorded at \(#file) is stale")
        #expect(worstDays.allSatisfy { $0.hasSuffix("-01-31") },
                "the floor is expected on the last day of January, not \(worstDays)")
    }

    @Test("The queue asks for one day more than the scout's worst case, and no more than that")
    func theQueueWindowSitsAgainstTheScoutsFloor() {
        let reaches = everyStartDay()
            .map { daysOfCalendarRead(from: $0, horizon: CalendarMonthIndex.defaultHorizon) }
        let floor = reaches.min()!
        let ceiling = reaches.max()!
        let window = QueueModel.leadTimeWindowDays

        // The window is deliberately narrower than the horizon's typical reach, so the store holds
        // shows that have not rolled into view yet. That buffer is the point of the two numbers
        // differing at all.
        //
        // On exactly one date a year the floor sits one day BELOW the window: asked on 31 January of a
        // non leap year, the queue's ninetieth day is 1 May, and only April has been read. A show that
        // far out is picked up the next night, when the window becomes February to May, so the cost is
        // one day of lateness on one date. It is recorded here rather than left to be rediscovered.
        #expect(window - floor == 1,
                "the queue window (\(window)) and the scout's floor (\(floor)) moved apart; decide the new relationship and say so here")
        #expect(window < ceiling,
                "the queue window (\(window)) must stay inside the horizon's furthest reach (\(ceiling)), or the queue promises a window the scout never fills")
    }

    @Test("A known client's calendar covers the whole queue window on every date")
    func aClientsCalendarAlwaysCoversTheWindow() {
        let floor = everyStartDay()
            .map { daysOfCalendarRead(from: $0, horizon: ClientHorizon.clientMonths) }
            .min()!
        #expect(floor >= QueueModel.leadTimeWindowDays,
                "a client's calendar is read \(ClientHorizon.clientMonths) months and must never reach less far than the queue window")
    }

    // #2521: the THIRD supply side, and the one that had no buffer at all.
    //
    // `AlgoliaCalendar.windowDays` is the FETCH window for Carnegie Hall's feed, the store's only
    // `algolia` source, and it was 90: exactly the queue's own display window. So a Carnegie show became
    // fetchable and became pitchable on the same day, and whether it was in the store by the time it
    // entered Dan's triage window depended on a scout run landing in the right order rather than on any
    // margin. Nothing absorbed a night the scout did not run, a read Dan deferred, or a feed that was
    // briefly unreadable.
    //
    // Every other source has that margin, because a whole calendar month is a coarser unit than a day:
    // four months reaches 89 to 122 days against a 90 day window. Carnegie's fetch is counted in days,
    // so the margin has to be chosen rather than inherited, and this is the check that it was.
    //
    // Why this source in particular: Carnegie is 122 of 322 shoots in Dan's history, 38% of everything
    // he has photographed, so it is where a show arriving late costs the most.
    @Test("Carnegie's feed is fetched further ahead than the queue shows")
    func theAlgoliaFetchWindowClearsTheQueueWindow() {
        let fetch = AlgoliaCalendar.windowDays
        let window = QueueModel.leadTimeWindowDays

        #expect(fetch > window,
                "the Carnegie fetch window (\(fetch)) must exceed the queue window (\(window)), or a show becomes fetchable and pitchable on the same day")

        // Thirty days, which is the same family as the month-index sources' typical 32 day margin and
        // is stated as a floor rather than an exact number so the fetch may be widened without editing
        // this test. Narrowing it below a month is the thing that has to be a deliberate act.
        #expect(fetch - window >= 30,
                "the buffer is \(fetch - window) days; a month is the margin this pair was set with, and shrinking it means deciding a new one and saying so here")
    }

    @Test("The sweep really examined every day, so an empty run cannot pass")
    func theSweepIsNotVacuous() {
        let days = everyStartDay()
        #expect(days.count == 2922, "eight years of dates, including two leap days")
    }
}
