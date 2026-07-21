import Testing
import Foundation
@testable import Overture

// #1308 Layer 2 Phase 3: which shows on a date are worth an opt-in reachability check. Only still-open
// pre-commitment candidates count: a booked, sent, or drafted show is past the keep/dismiss moment, and an
// already-probed show already has its answer. The date-header "Check reachability" control appears only
// when two or more such candidates share a date (the whole value is comparing several).
@MainActor
@Suite("Reachability probe candidates (#1308)")
struct ReachabilityProbeCandidateTests {
    private func item(_ key: String, status: ReviewStatus = .new, booked: Bool = false,
                      sent: Bool = false, probed: Bool = false) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        if booked { i.performanceStatus = .booked }
        if sent { i.sentAt = Date(timeIntervalSince1970: 1_780_000_000) }
        if probed { i.reachabilityProbedAt = Date(timeIntervalSince1970: 1_780_000_000) }
        return i
    }

    @Test func onlyStillOpenUnprobedShowsAreCandidates() {
        let items = [
            item("a"),                              // new, open -> candidate
            item("b", status: .queued),             // kept, no draft -> candidate
            item("c", status: .drafted),            // already being pursued -> no
            item("d", sent: true),                  // already pitched -> no
            item("e", booked: true),                // booked -> no
            item("f", probed: true),                // freshly probed: has its answer -> no
        ]
        // `now` just after f's probe, so f is still fresh (not stale) and stays excluded.
        let now = Date(timeIntervalSince1970: 1_780_000_100)
        #expect(QueueModel.reachabilityProbeCandidateKeys(items, now: now) == ["a", "b"])
    }

    // #1332: a probe result that has aged past the freshness window shows Dan a "worth re-checking" badge
    // (#1325) telling him to run Check reachability again, so that stale show must become a candidate
    // AGAIN, or the advice points at a control that never includes it. A freshly probed show stays out.
    @Test func aStaleProbedShowBecomesACandidateAgainSoItCanBeRechecked() {
        let probedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var stale = item("s"); stale.reachabilityProbedAt = probedAt
        var fresh = item("t"); fresh.reachabilityProbedAt = probedAt

        let afterWindow = probedAt.addingTimeInterval(Reachability.probeFreshness + 1)
        #expect(QueueModel.reachabilityProbeCandidateKeys([stale], now: afterWindow) == ["s"])

        let withinWindow = probedAt.addingTimeInterval(1)
        #expect(QueueModel.reachabilityProbeCandidateKeys([fresh], now: withinWindow) == [])
    }

    @Test func theControlNeedsAtLeastTwoCandidates() {
        #expect(QueueModel.showsReachabilityProbeControl([item("a")]) == false)          // only one
        #expect(QueueModel.showsReachabilityProbeControl([item("a"), item("b")]) == true) // two
        #expect(QueueModel.showsReachabilityProbeControl([item("a", status: .drafted)]) == false)
    }
}
