import Testing
import Foundation
import SwiftData

// #3620: what the Days off sheet does around a weekly rule, and what it says. Each action says what it did
// only once the write has landed, and each removal can be undone from the banner it happened in, as a
// range's can (#1417, #845). 2026-09-23 and 2026-09-30 are Wednesdays.
@MainActor
@Suite("Adding, removing and freeing a weekly block, as the sheet does it (#3620)")
struct WeeklyDayOffMutationsTests {
    private let wednesday = 4
    private let noExport: DayOffEditing.Export = (bookings: [], blockedDates: [], health: .ok)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, CancelledShoot.self, WeeklyDayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

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

    @Test func aRefusedRuleSaysWhyAndAddsNothing() throws {
        let ctx = try context()
        let outcome = WeeklyDayOffMutations.add(weekday: wednesday, firstDate: "2027-02-03",
                                                lastDate: "2027-01-06", note: nil, export: noExport,
                                                context: ctx, feedback: ActionFeedback())
        #expect(outcome == .refused("The last day is before the first day."))
        #expect(WeeklyDayOffEditing.rows(in: ctx).isEmpty)
    }

    // The Undo puts back the WHOLE rule, freed dates included, and the shows it blocked are blocked again.
    @Test func removingARuleSaysSoAndItsUndoPutsTheWholeRuleBack() throws {
        let ctx = try context()
        let blocked = show(ctx, on: "2026-09-30")
        let freed = show(ctx, on: "2026-09-23")
        let feedback = ActionFeedback()
        #expect(WeeklyDayOffMutations.add(weekday: wednesday, firstDate: nil, lastDate: nil, note: "Rehearsal",
                                          export: noExport, context: ctx, feedback: feedback) == .added)
        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)
        WeeklyDayOffEditing.free("2026-09-23", from: rule, export: noExport, in: ctx)

        WeeklyDayOffMutations.remove(rule, export: noExport, context: ctx, feedback: feedback)
        #expect(feedback.message == "Every Wednesday is no longer blocked")
        #expect(!blocked.hasUnclearedConflict)

        feedback.action?.perform()
        let back = try #require(WeeklyDayOffEditing.rows(in: ctx).first)
        #expect(back.freedDates == ["2026-09-23"])
        #expect(back.note == "Rehearsal")
        #expect(blocked.hasUnclearedConflict)
        #expect(!freed.hasUnclearedConflict)
    }

    @Test func freeingADateSaysSoAndItsUndoBlocksItAgain() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-09-23")
        let feedback = ActionFeedback()
        WeeklyDayOffEditing.add(weekday: wednesday, firstDate: nil, lastDate: nil, note: nil,
                                export: noExport, into: ctx)
        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)

        #expect(WeeklyDayOffMutations.free("2026-09-23", from: rule, export: noExport,
                                           context: ctx, feedback: feedback) == .freed)
        #expect(feedback.message == "Sep 23 is no longer blocked")
        #expect(!p.hasUnclearedConflict)

        feedback.action?.perform()
        #expect(p.hasUnclearedConflict)
        #expect(rule.freedDates.isEmpty)
    }

    // The usual mistake is a date on the wrong weekday, so the refusal names the weekday.
    @Test func freeingADateTheRuleDoesNotBlockIsRefusedByName() throws {
        let ctx = try context()
        let feedback = ActionFeedback()
        WeeklyDayOffEditing.add(weekday: wednesday, firstDate: nil, lastDate: nil, note: nil,
                                export: noExport, into: ctx)
        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)

        #expect(WeeklyDayOffMutations.free("2026-09-24", from: rule, export: noExport,
                                           context: ctx, feedback: feedback)
                == .refused("Sep 24 isn't one of the Wednesdays this blocks."))
        #expect(rule.freedDates.isEmpty)
    }

    @Test func blockingAFreedDateAgainSaysSo() throws {
        let ctx = try context()
        let feedback = ActionFeedback()
        WeeklyDayOffEditing.add(weekday: wednesday, firstDate: nil, lastDate: nil, note: nil,
                                export: noExport, into: ctx)
        let rule = try #require(WeeklyDayOffEditing.rows(in: ctx).first)
        WeeklyDayOffEditing.free("2026-09-23", from: rule, export: noExport, in: ctx)

        WeeklyDayOffMutations.reblock("2026-09-23", on: rule, export: noExport, context: ctx, feedback: feedback)
        #expect(feedback.message == "Sep 23 is now blocked")
        #expect(rule.freedDates.isEmpty)
    }

    // MARK: The add form

    @Test func theConfirmButtonNamesTheWeekday() {
        #expect(DayOffEditing.addConfirmTitle(kind: .someDays, weekday: wednesday) == "Block these days")
        #expect(DayOffEditing.addConfirmTitle(kind: .everyWeek, weekday: wednesday) == "Block every Wednesday")
    }

    // Closing the sheet over an edited weekly form asks first, as it does over an edited range (#928).
    @Test func anEditedWeeklyFormAsksBeforeClosing() {
        let base = DayOffEditing.AddDraft(startDay: "2026-09-18", endDay: "2026-09-18", note: "")
        var weekly = base
        weekly.kind = .everyWeek
        #expect(DayOffEditing.closeNeedsConfirmation(addFormOpen: true, draft: weekly, baseline: base))

        var picked = weekly
        picked.weekday = 5
        #expect(DayOffEditing.closeNeedsConfirmation(addFormOpen: true, draft: picked, baseline: weekly))

        var bounded = weekly
        bounded.lastDay = "2027-01-14"
        #expect(DayOffEditing.closeNeedsConfirmation(addFormOpen: true, draft: bounded, baseline: weekly))
        #expect(!DayOffEditing.closeNeedsConfirmation(addFormOpen: true, draft: weekly, baseline: weekly))
    }

    // MARK: The sheet uses them

    @Test func theSheetListsEachRuleAsOneRowAndCountsIt() throws {
        let sheet = SourceGuardHelper.source("Overture/UI/DaysOffView.swift")
        #expect(!sheet.isEmpty, "DaysOffView.swift did not resolve; every check below is unmeasured")
        let mine = try #require(SourceGuardHelper.propertyBody("private var myDaysOff: some View {", in: sheet))
        #expect(mine.contains("WeeklyDayOffEditing.upcoming(weeklyRules, today: today)"))
        #expect(mine.contains("count: shownRules.count + shown.count"))
        #expect(mine.contains("ForEach(shownRules)"))
        #expect(mine.contains("hasPastRanges: !daysOff.isEmpty || !weeklyRules.isEmpty"))
    }
}
