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

    // #675: the lightweight row (#661) dropped the delivery-delay hint the embedded DraftReviewView
    // used to show (#656) for a recipient in this same pipeline. Must reuse hasRecentDeliveryDelay
    // rather than reimplementing the fade-window check, so the two can't drift apart (#656/#675).
    @Test func rowReusesTheSharedDeliveryDelayCheck() throws {
        let src = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: src)
        #expect(body.contains("hasRecentDeliveryDelay("),
                "reachedOutRow doesn't surface the soft-delay hint via the shared hasRecentDeliveryDelay check (#675).")
    }
}
