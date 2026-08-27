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
                  performanceDate: "2026-09-12", sourceListingURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
    }

    @Test func showsAndTapReportsTheCandidateKeys() throws {
        var tapped: (keys: [String], label: String)?
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b"), item("c", status: .drafted)],   // c is past keep/dismiss
            dateLabel: "Sep 12", isRunning: false,
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
            items: [item("a"), item("b")], dateLabel: "Sep 12", isRunning: true,
            onTap: { _, _ in })

        let button = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        #expect(try button.isDisabled() == true)
    }

    @Test func enabledWhenNoRunIsInProgress() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isRunning: false,
            onTap: { _, _ in })

        let button = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        #expect(try button.isDisabled() == false)
    }

    // #1595 replaces what used to be hiddenOnTheScoutStage and hiddenWithFewerThanTwoCandidates. Both
    // asserted exactly the behaviour that made this feature unreachable: it was blocked on the stage Dan
    // triages, and it demanded a second show before it would offer to check anything. Between them the
    // control had never appeared once (#1585). It now renders on any date holding a candidate.

    // Dan's call after walking the Debug build (2026-07-27): the callout was too heavy on every date. No
    // green box, no envelope icon, no sentence, no dismiss X. Just the Check reachability button, right
    // aligned. The stale case loses nothing by this: the ROW already carries its own amber "Reachability
    // may be out of date" badge, so the callout was saying it a second time (#843).
    @Test func rendersNothingButTheButton() throws {
        var stale = item("s"); stale.reachabilityProbedAt = Date(timeIntervalSince1970: 1_000_000)
        for items in [[item("a")], [item("a"), item("b"), item("c")], [stale]] {
            let view = ReachabilityProbeControl(items: items, dateLabel: "Sep 12",
                                                isRunning: false, onTap: { _, _ in })
            // Empty strings are SwiftUI's own (the idle .help tooltip), not anything Dan reads, so the
            // assertion is about VISIBLE copy: the button label and nothing else.
            let texts = try view.inspect().findAll(ViewType.Text.self)
                .map { try $0.string() }.filter { !$0.isEmpty }
            #expect(texts == [ReachabilityProbeCopy.controlLabel])
            #expect(try view.inspect().findAll(ViewType.Image.self).isEmpty)
        }
    }

    @Test func rendersOnASingleShowDate() throws {
        let view = ReachabilityProbeControl(items: [item("a")], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        _ = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
    }

    // Dan's call (2026-07-26): a lone show nobody has checked gets the button and NO sentence. There is
    // nothing to compare on a one-show night, so a headline would only restate the row beneath it, and it
    // must never say "re-check" about a show that was never checked.
    @Test func aLoneNeverProbedShowGetsNoHeadline() throws {
        let view = ReachabilityProbeControl(items: [item("a")], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.lowercased().contains("re-check") })
        #expect(!texts.contains { $0.contains("compete") })
        #expect(!texts.contains { $0.contains("1 show") })
    }

    @Test func hiddenWhenNoShowOnTheDateIsStillOpen() throws {
        let view = ReachabilityProbeControl(items: [item("a", status: .drafted)], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        #expect(throws: (any Error).self) {
            try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        }
    }

    // #1334 asked this to render a re-check SENTENCE. Dan removed every sentence from the control
    // (2026-07-27), so what matters now is that a lone stale show still gets its button: its row badge
    // tells him the earlier answer aged out, and this is the control that acts on that.
    @Test func aLoneStaleShowStillGetsTheButton() throws {
        var stale = item("s"); stale.reachabilityProbedAt = Date(timeIntervalSince1970: 1_000_000)
        let view = ReachabilityProbeControl(items: [stale], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        _ = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
    }

    @Test func showsAProactiveCalloutNamingTheCompetingCount() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b"), item("c")],   // 3 still-open candidates
            dateLabel: "Sep 12", isRunning: false, onTap: { _, _ in })

        _ = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)   // Check button present
    }

    // #1336's session dismiss (the X) is GONE, and with it aDismissedDateHidesTheCallout and
    // tappingDismissReportsUp. Dan cut the X when he walked the build (2026-07-27): with the callout
    // reduced to a bare button there is nothing to wave off, and a control that hides itself is worse than
    // one that is quiet. The date resolving out of candidacy is what makes it disappear now.
}
