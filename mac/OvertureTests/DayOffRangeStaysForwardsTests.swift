import Testing
import Foundation
import SwiftData

// #2254, Dan walking the days off form on 2026-08-07: moving First day forward to 8/10/2026 left Last
// day sitting at 8/7/2026, three days before the range starts, with both fields looking perfectly
// normal. The press was refused, but only after he had typed a range the form had shown him as fine.
@MainActor
@Suite("The days off range never ends before it starts (#2254)")
struct DayOffRangeStaysForwardsTests {

    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }

    // The case from the walk: the first day moves past the last, and the last comes with it.
    @Test func movingTheFirstDayPastTheLastCarriesTheLastWithIt() {
        let moved = DayOffEditing.endMovedWithStart(start: day("2026-08-10"), end: day("2026-08-07"))
        #expect(EasternDate.dayString(from: moved) == "2026-08-10")
    }

    // A range that is already forwards is left entirely alone: this rule exists to stop an impossible
    // range, not to collapse a real one.
    @Test func aForwardsRangeIsUntouched() {
        let moved = DayOffEditing.endMovedWithStart(start: day("2026-08-07"), end: day("2026-08-10"))
        #expect(EasternDate.dayString(from: moved) == "2026-08-10")
    }

    @Test func aSingleDayRangeIsUntouched() {
        let moved = DayOffEditing.endMovedWithStart(start: day("2026-08-07"), end: day("2026-08-07"))
        #expect(EasternDate.dayString(from: moved) == "2026-08-07")
    }

    // The reason this compares Eastern DAYS and not instants. Both pickers carry a time of day, so a
    // first day whose instant is later within the SAME day is not a backwards range, and dragging the
    // last day onto it would silently shorten a range Dan never touched.
    @Test func aLaterTimeOnTheSameDayIsNotABackwardsRange() {
        let start = day("2026-08-07").addingTimeInterval(20 * 3_600)
        let end = day("2026-08-07")
        let moved = DayOffEditing.endMovedWithStart(start: start, end: end)
        #expect(moved == end, "the same day is not backwards, whatever the clock time says")
    }

    // It only ever moves the range FORWARD, so extending a trip by pushing Last day out is untouched.
    @Test func movingTheLastDayOutIsNotThisRulesBusiness() {
        let moved = DayOffEditing.endMovedWithStart(start: day("2026-08-07"), end: day("2026-12-31"))
        #expect(EasternDate.dayString(from: moved) == "2026-12-31")
    }

    // Part 2 of the issue: if a backwards range still reaches the press, it is refused with a reason on
    // screen rather than silently accepted. The refusal exists (#1417); what was missing was any test
    // that the SHEETS' own writer returns the words, rather than the domain result alone.
    @Test func aBackwardsRangeReachingThePressIsRefusedInWords() throws {
        let ctx = try ModelContext(ModelContainer(
            for: DayOff.self, Prospect.self, Inquiry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let feedback = ActionFeedback()

        let outcome = DayOffMutations.add(start: "2026-08-10", end: "2026-08-07", note: nil,
                                          export: ([], []), context: ctx, feedback: feedback)

        #expect(outcome == .refused("The last day is before the first day."))
        #expect(DayOffEditing.rows(in: ctx).isEmpty, "and nothing was written")
    }
}

// The rule is only worth anything if the fields Dan actually types into ask it. Both sheets embed the
// same fields view, so pinning it once covers the Days off form and the block-these-days picker, and a
// sheet that grew its own copy of the rule would be the drift this file exists to prevent.
@Suite("Both days off sheets share one range rule (#2254)")
struct DayOffRangeFieldsWiringTests {
    private var fields: String { SourceGuardHelper.source("Overture/UI/DayOffRangeFields.swift") }

    @Test func theFieldsCarryTheLastDayForwardWithTheFirst() {
        #expect(!fields.isEmpty)
        #expect(fields.contains("DayOffEditing.endMovedWithStart(start: moved, end: end)"))
        #expect(fields.contains(".onChange(of: start)"))
    }

    @Test func theLastDayPickerCannotBeSetBeforeTheFirst() {
        #expect(fields.contains("in: start..."))
    }

    // Neither sheet may state the rule itself: the whole point of the shared fields view is that there
    // is one place to change it.
    @Test func neitherSheetKeepsItsOwnCopyOfTheRule() {
        for file in ["Overture/UI/DaysOffView.swift", "Overture/UI/BlockDaysSheet.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty)
            #expect(source.contains("DayOffRangeFields("), "\(file) must use the shared fields")
            #expect(!source.contains("endMovedWithStart"), "\(file) must not restate the range rule")
        }
    }
}
