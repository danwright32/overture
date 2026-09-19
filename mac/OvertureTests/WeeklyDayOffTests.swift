import Testing
import Foundation
import SwiftData

// #3620: one weekday blocked every week, with an optional first and last date, and single dates freed
// from it. Dates here are pinned (L130); 2026-09-16, 2026-09-23 and 2031-09-17 are Wednesdays.
@MainActor
@Suite("A weekday blocked every week (#3620)")
struct WeeklyDayOffTests {
    private let wednesday = 4

    // MARK: The rule, asked of one date

    // THE horizon test. A standing rule answers by predicate, so a Wednesday five years out is blocked
    // exactly as next week's is. An expansion capped at 366 days would have answered "free" here, silently.
    @Test func aStandingRuleBlocksEveryWednesdayWithNoHorizon() {
        let rule = WeeklyBlock(weekday: wednesday)

        #expect(rule.blocks("2026-09-16"))
        #expect(rule.blocks("2026-09-23"))
        #expect(rule.blocks("2031-09-17"))
        #expect(!rule.blocks("2026-09-17"))              // a Thursday
        #expect(!rule.blocks("not a date"))
    }

    // All four combinations Dan asked for.
    @Test func theFirstAndLastDatesBoundTheRuleInclusively() {
        let until = WeeklyBlock(weekday: 5, lastDate: "2027-01-14")          // every Thursday until Jan 14
        #expect(until.blocks("2026-09-17"))
        #expect(until.blocks("2027-01-14"))
        #expect(!until.blocks("2027-01-21"))

        let from = WeeklyBlock(weekday: wednesday, firstDate: "2027-02-03")    // resumes after a break
        #expect(!from.blocks("2027-01-27"))
        #expect(from.blocks("2027-02-03"))
        #expect(from.blocks("2031-09-17"))

        let both = WeeklyBlock(weekday: wednesday, firstDate: "2027-02-03", lastDate: "2027-06-30")
        #expect(!both.blocks("2027-01-27"))
        #expect(both.blocks("2027-06-30"))
        #expect(!both.blocks("2027-07-07"))
    }

    @Test func aFreedDateIsFreeAndTheRestOfTheRuleStands() {
        let rule = WeeklyBlock(weekday: wednesday, freedDates: ["2026-09-23"])

        #expect(!rule.blocks("2026-09-23"))
        #expect(rule.blocks("2026-09-16"))
        #expect(rule.blocks("2026-09-30"))
    }

    // MARK: The calendar

    private func calendar(daysOff: [DayOffRange] = [], bookings: [OvertureBooking] = [],
                          weekly: [WeeklyBlock]) -> BlockedCalendar {
        BlockedCalendar.build(availability: .measured, bookings: bookings, exportedBlockedDates: [],
                              daysOff: daysOff, weeklyBlocks: weekly)
    }

    // A rule's night is an ordinary day off: the same kind, the same key shape and the same sentence Dan
    // reads, so the clearance and every surface downstream need nothing new.
    @Test func aRulesNightIsAnOrdinaryDayOffAndSaysSo() {
        let cal = calendar(weekly: [WeeklyBlock(weekday: wednesday, note: "Rehearsal")])
        let clash = cal.conflict(performanceDate: "2031-09-17", runEndDate: nil)

        #expect(clash?.kind == .dayOff)
        #expect(clash?.key == "dayOff|2031-09-17|Rehearsal")
        #expect(clash?.reason == "You blocked Sep 17 (Rehearsal).")
        #expect(cal.conflict(performanceDate: "2031-09-18", runEndDate: nil) == nil)
    }

