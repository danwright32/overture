import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #1308 Layer 2 Phase 3: the date-header "Check reachability" control. Verifies the button actually
// renders under the right conditions and that a tap reports exactly the date's candidate keys up to the
// caller (which opens the confirm sheet). Rendered directly through ViewInspector because the enclosing
// QueueView reads @Query/@State a unit test can't inject.
@MainActor
@Suite("Reachability probe control (#1308)")
struct ReachabilityProbeControlTests {
    private func item(_ key: String, status: ReviewStatus = .new) -> QueueItem {
        QueueItem(id: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                  performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
    }

    @Test func showsAndTapReportsTheCandidateKeys() throws {
        var tapped: (keys: [String], label: String)?
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b"), item("c", status: .drafted)],   // c is past keep/dismiss
            dateLabel: "Sep 12", isScout: false, isRunning: false,
            onTap: { keys, label in tapped = (keys, label) })

        let button = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        try button.tap()

        #expect(tapped?.keys == ["a", "b"])       // only the still-open candidates
        #expect(tapped?.label == "Sep 12")
    }

    // #1323: a probe and a normal Prep share the single detached-run slot, so tapping "Check
    // reachability" while a run is already in flight only fails after the fact. The control greys out
    // up front with a reason instead, the way other run-gated controls behave.
    @Test func disabledWhileARunIsInProgress() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isScout: false, isRunning: true,
            onTap: { _, _ in })

        let button = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        #expect(try button.isDisabled() == true)
    }

    @Test func enabledWhenNoRunIsInProgress() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isScout: false, isRunning: false,
            onTap: { _, _ in })

        let button = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        #expect(try button.isDisabled() == false)
    }

    @Test func hiddenOnTheScoutStage() throws {
        let view = ReachabilityProbeControl(items: [item("a"), item("b")], dateLabel: "Sep 12",
                                            isScout: true, isRunning: false, onTap: { _, _ in })
        #expect(throws: (any Error).self) {
            try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        }
    }

    @Test func hiddenWithFewerThanTwoCandidates() throws {
        let view = ReachabilityProbeControl(items: [item("a")], dateLabel: "Sep 12",
                                            isScout: false, isRunning: false, onTap: { _, _ in })
        #expect(throws: (any Error).self) {
            try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        }
    }
}
