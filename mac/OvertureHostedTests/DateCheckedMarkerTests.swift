import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #1617: a Scout date whose shows have ALL been answered drew a bare heading. No Check button (there was
// nothing left to check), no tick box (same reason), and nothing saying why, so the one date Dan had
// finished looked exactly like the feature being broken. He read it that way walking the Debug build on
// 2026-07-31.
//
// The marker claims only what it measured. A date can be bare for reasons that have nothing to do with
// having been checked (nothing on it is still open, everything on it is somewhere Dan refuses to travel),
// and saying "Reachability checked" there would be a sentence the code never verified.
@MainActor
@Suite("Date fully checked marker (#1617)")
struct DateCheckedMarkerTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_100)
    private let today = "2026-09-01"

    private func item(_ key: String, status: ReviewStatus = .new, discipline: String = "music",
                      location: String? = nil, date: String = "2026-09-12") -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: discipline, venue: "Weill Recital Hall",
                          performanceDate: date, sourceListingURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        i.location = location
        return i
    }

    // Its own fresh answer: what a check on this very show produced.
    private func probed(_ key: String, status: ReviewStatus = .new, at: Date? = nil) -> QueueItem {
        var i = item(key, status: status)
        i.reachabilityProbedAt = at ?? now.addingTimeInterval(-60)
        i.reachabilityResult = .emailFound
        return i
    }

    // #1598 Phase 5: an answer paid for on another show by the same organisation. The card already prints
    // it, so the date is answered too.
    private func inherited(_ key: String) -> QueueItem {
        var i = item(key)
        i.inheritedReachability = OrgAnswerLedger.Inherited(result: .emailFound,
                                                           probedAt: now.addingTimeInterval(-60),
                                                           organisation: "A Presenter",
                                                           emails: ["hello@example.com"])
        return i
    }

    @Test func aDateWhoseOpenShowsAreAllAnsweredIsMarkedChecked() {
        #expect(QueueModel.dateReachabilityIsFullyChecked([probed("a"), probed("b")],
                                                          now: now, today: today))
    }

    @Test func anInheritedAnswerCountsAsChecked() {
        #expect(QueueModel.dateReachabilityIsFullyChecked([inherited("a")], now: now, today: today))
    }

    // The button is what belongs on this date, not the marker: something on it is still worth checking.
    @Test func aDateWithOneRemainingCandidateIsNotMarkedChecked() {
        #expect(!QueueModel.dateReachabilityIsFullyChecked([probed("a"), item("b")],
                                                            now: now, today: today))
    }

    // A stale answer becomes a candidate again (#1332), so the date is back to offering its button.
    @Test func aStaleAnswerIsNotChecked() {
        let old = now.addingTimeInterval(-(Reachability.probeFreshness + 1))
        #expect(!QueueModel.dateReachabilityIsFullyChecked([probed("s", at: old)], now: now, today: today))
    }

    // The bare heading Dan met is not always a finished date. A night holding only shows he is past
    // deciding about has no candidates and no answers of its own, and must claim nothing.
    @Test func aDateWithNothingStillOpenClaimsNothing() {
        for status in [ReviewStatus.queued, .drafted, .approved] {
            #expect(!QueueModel.dateReachabilityIsFullyChecked([probed("a", status: status)],
                                                                now: now, today: today),
                    "a show past the keep-or-dismiss moment was never the thing this marker is about")
        }
    }

    // The other false claim: a theater show up the line is bare because Overture refuses to travel there
    // (#1609), never because anyone checked it. Both halves, so the test fails if the refusals stop
    // reaching this rule.
    @Test func aShowOutOfRangeIsNotSomethingWeChecked() {
        let show = [item("refused", discipline: "theater", location: "Larchmont, NY")]
        let refusals = GeoRefusals(userExcludedTowns: ["larchmont"])
        #expect(!QueueModel.dateReachabilityIsFullyChecked(show, now: now, today: today, geo: refusals),
                "an unchecked show he will not travel to must never read as checked")

        var answered = show[0]
        answered.reachabilityProbedAt = now.addingTimeInterval(-60)
        #expect(!QueueModel.dateReachabilityIsFullyChecked([answered], now: now, today: today,
                                                            geo: refusals),
                "and neither does an old answer on a show he has since refused")
        #expect(QueueModel.dateReachabilityIsFullyChecked([answered], now: now, today: today),
                "without the refusal it is a plain answered show")
    }

    @Test func anEmptyDateClaimsNothing() {
        #expect(!QueueModel.dateReachabilityIsFullyChecked([], now: now, today: today))
    }

    // The marker lands in the slot the Check button would have used, so Dan finds an answer exactly where
    // he looked for the control. Rendered through the real view: the helper being right is a separate
    // claim from the view actually showing it (#863).
    @Test func theMarkerRendersWhereTheButtonWouldHaveBeen() throws {
        // A date far enough out to still be open on any day this suite runs, and an answer taken just now,
        // because the view asks with the real clock.
        var answered = item("a", date: "2099-09-12")
        answered.reachabilityProbedAt = Date()
        let view = ReachabilityProbeControl(items: [answered], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self)
            .map { try $0.string() }.filter { !$0.isEmpty }
        #expect(texts == [ReachabilityProbeCopy.dateCheckedMarker])
        #expect(throws: (any Error).self) {
            try view.inspect().find(button: ReachabilityProbeCopy.controlLabel)
        }
    }

    // A date with a candidate still gets the button and NOT the marker: two claims that must never
    // appear together.
    @Test func aDateWithWorkLeftShowsTheButtonAndNoMarker() throws {
        let open = item("a", date: "2099-09-12")
        let view = ReachabilityProbeControl(items: [open], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        let texts = try view.inspect().findAll(ViewType.Text.self)
            .map { try $0.string() }.filter { !$0.isEmpty }
        #expect(texts == [ReachabilityProbeCopy.controlLabel])
    }

    // Nothing open on the date: the heading stays bare, because there is nothing true to say.
    @Test func aDateWithNothingOpenStillRendersNothing() throws {
        var done = item("a", status: .drafted, date: "2099-09-12")
        done.reachabilityProbedAt = Date()
        let view = ReachabilityProbeControl(items: [done], dateLabel: "Sep 12",
                                            isRunning: false, onTap: { _, _ in })
        let texts = try view.inspect().findAll(ViewType.Text.self)
            .map { try $0.string() }.filter { !$0.isEmpty }
        #expect(texts.isEmpty)
    }
}
