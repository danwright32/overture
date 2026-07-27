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

    // #1595 / #1587: candidacy now comes from the shared OpenForDecision predicate, so this list and the
    // Scout list Dan triages cannot answer "is he still deciding" differently. Two changes from #1308:
    // a KEPT show is no longer a candidate (it is past the keep-or-dismiss moment, and Prep is about to
    // find its contact anyway), and a run that has already OPENED is no longer a candidate (the Scout list
    // drops it, so paying to research it would be money on a show Overture refuses to display).
    @Test func onlyStillOpenUnprobedShowsAreCandidates() {
        let items = [
            item("a"),                              // new, open -> candidate
            item("b", status: .queued),             // KEPT: past the decision -> no longer a candidate
            item("c", status: .drafted),            // already being pursued -> no
            item("d", sent: true),                  // already pitched -> no
            item("e", booked: true),                // booked -> no
            item("f", probed: true),                // freshly probed: has its answer -> no
        ]
        // `now` just after f's probe, so f is still fresh (not stale) and stays excluded.
        let now = Date(timeIntervalSince1970: 1_780_000_100)
        #expect(QueueModel.reachabilityProbeCandidateKeys(items, now: now, today: "2026-09-01") == ["a"])
    }

    @Test func aRunThatHasAlreadyOpenedIsNotACandidate() {
        // The show opens on 2026-09-12; today is after it, so the run is underway and Dan will not pitch
        // it. The Scout list already drops it (#1540); this rule used to keep offering to pay for it.
        #expect(QueueModel.reachabilityProbeCandidateKeys([item("a")],
                                                          now: Date(timeIntervalSince1970: 1_780_000_100),
                                                          today: "2026-09-20") == [])
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

    // #1595, then Dan's walk (2026-07-27): both the visibility rule and the headline selector are gone.
    // The control renders wherever there is a candidate and shows nothing but its button, so all that is
    // left to assert here is candidacy itself. A stale result still surfaces on the ROW badge, tested in
    // ReachabilityTests.
    // A booked sibling on the date is not a candidate, so it neither adds to the count nor keeps the
    // control alive on a date whose only open show has been answered.
    @Test func aBookedSiblingIsNotACandidate() {
        #expect(QueueModel.reachabilityProbeCandidateKeys(
            [item("a"), item("x", booked: true)],
            now: Date(timeIntervalSince1970: 1_780_000_100)) == ["a"])
    }
}
