import Testing
import Foundation
import SwiftData
@testable import Overture

// #901: Dan blocking his own dates. The vacation half of the ask, and (since Downbeat exports no
// bookings and only ever will for shoots booked through it, going forward) the only conflict source that
// works at all today.
@MainActor
@Suite("Days off editing")
struct DayOffEditingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func rows(_ ctx: ModelContext) -> [DayOff] {
        (try? ctx.fetch(FetchDescriptor<DayOff>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
    }

    // MARK: - Adding

    @Test func aRangeIsStoredOnceRatherThanAsOneRowPerDay() throws {
        let ctx = try context()
        let result = DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation", into: ctx)

        #expect(result == .added)
        #expect(rows(ctx).count == 1)                    // one row, not nine
        #expect(rows(ctx).first?.endDate == "2026-11-22")
        #expect(rows(ctx).first?.note == "Vacation")
    }

    @Test func aSingleDayIsARangeOfOne() throws {
        let ctx = try context()
        DayOffEditing.add(start: "2026-11-14", end: "2026-11-14", note: nil, into: ctx)

        #expect(DayOffEditing.ranges(in: ctx) == [DayOffRange(startDate: "2026-11-14", endDate: "2026-11-14", note: nil)])
    }

    // MARK: - What it refuses

    @Test func aBackwardsRangeIsRefused() throws {
        let ctx = try context()
        let result = DayOffEditing.add(start: "2026-11-22", end: "2026-11-14", note: nil, into: ctx)

        #expect(result == .endsBeforeItStarts)
        #expect(rows(ctx).isEmpty)                       // and nothing was written
    }

    // Overture only ever looks at a four-month calendar horizon (#858), so a decade-long block is a typo,
    // not a plan, and silently expanding it to 3,650 days helps nobody.
    @Test func anAbsurdlyLongRangeIsRefused() throws {
        let ctx = try context()
        let result = DayOffEditing.add(start: "2026-11-14", end: "2036-11-14", note: nil, into: ctx)

        #expect(result == .tooLong)
        #expect(rows(ctx).isEmpty)
    }

    @Test func anUnparseableDateIsRefused() throws {
        let ctx = try context()
        #expect(DayOffEditing.add(start: "next tuesday", end: "2026-11-14", note: nil, into: ctx) == .invalidDate)
        #expect(rows(ctx).isEmpty)
    }

    // MARK: - Removing

    @Test func removingARangeUnblocksItsDays() throws {
        let ctx = try context()
        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation", into: ctx)
        let row = try #require(rows(ctx).first)

        DayOffEditing.remove(row, in: ctx)

        #expect(rows(ctx).isEmpty)
        #expect(DayOffEditing.ranges(in: ctx).isEmpty)
    }

    // MARK: - What the scout reads

    // The ranges feed the blocked calendar, so a day inside one really does flag a show.
    @Test func aStoredRangeBlocksAShowInsideIt() throws {
        let ctx = try context()
        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation", into: ctx)

        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [],
                                        daysOff: DayOffEditing.ranges(in: ctx))

        #expect(cal.conflict(performanceDate: "2026-11-18", runEndDate: nil)?.name == "Vacation")
        #expect(cal.conflict(performanceDate: "2026-11-30", runEndDate: nil) == nil)
    }

    // An empty note is not a note. Stored as nil, so the sentence Dan reads is "You blocked Nov 14."
    // rather than "You blocked Nov 14 ()."
    @Test func aBlankNoteIsStoredAsNoNote() throws {
        let ctx = try context()
        DayOffEditing.add(start: "2026-11-14", end: "2026-11-14", note: "   ", into: ctx)

        #expect(DayOffEditing.ranges(in: ctx).first?.note == nil)
    }

    // MARK: - What Dan reads

    @Test func eachRefusalSaysWhatToDoAboutIt() {
        #expect(DayOffEditing.message(for: .endsBeforeItStarts) == "The last day is before the first day.")
        #expect(DayOffEditing.message(for: .tooLong) == "That's longer than a year. Block a shorter stretch.")
        #expect(DayOffEditing.message(for: .invalidDate) == "That isn't a date Overture can read.")
        #expect(DayOffEditing.message(for: .added) == nil)     // success says nothing; the row appearing is the receipt
    }
}
