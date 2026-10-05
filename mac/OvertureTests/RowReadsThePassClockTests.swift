import Testing
import Foundation

// #4357 slice G1 (the #4356 part 3 note): every surface that draws a queue row hands it the RENDER PASS's
// day and instant, never the wall clock read again while drawing. The row's badge, route list and authority
// gap judge staleness against that instant, and its draft review judges the date it names against that day,
// so a row whose clock is read at draw time can disagree with the card it is drawn from (L74).
//
// The six `QueueItem` members lost their wall clock defaults, so the compiler already refuses a row that
// passes nothing. What it cannot refuse is a call site passing `Date()` or the wall clock day explicitly,
// which is what this reads. Derived from the source rather than a list of call sites, so a third surface
// drawing rows joins the rule on its own (L96).
@Suite("A queue row is handed the render pass's clock (#4357 slice G1)")
struct RowReadsThePassClockTests {
    /// The argument list of each `ProspectRowFactory.row(` call up to its `prospects:` argument, which is
    /// where the clock arguments sit, in every app file that draws a row.
    static func clockArguments() -> [(file: String, arguments: String)] {
        AppSourceWalk.files(under: RepoRoot.app).flatMap { file -> [(file: String, arguments: String)] in
            file.text.components(separatedBy: "ProspectRowFactory.row(").dropFirst().compactMap { chunk in
                guard let end = chunk.range(of: "prospects:") else { return nil }
                return (file.name, String(chunk[..<end.lowerBound]))
            }
        }
    }

    @Test func everyRowIsHandedThePassClock() {
        let calls = Self.clockArguments()
        // The surfaces measured on 2026-10-04: the queue and the archive.
        #expect(calls.count >= 2, "found \(calls.count) row call site(s), so this measured nothing (L98)")
        for call in calls {
            #expect(call.arguments.contains("now:"), "\(call.file) draws a row without handing it an instant")
            #expect(!call.arguments.contains("Date()") && !call.arguments.contains("easternToday"),
                    Comment(rawValue: "\(call.file) hands a row the wall clock rather than the render pass's "
                            + "day and instant, so the row can judge staleness at a different moment from "
                            + "the card it draws."))
        }
    }
}
