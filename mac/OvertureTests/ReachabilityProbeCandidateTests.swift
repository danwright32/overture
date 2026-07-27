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

    // #1595: `showsReachabilityProbeControl` is GONE. The control now renders wherever there is at least
    // one candidate, on every Scout date, because a lone promising show on a quiet night is exactly the
    // case Dan could not check before (#1585). What survives is the HEADLINE choice, which is all
    // `usesStaleRecheckHeadline` decides now: it no longer gates whether the control appears, only which
    // of two sentences it carries. A lone never-probed show gets NO headline at all, by Dan's call
    // (2026-07-26): on a one-show night there is nothing to compare, so the sentence has no work to do.
    @Test func aLoneStaleShowUsesTheRecheckHeadline() {
        let probedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let afterWindow = probedAt.addingTimeInterval(Reachability.probeFreshness + 1)
        let withinWindow = probedAt.addingTimeInterval(1)
        var stale = item("s"); stale.reachabilityProbedAt = probedAt

        #expect(QueueModel.usesStaleRecheckHeadline([stale], now: afterWindow) == true)

        // A lone never-probed show is still a candidate (the control shows), but it is not a re-check, so
        // it must not be told to "re-check" something that was never checked.
        #expect(QueueModel.usesStaleRecheckHeadline([item("a")], now: afterWindow) == false)
        #expect(QueueModel.reachabilityProbeCandidateKeys([item("a")], now: afterWindow) == ["a"])

        // A lone freshly probed show has its answer, so it is not a candidate and nothing renders.
        #expect(QueueModel.usesStaleRecheckHeadline([stale], now: withinWindow) == false)
        #expect(QueueModel.reachabilityProbeCandidateKeys([stale], now: withinWindow) == [])

        // Two open candidates is the comparison case, not a lone re-check.
        #expect(QueueModel.usesStaleRecheckHeadline([item("a"), item("b")], now: afterWindow) == false)

        // A booked sibling on the same date is not a candidate, so a lone stale show beside it still counts
        // as a lone re-check, not a comparison.
        var staleBesideBooked = item("s2"); staleBesideBooked.reachabilityProbedAt = probedAt
        #expect(QueueModel.usesStaleRecheckHeadline([staleBesideBooked, item("x", booked: true)],
                                                    now: afterWindow) == true)
    }
}
