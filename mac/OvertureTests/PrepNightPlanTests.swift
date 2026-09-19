import Testing
import Foundation
import SwiftData

// #3325 (plan section 3) and #3311: what the Prep picker offers for each night, and what it commits.
//
// Every date and stamp is pinned (L130).
@MainActor
@Suite("The Prep picker's nights (#3325, #3311)")
struct PrepNightPlanTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let nights = ["2026-11-06", "2026-11-13", "2026-11-20", "2026-11-27"]

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func run(_ ctx: ModelContext, name: String = "Picker Revue",
                     nights: [String] = PrepNightPlanTests.nights) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: name, performanceDate: nights.first,
                                                             venue: "Room One"),
                         groupName: name, discipline: "theater", venue: "Room One",
                         performanceDate: nights.first, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = nights.last
        p.runNights = nights
        ctx.insert(p)
        return p
    }

    // A booked shoot on the 13th and a day off on the 27th.
    private var calendar: BlockedCalendar {
        BlockedCalendar.build(availability: .measured,
                              bookings: [OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "Client", shootName: "Gala",
                                                         startDate: "2026-11-13", endDate: "2026-11-13",
                                                         venueId: nil, venueName: "Hall")],
                              exportedBlockedDates: [],
                              daysOff: [DayOffRange(startDate: "2026-11-27", endDate: "2026-11-27", note: "away")])
    }

    private func nights(_ plan: PrepNightPlan, _ p: Prospect) throws -> [PrepNightPlan.Night] {
        try #require(plan.runs[p.naturalKey]?.perNight)
    }

    // Answer 5 and answer 7: a blocked night is shown unticked, naming the clash, and the run opens.
    @Test func blockedNightsStartUntickedNamedAndTheRunOpens() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        let n = try nights(plan, p)
        #expect(n.map(\.date) == Self.nights)
        #expect(n.map(\.defaultTicked) == [true, false, true, false])
        guard case .blocked(let day) = n[1].clash else { Issue.record("the 13th is not blocked"); return }
        #expect(day.name == "Gala")
        #expect(plan.runs[p.naturalKey]?.opensByDefault == true)
    }

    @Test func aCleanRunStaysClosedWithEveryNightTicked() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-12-04", "2026-12-11"])
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        #expect(try nights(plan, p).allSatisfy(\.defaultTicked))
        #expect(plan.runs[p.naturalKey]?.opensByDefault == false)
    }

    // L330: the card's "I can shoot this anyway" is consulted, not bypassed.
    @Test func aClashDanClearedOnTheCardIsWaivedNotAskedAgain() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-06", "2026-11-13"])
        let gala = try #require(calendar.blockedNights(.recorded(["2026-11-13"])).first)
        p.setScoutConflict(gala.key)
        p.clearConflict()
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        let n = try nights(plan, p)
        guard case .waived = n[1].clash else { Issue.record("the cleared clash was raised again"); return }
        #expect(n[1].defaultTicked)
        #expect(plan.runs[p.naturalKey]?.opensByDefault == false)
    }

    // #3961: a night pitched despite a clash stays accepted while the clash is the same one, and blocks
    // again when a DIFFERENT clash lands on it (#718's pattern).
    @Test func anAcceptedClashHoldsUntilTheClashChanges() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-06", "2026-11-13"])
        let gala = try #require(calendar.blockedNights(.recorded(["2026-11-13"])).first)
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-11-06", at: now, origin: .chosen),
                                             NightDecision(night: "2026-11-13", at: now, origin: .chosen,
                                                           acceptedClashKey: gala.key)],
                                   skipped: [])
        let same = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        guard case .accepted = try nights(same, p)[1].clash else { Issue.record("not read as accepted"); return }
        #expect(try nights(same, p)[1].defaultTicked)

        let other = BlockedCalendar.build(availability: .measured,
                                          bookings: [OvertureBooking(id: "b2", clientId: "c2", clientDisplayName: "Client", shootName: "Wedding",
                                                                     startDate: "2026-11-13", endDate: "2026-11-13",
                                                                     venueId: nil, venueName: "Hall")],
                                          exportedBlockedDates: [], daysOff: [])
        let changed = PrepNightPlan.build(prospects: [p], calendar: other, availability: .measured, today: "2026-09-01")
        guard case .blocked = try nights(changed, p)[1].clash else {
            Issue.record("a different shoot on an accepted night did not block it again"); return
        }
        #expect(try nights(changed, p)[1].defaultTicked == false)
    }

    @Test func aNightSkippedBeforeStartsUnticked() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-12-04", "2026-12-11"])
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-12-04", at: now, origin: .chosen)],
                                   skipped: [NightDecision(night: "2026-12-11", at: now, origin: .chosen)])
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        #expect(try nights(plan, p).map(\.defaultTicked) == [true, false])
    }

    // #3311: a calendar that could not be read marks nothing and SAYS so; it is never read as clear.
    @Test func anUnreadableCalendarIsItsOwnStateAndMarksNoNight() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .unknown, today: "2026-09-01")
        #expect(plan.calendar == .couldNotRead)
        #expect(try nights(plan, p).allSatisfy { $0.clash == .clear })
        let read = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        #expect(read.calendar == .read)
    }

    // Plan 3.3 and 3.4: a run with no recorded nights says so, and a night stored twice is offered once.
    @Test func spanOnlyAndSingleNightRowsAndDuplicates() throws {
        let ctx = ModelContext(try container())
        let span = run(ctx, name: "Span", nights: [])
        span.performanceDate = "2026-10-09"
        span.runEndDate = "2026-10-12"
        let single = run(ctx, name: "Single", nights: ["2026-10-20"])
        let doubled = run(ctx, name: "Doubled", nights: ["2026-12-04", "2026-12-04", "2026-12-11", "2026-12-11"])
        let plan = PrepNightPlan.build(prospects: [span, single, doubled], calendar: .empty, availability: .measured, today: "2026-09-01")
        #expect(plan.runs[span.naturalKey]?.nights == .notRecorded)
        #expect(plan.runs[single.naturalKey]?.nights == .single)
        #expect(try nights(plan, doubled).map(\.date) == ["2026-12-04", "2026-12-11"])
    }

    // Plan 2.3: opened commits `chosen`, closed commits `default`, and a night ticked over a clash carries
    // the clash's key.
    @Test func theCommitRecordsHowItWasMadeAndWhichClashWasAccepted() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        let gala = try #require(calendar.blockedNights(.recorded(["2026-11-13"])).first)
        let opened = try #require(plan.commit(key: p.naturalKey, ticked: ["2026-11-06", "2026-11-13"],
                                              opened: true, now: now))
        #expect(opened.pitched.map(\.night) == ["2026-11-06", "2026-11-13"])
        #expect(opened.skipped.map(\.night) == ["2026-11-20", "2026-11-27"])
        #expect(opened.pitched.allSatisfy { $0.origin == .chosen })
        #expect(opened.pitched[1].acceptedClashKey == gala.key)
        #expect(opened.pitched[0].acceptedClashKey == nil)
        let closed = try #require(plan.commit(key: p.naturalKey, ticked: Set(Self.nights), opened: false, now: now))
        #expect((closed.pitched + closed.skipped).allSatisfy { $0.origin == .byDefault })
    }

    // One predicate for the confirm: a ticked blocked night is asked about, an unticked one is not, and a
    // waived one is not asked again.
    @Test func theConfirmAsksOnlyAboutTickedNightsTheCalendarBlocks() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        let none = plan.calendarClashes(forKeys: [p.naturalKey], ticks: [p.naturalKey: ["2026-11-06"]], among: [])
        #expect(none.isEmpty)
        let one = plan.calendarClashes(forKeys: [p.naturalKey],
                                       ticks: [p.naturalKey: ["2026-11-06", "2026-11-13"]], among: [])
        #expect(one.map(\.note) == ["You're already shooting Gala on Nov 13."])
    }

    // #3312: chronology wins over a tick. A night already behind us is not offered, so the picker can never
    // record a choice the drafter would then be told to overrule.
    @Test func aNightAlreadyPastIsNotOffered() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let plan = PrepNightPlan.build(prospects: [p], calendar: .empty, availability: .measured,
                                       today: "2026-11-14")
        #expect(try nights(plan, p).map(\.date) == ["2026-11-20", "2026-11-27"])
        let last = PrepNightPlan.build(prospects: [p], calendar: .empty, availability: .measured,
                                       today: "2026-11-21")
        #expect(last.runs[p.naturalKey]?.nights == .single, "one night left is the row's own checkbox")
    }

    // MARK: the commit against the store (plan 3.6)

    @Test func theLaunchCommitsTheNightsThenHandsBackKeysReadFromTheRows() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        try ctx.save()
        let plan = PrepNightPlan.build(prospects: [p], calendar: calendar, availability: .measured, today: "2026-09-01")
        let commit = try #require(plan.commit(key: p.naturalKey, ticked: ["2026-11-06", "2026-11-20"],
                                              opened: true, now: now))
        let outcome = try PrepNightCommitting.apply(
            PrepSelectionSheet.Choice(keys: [p.naturalKey], commits: [p.naturalKey: commit]), in: ctx)
        #expect(outcome.launchKeys == [p.naturalKey])
        #expect(outcome.leftOut.isEmpty)
        #expect(p.pitchedNightDecisions.map(\.night) == ["2026-11-06", "2026-11-20"])
        #expect(p.skippedNightDecisions.map(\.night) == ["2026-11-13", "2026-11-27"])
    }

    // A scout ran while the sheet was open and a night left the run: that run is left out BY NAME, the
    // others launch.
    @Test func aRunWhoseNightsMovedUnderTheSheetIsLeftOutByName() throws {
        let ctx = ModelContext(try container())
        let moved = run(ctx, name: "Moved")
        let fine = run(ctx, name: "Fine", nights: ["2026-12-04", "2026-12-11"])
        try ctx.save()
        let plan = PrepNightPlan.build(prospects: [moved, fine], calendar: .empty, availability: .measured, today: "2026-09-01")
        let c1 = try #require(plan.commit(key: moved.naturalKey, ticked: Set(Self.nights), opened: false, now: now))
        let c2 = try #require(plan.commit(key: fine.naturalKey, ticked: ["2026-12-04"], opened: true, now: now))
        moved.runNights = Array(Self.nights.dropLast())   // the 27th left the feed after the sheet opened
        let outcome = try PrepNightCommitting.apply(
            PrepSelectionSheet.Choice(keys: [moved.naturalKey, fine.naturalKey],
                                      commits: [moved.naturalKey: c1, fine.naturalKey: c2]), in: ctx)
        #expect(outcome.launchKeys == [fine.naturalKey])
        #expect(outcome.leftOut == ["Moved"])
        #expect(moved.pitchedRunNights.isEmpty, "a refused run wrote part of its decisions")
    }

    private struct DiskFull: Error {}

    // L12: a save that fails launches NOTHING and says so.
    @Test func aFailedSaveLaunchesNothing() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        try ctx.save()
        let plan = PrepNightPlan.build(prospects: [p], calendar: .empty, availability: .measured, today: "2026-09-01")
        let commit = try #require(plan.commit(key: p.naturalKey, ticked: Set(Self.nights), opened: false, now: now))
        #expect(throws: PrepNightCommitting.SaveFailed.self) {
            try PrepNightCommitting.apply(PrepSelectionSheet.Choice(keys: [p.naturalKey],
                                                                    commits: [p.naturalKey: commit]),
                                          in: ctx, save: { _ in throw DiskFull() })
        }
        #expect(p.pitchedRunNights.isEmpty, "the failed save left the decisions in memory as if recorded")
    }

    // MARK: the copy

    @Test func nightsAreGroupedByWeekAndNamedByWeekday() {
        let weeks = PrepSelectionCopy.weeks(["2026-11-06", "2026-11-07", "2026-11-13", "2026-11-20"])
        #expect(weeks.map(\.label) == ["Week of Nov 2", "Week of Nov 9", "Week of Nov 16"])
        #expect(weeks[0].nights == ["2026-11-06", "2026-11-07"])
        #expect(PrepSelectionCopy.nightLabel("2026-11-06") == "Fri Nov 6")
        #expect(PrepSelectionCopy.nightsSummary(ticked: 4, of: 4) == "All 4 nights")
        #expect(PrepSelectionCopy.nightsSummary(ticked: 3, of: 4) == "3 of 4 nights")
        #expect(PrepSelectionCopy.nightsSummary(ticked: 0, of: 4) == "No nights")
    }
}