    // A run is judged on every night, so a rule's Wednesday inside it is caught, by real nights and by span.
    @Test func aRunIsCaughtOnTheWednesdayInsideIt() {
        let cal = calendar(weekly: [WeeklyBlock(weekday: wednesday, note: "Rehearsal")])

        #expect(cal.conflict(performanceDate: "2026-09-14", runEndDate: "2026-09-18")?.date == "2026-09-16")
        #expect(cal.conflict(performanceDate: "2026-09-14", runEndDate: "2026-09-18",
                             nights: ["2026-09-14", "2026-09-16"])?.date == "2026-09-16")
        #expect(cal.conflict(performanceDate: "2026-09-14", runEndDate: "2026-09-18",
                             nights: ["2026-09-14", "2026-09-15"]) == nil)
    }

    // Precedence on one date: a booked shoot outranks the rule, and a range Dan typed for that date keeps
    // deciding, so no key he has already cleared moves because a rule arrived on the same night.
    @Test func aBookingOutranksTheRuleAndATypedRangeKeepsDeciding() {
        let shoot = OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client",
                                    shootName: "Smith Recital", startDate: "2026-09-16", endDate: "2026-09-16",
                                    venueId: nil, venueName: "V")
        let rule = WeeklyBlock(weekday: wednesday, note: "Rehearsal")

        #expect(calendar(bookings: [shoot], weekly: [rule])
            .conflict(performanceDate: "2026-09-16", runEndDate: nil)?.name == "Smith Recital")

        let typed = DayOffRange(startDate: "2026-09-16", endDate: "2026-09-16", note: "Empire rehearsal")
        #expect(calendar(daysOff: [typed], weekly: [rule])
            .conflict(performanceDate: "2026-09-16", runEndDate: nil)?.name == "Empire rehearsal")
    }

    // Two rules on the same weekday answer the same way whichever order the store returns them in.
    @Test func twoRulesOnOneDateDecideTheSameWayInEitherOrder() {
        let a = WeeklyBlock(weekday: wednesday, note: "Choir")
        let b = WeeklyBlock(weekday: wednesday, note: "Rehearsal")

        #expect(calendar(weekly: [a, b]).conflict(performanceDate: "2026-09-16", runEndDate: nil)?.key
                == calendar(weekly: [b, a]).conflict(performanceDate: "2026-09-16", runEndDate: nil)?.key)
    }

    // MARK: Adding, removing and freeing re-judge the queue at once

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, CancelledShoot.self, WeeklyDayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let noExport: DayOffEditing.Export = (bookings: [], blockedDates: [], health: .ok)

    @discardableResult
    private func show(_ ctx: ModelContext, on date: String) -> Prospect {
        let p = Prospect(naturalKey: "key-\(date)", groupName: "A Choir", discipline: "choral",
                         venue: "A Hall", performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func addingARuleFlagsItsShowsAndRemovingItFreesThem() throws {
        let ctx = try context()
        let far = show(ctx, on: "2031-09-17")
        let thursday = show(ctx, on: "2026-09-17")

        #expect(WeeklyDayOffEditing.add(weekday: wednesday, firstDate: nil, lastDate: nil,
                                        note: "Rehearsal", export: noExport, into: ctx) == .added)
        #expect(far.hasUnclearedConflict)
        #expect(far.conflictNote == "You blocked Sep 17 (Rehearsal).")
        #expect(!thursday.hasUnclearedConflict)

        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)
        WeeklyDayOffEditing.remove(rule, export: noExport, in: ctx)
        #expect(!far.hasUnclearedConflict)
        #expect(WeeklyDayOffEditing.rows(in: ctx).isEmpty)
    }

    @Test func freeingADateFreesThatShowOnlyAndBlockingItAgainPutsItBack() throws {
        let ctx = try context()
        let freed = show(ctx, on: "2026-09-23")
        let other = show(ctx, on: "2026-09-30")
        WeeklyDayOffEditing.add(weekday: wednesday, firstDate: nil, lastDate: nil, note: "Rehearsal",
                                export: noExport, into: ctx)
        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)

        #expect(WeeklyDayOffEditing.free("2026-09-23", from: rule, export: noExport, in: ctx) == .freed)
        #expect(!freed.hasUnclearedConflict)
        #expect(other.hasUnclearedConflict)
        #expect(rule.freedDates == ["2026-09-23"])

        WeeklyDayOffEditing.reblock("2026-09-23", on: rule, export: noExport, in: ctx)
        #expect(freed.hasUnclearedConflict)
        #expect(rule.freedDates.isEmpty)
    }

    // A date the rule never blocked cannot be "freed": the row would then claim a night was freed when
    // nothing about it changed.
    @Test func aDateTheRuleDoesNotBlockIsRefusedRatherThanRecorded() throws {
        let ctx = try context()
        WeeklyDayOffEditing.add(weekday: wednesday, firstDate: "2026-10-01", lastDate: nil, note: nil,
                                export: noExport, into: ctx)
        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)

        #expect(WeeklyDayOffEditing.free("2026-09-24", from: rule, export: noExport, in: ctx)
                == .notBlockedByThisRule)                                   // a Thursday
        #expect(WeeklyDayOffEditing.free("2026-09-23", from: rule, export: noExport, in: ctx)
                == .notBlockedByThisRule)                                   // before the rule starts
        #expect(rule.freedDates.isEmpty)
    }

    @Test func aRuleThatCannotBeMeantIsRefusedWithAReason() throws {
        let ctx = try context()
        #expect(WeeklyDayOffEditing.add(weekday: 9, firstDate: nil, lastDate: nil, note: nil,
                                        export: noExport, into: ctx) == .notAWeekday)
        #expect(WeeklyDayOffEditing.add(weekday: wednesday, firstDate: "someday", lastDate: nil, note: nil,
                                        export: noExport, into: ctx) == .invalidDate)
        #expect(WeeklyDayOffEditing.add(weekday: wednesday, firstDate: "2027-02-03", lastDate: "2027-01-06",
                                        note: nil, export: noExport, into: ctx) == .endsBeforeItStarts)
        #expect(WeeklyDayOffEditing.rows(in: ctx).isEmpty)
        for result in [WeeklyDayOffEditing.Result.notAWeekday, .invalidDate, .endsBeforeItStarts] {
            #expect(WeeklyDayOffEditing.message(for: result) != nil, "\(result) refuses without saying why")
        }
    }

    // The ONE production place the calendar is built reads the rules, so the scout, the sheet and the sweep
    // all judge against them.
    @Test func theAppsCalendarReadsTheStoredRules() throws {
        let ctx = try context()
        ctx.insert(WeeklyDayOff(weekday: wednesday, note: "Rehearsal"))
        try ctx.save()

        let cal = ScoutService.blockedCalendar(export: noExport, context: ctx)
        #expect(cal.conflict(performanceDate: "2031-09-17", runEndDate: nil)?.name == "Rehearsal")
    }

    // And nothing else in the app builds a calendar that could leave them out: `build` defaults the rules
    // to none, so a second production caller would quietly judge without them.
    @Test func theOnlyProductionBuildOfTheCalendarPassesTheRules() {
        let service = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!service.isEmpty)
        #expect(service.contains("weeklyBlocks: WeeklyDayOffEditing.blocks(in: context)"))
        let callers = AppSourceWalk.appFiles().filter { $0.text.contains("BlockedCalendar.build(") }.map(\.name)
        #expect(callers == ["ScoutService.swift"],
                "a second production caller of BlockedCalendar.build: \(callers)")
    }

    // MARK: What the sheet shows

    @Test func theRowSaysTheRuleTheWayDanWouldSayIt() {
        #expect(WeeklyDayOffEditing.label(weekday: wednesday, firstDate: nil, lastDate: nil) == "Every Wednesday")
        #expect(WeeklyDayOffEditing.label(weekday: 5, firstDate: nil, lastDate: "2027-01-14")
                == "Every Thursday until Jan 14")
        #expect(WeeklyDayOffEditing.label(weekday: wednesday, firstDate: "2027-02-03", lastDate: nil)
                == "Every Wednesday from Feb 3")
        #expect(WeeklyDayOffEditing.label(weekday: wednesday, firstDate: "2027-02-03", lastDate: "2027-06-30")
                == "Every Wednesday, Feb 3 to Jun 30")
    }

    // #3406 for the third list: a bounded rule whose last date has gone is no longer listed; a standing one
    // never expires. Filtered, never deleted.
    @Test func anEndedRuleIsNoLongerListed() {
        let standing = WeeklyDayOff(weekday: wednesday)
        let ended = WeeklyDayOff(weekday: 5, lastDate: "2026-09-10")
        let endsToday = WeeklyDayOff(weekday: 6, lastDate: "2026-09-18")

        let shown = WeeklyDayOffEditing.upcoming([standing, ended, endsToday], today: "2026-09-18")
        #expect(shown.map(\.weekday) == [wednesday, 6])
    }

    @Test func theRuleIsInTheAppSchema() {
        #expect(AppSchema.models.contains { ObjectIdentifier($0) == ObjectIdentifier(WeeklyDayOff.self) })
    }
}
