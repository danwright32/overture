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

    // #1336: the control is a proactive first-party CALLOUT, not a passive button Dan must remember. It
    // names how many shows compete for the date so he checks which are emailable before he keeps one.
    @Test func theCalloutHeadlineNamesTheCountAndTheAsk() {
        let headline = ReachabilityProbeCopy.calloutHeadline(count: 3)
        #expect(headline.contains("3"))
        #expect(headline.lowercased().contains("email"))
    }

    @Test func showsAProactiveCalloutNamingTheCompetingCount() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b"), item("c")],   // 3 still-open candidates
            dateLabel: "Sep 12", isScout: false, isRunning: false, onTap: { _, _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("3 shows") })
        _ = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)   // Check button present
    }

    // #1336: a session dismiss (the X) waves the callout off for that date without checking.
    @Test func aDismissedDateHidesTheCallout() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isScout: false, isRunning: false,
            isDismissed: true, onDismiss: {}, onTap: { _, _ in })
        #expect(throws: (any Error).self) {
            try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        }
    }

    @Test func tappingDismissReportsUp() throws {
        var dismissed = false
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isScout: false, isRunning: false,
            isDismissed: false, onDismiss: { dismissed = true }, onTap: { _, _ in })

        let x = try view.inspect().find(ViewType.Button.self, where: {
            (try? $0.accessibilityIdentifier()) == "dismiss-reachability-callout"
        })
        try x.tap()
        #expect(dismissed == true)
    }
}
