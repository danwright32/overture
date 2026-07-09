import Testing
import Foundation

// #661 follow-up: the lightweight reached-out row must color an overdue reach-out in rust, the
// same urgency cue the old full show card gave it, rather than the plain color used for a future
// "in N days" timing. Source-guarded since QueueView's row isn't directly invokable in a test.
@Suite("Reached-out row urgency color")
struct ReachedOutRowGuardTests {
    @Test func rowColorsTheTimingTextByDueNow() throws {
        let src = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: src)
        #expect(body.contains("ReachedOutQueue.isDueNow("),
                "reachedOutRow no longer checks isDueNow to decide the timing text's color (#661).")
        #expect(body.contains("OVColor.rust"),
                "reachedOutRow lost the rust urgency color for an overdue reach-out (#661).")
    }
}
