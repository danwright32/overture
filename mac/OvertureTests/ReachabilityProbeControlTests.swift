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

    // #1334: a single show whose earlier probe has gone stale still renders the callout, but with the
    // re-check headline (not the "N shows compete" comparison framing), and the Check button to run it.
    // The probe date is long past, so it is stale against the wall clock the view reads whenever this runs.
    @Test func aLoneStaleShowRendersTheRecheckCallout() throws {
        var stale = item("s"); stale.reachabilityProbedAt = Date(timeIntervalSince1970: 1_000_000)
        let view = ReachabilityProbeControl(items: [stale], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.lowercased().contains("re-check") })      // action-framed re-check headline
        #expect(!texts.contains { $0.contains("compete") })                   // not the comparison headline
        _ = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)   // Check button present
    }

    // #1334: the lone re-check copy leads with the action (the row's own badge already states the stale
    // condition, #843) and reads for ONE show (not "these 1 shows"); the comparison copy for two or more is
    // unchanged.
    @Test func theLoneRecheckCopyReadsForOneShow() {
        #expect(ReachabilityProbeCopy.staleRecheckHeadline.lowercased().contains("re-check"))
        #expect(!ReachabilityProbeCopy.staleRecheckHeadline.lowercased().contains("out of date"))
        #expect(ReachabilityProbeCopy.confirmTitle(count: 1) == "Check reachability for this show?")
        #expect(ReachabilityProbeCopy.confirmTitle(count: 3) == "Check reachability for these 3 shows?")
    }

    // #1336: the control is a proactive first-party CALLOUT, not a passive button Dan must remember. It
    // names how many shows compete for the date so he checks which are emailable before he keeps one.
    @Test func theCalloutHeadlineNamesTheCountAndTheAsk() {
        let headline = ReachabilityProbeCopy.calloutHeadline(count: 3)
        #expect(headline.contains("3"))
        #expect(headline.lowercased().contains("email"))
    }

    // #1595: the comparison headline is only ever used for two or more, so it never has to read for one.
    // Dropping the old 2-or-more gate without this would have printed "1 shows compete for this date" on
    // 54 of Dan's 169 dates. The single-show case renders no headline at all, asserted above.
    @Test func theComparisonHeadlineIsNeverAskedToReadForOneShow() throws {
        let view = ReachabilityProbeControl(items: [item("a")], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("1 shows") })
    }

    @Test func showsAProactiveCalloutNamingTheCompetingCount() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b"), item("c")],   // 3 still-open candidates
            dateLabel: "Sep 12", isRunning: false, onTap: { _, _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("3 shows") })
        _ = try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)   // Check button present
    }

    // #1336: a session dismiss (the X) waves the callout off for that date without checking.
    @Test func aDismissedDateHidesTheCallout() throws {
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isRunning: false,
            isDismissed: true, onDismiss: {}, onTap: { _, _ in })
        #expect(throws: (any Error).self) {
            try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        }
    }

    @Test func tappingDismissReportsUp() throws {
        var dismissed = false
        let view = ReachabilityProbeControl(
            items: [item("a"), item("b")], dateLabel: "Sep 12", isRunning: false,
            isDismissed: false, onDismiss: { dismissed = true }, onTap: { _, _ in })

        let x = try view.inspect().find(ViewType.Button.self, where: {
            (try? $0.accessibilityIdentifier()) == "dismiss-reachability-callout"
        })
        try x.tap()
        #expect(dismissed == true)
    }
}
