import Testing
import Foundation

// Two defects that shipped in #2692 and were found by reading the merged code afterwards, not by any
// check. Dan, on being shown them: "Why are you shipping code with defects in it? You should fix it
// before you ship moving forward." So they are fixed, and guarded, because neither was catchable by
// anything that existed.
//
// Both are rules this repo already states and neither was applied to the VIEW that was added. The class
// sweep in #2692 covered the domain rule being changed and stopped there.
@Suite("The days off sheet pays once and counts what it draws (#2692 follow-up)")
struct DaysOffSheetCostAndCountsTests {
    private let sheet = SourceGuardHelper.source("Overture/UI/DaysOffView.swift")

    // The path has to be right or SourceGuardHelper returns "" and every check below passes vacuously.
    @Test func theSourceIsActuallyRead() {
        #expect(!sheet.isEmpty, "DaysOffView.swift did not resolve; every guard below is unmeasured")
    }

    // DEFECT 1. `bookedShootRow` looked up which booking a row stood for by reading the whole Downbeat
    // export from disk, INSIDE the row, so a sheet with fifteen bookings decoded the export fifteen times
    // to draw itself. `cancelledShootRow` did it too, and fetched the cancellations again on top.
    //
    // That is #1960's defect on this very sheet ("each read of daysOffReason decodes the Downbeat export,
    // so three reads is three of each, on every render") and #1731's on the Presenters one. The rule is
    // that a row must not pay a cost that belongs to the whole list, so the export is worked out once by
    // the section and handed down.
    @Test func noRowReadsTheExportForItself() throws {
        for row in ["bookedShootRow", "cancelledShootRow"] {
            let body = try #require(SourceGuardHelper.bodyOfFunction(named: row, in: sheet),
                                    "expected \(row)'s body")
            #expect(!body.contains("DownbeatBridge.loadedExport()"),
                    "\(row) decodes the whole export for one row; the section works it out once")
            #expect(!body.contains("CancelledShootEditing.cancelledIds(in: context)"),
                    "\(row) re-fetches the cancellations for one row")
            // The parameter is in the SIGNATURE, which `bodyOfFunction` deliberately does not return, so
            // this half is asked of the file.
            #expect(sheet.contains("func \(row)("), "\(row) must exist to be judged at all")
            #expect(sheet.contains("bookings: [OvertureBooking]"),
                    "\(row) must be HANDED the bookings, which is what makes the read above unnecessary")
        }
    }

    // And the section really does work them out once rather than leaving the reads to the computed
    // properties, which SwiftUI re-reads on every access.
    @Test func theSectionWorksThemOutOnceAndHandsThemDown() throws {
        let body = try #require(SourceGuardHelper.propertyBody("private var bookedShoots: some View {", in: sheet))
        #expect(body.contains("let cal = calendar"))
        #expect(body.contains("let bookings = DownbeatBridge.loadedExport().bookings"))
        #expect(body.contains("let cancelled = cancelledRows"))
        // Counted rather than merely present: one read is the fix, and a second one added later beside it
        // is the defect coming back in a form a `contains` check would not notice.
        #expect(body.components(separatedBy: "DownbeatBridge.loadedExport()").count - 1 == 1,
                "exactly one export read in the whole section")
    }

    // DEFECT 2. The "Booked shoots" heading counted the nights still blocked, and the section then drew
    // that list PLUS the shoots Dan had waved through, so after one cancellation the number said twelve
    // and thirteen rows followed it. A count is a promise about the rows beneath it (#863), and one
    // heading standing over two different lists cannot keep that promise.
    //
    // Asserted as "the waved-through rows are drawn under their own heading", which is the shape of the
    // fix, because the counts themselves are computed in the view and there is no value to compare.
    @Test func theWavedThroughShootsHaveTheirOwnHeadingAndCount() throws {
        let body = try #require(SourceGuardHelper.propertyBody("private var bookedShoots: some View {", in: sheet))
        #expect(body.contains("sectionHeading(\"Booked shoots\", systemImage: \"camera\", count: live.count)"),
                "the first number counts the live rows, which are what follow it")
        #expect(body.contains("sectionHeading(CancelledShootCopy.sectionTitle"),
                "the waved-through rows carry their own heading rather than sitting under the one above")
        #expect(body.contains("count: cancelled.count"),
                "and their own count, which is a promise about the rows under IT")

        // The ordering that makes it true: the second heading must come BEFORE its own ForEach and AFTER
        // the live one, or the rows are still under the wrong number.
        let liveHeading = try #require(body.range(of: "count: live.count"))
        let cancelledHeading = try #require(body.range(of: "sectionHeading(CancelledShootCopy.sectionTitle"))
        let cancelledRows = try #require(body.range(of: "ForEach(cancelled, id:"))
        #expect(liveHeading.upperBound < cancelledHeading.lowerBound)
        #expect(cancelledHeading.upperBound < cancelledRows.lowerBound)
    }
}
