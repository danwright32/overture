import Testing
import Foundation
@testable import Overture

private func item(status: ReviewStatus = .new, performanceStatus: PerformanceStatus = .new, key: String = "k") -> QueueItem {
    var q = QueueItem(
        id: key, groupName: "Test Group", discipline: "music", venue: "Weill Recital Hall",
        performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status
    )
    q.performanceStatus = performanceStatus
    return q
}

@Suite("ArchiveStatus")
struct ArchiveStatusTests {
    @Test func dismissedTakesPrecedenceOverPerformanceStatus() {
        // A prospect cut at triage is always performanceStatus .new (never contacted), but Archive
        // must bucket it as Dismissed, not New, so it is hidden by the New+Active default filter.
        let i = item(status: .dismissed, performanceStatus: .new)
        #expect(ArchiveStatus.of(i) == .dismissed)
    }

    @Test func nonDismissedMapsDirectlyFromPerformanceStatus() {
        #expect(ArchiveStatus.of(item(status: .new, performanceStatus: .new)) == .new)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .active)) == .active)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .lostDoorOpen)) == .lostDoorOpen)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .lostNotInterested)) == .lostNotInterested)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .booked)) == .booked)
    }

    @Test func labelsAreDistinctPlainLanguage() {
        #expect(ArchiveStatus.lostDoorOpen.label == "Closed (not now)")
        #expect(ArchiveStatus.lostNotInterested.label == "Closed (not interested)")
        #expect(ArchiveStatus.dismissed.label == "Dismissed")
    }
}
