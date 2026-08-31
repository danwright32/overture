import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #2261/#2267: the re-check control as it actually renders on a card, not merely as a decision a function
// returns. Logic in a SwiftUI view is untestable unless something exercises it, and this control is the
// only route to a paid lookup Dan starts from a row, so each of its states is proven to appear.
//
// What makes this worth a hosted test rather than another pure one: the states are chosen by
// `Reachability.recheckState`, which is already covered, but WHICH of them reaches the screen depends on
// the two run facts being threaded into the row. A break in that threading leaves every pure test green
// while the card shows a running label over nothing, or an enabled button that fails when pressed.
@Suite("The re-check control on a card (#2267)")
struct RecheckControlOnTheRowTests {

    // #3169: against the LIVE clock. `Reachability.recheckState` refuses a stale answer, and
    // ProspectRowView asks it with no `now`, so a pinned instant here is an answer that goes stale on
    // a date nobody chose: this one did, and five tests in this file went red on an untouched main.
    private let probedAt = LiveClockProbe.fresh

    private func item(probed: Bool = true, requestedAt: Date? = nil) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music",
                          venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                          sourceListingURL: "https://example.org/calendar",
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.presenter = "Aurora Strings"
        if probed {
            i.reachabilityProbedAt = probedAt
            i.reachabilityResult = .noEmailFound
        }
        i.reachabilityRecheckRequestedAt = requestedAt
        return i
    }

    private func texts(_ item: QueueItem, checkRunning: Bool = false,
                       probeRunning: Bool = false,
                       checkRunSince: Date? = nil, checkLookups: Int? = nil) throws -> [String] {
        let view = ProspectRowView(item: item, today: "2026-08-07", onKeep: {}, onDismiss: { _ in },
                                   checkRunning: checkRunning, probeRunning: probeRunning,
                                   checkRunSince: checkRunSince, checkLookups: checkLookups)
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // #3186: the label counts from the RUN and is judged by the run's DEPTH, and both halves are rendered
    // rather than asserted of a rule, because the row is where they were wrong.
    //
    // The control does not start a run: `requestReachabilityRecheck` sets a flag and the answer arrives
    // from whatever batch picks it up. So the label counted from the PRESS, which includes however long
    // the request waited, and judged that against a flat ten minutes, which #3137 established is a
    // per-round figure. A card could sit there saying a healthy deep run looked stuck, which is #1530's
    // defect and the one this family of warnings cannot afford (#2577, #2929).
    //
    // Against the LIVE clock, because `ProspectRowView` has no clock seam and reads the wall clock at
    // render time; the fixture is expressed relative to it for #3169's reason.
    private func runningRow(startedMinutesAgo: Double, pressedMinutesAgo: Double) -> QueueItem {
        var row = item(requestedAt: Date().addingTimeInterval(-pressedMinutesAgo * 60))
        row.reachabilityProbedAt = LiveClockProbe.fresh
        return row
    }

    @Test func aDeepRunPastTheOneRoundWindowIsNotCalledStuck() throws {
        let row = runningRow(startedMinutesAgo: 11, pressedMinutesAgo: 40)
        let t = try texts(row, probeRunning: true,
                          checkRunSince: Date().addingTimeInterval(-11 * 60), checkLookups: 30)
        #expect(t.contains { $0.contains(ReachabilityCopy.recheckRunning) })
        #expect(!t.contains { $0.contains("looks stuck") },
                "a 30 show check eleven minutes in is three rounds deep and running normally")
    }

    // The control, in the same fixture, so the negative above is not satisfied by a row that could never
    // have said it (L159). Same run, same elapsed time, with the size unknown: the flat one-round window
    // is all there is to judge by, and eleven minutes really is past it.
    @Test func theSameRunWithNoKnownSizeStillFallsBackToTheFlatWindow() throws {
        let row = runningRow(startedMinutesAgo: 11, pressedMinutesAgo: 40)
        let t = try texts(row, probeRunning: true,
                          checkRunSince: Date().addingTimeInterval(-11 * 60), checkLookups: nil)
        #expect(t.contains { $0.contains("looks stuck") })
    }

    // And the half that is about the CLOCK rather than the window: a request that waited half an hour for
    // a run to pick it up is judged from the run, not from the press. With the old reading this row was
    // forty minutes elapsed and stuck; with the run's own start it is one minute in.
    @Test func aLongWaitBeforeTheRunStartedIsNotCountedAgainstTheRun() throws {
        let row = runningRow(startedMinutesAgo: 1, pressedMinutesAgo: 40)
        let t = try texts(row, probeRunning: true,
                          checkRunSince: Date().addingTimeInterval(-60), checkLookups: nil)
        #expect(t.contains { $0.contains(ReachabilityCopy.recheckRunning) })
        #expect(!t.contains { $0.contains("looks stuck") })
    }

    // Nothing said when the run start is unknown, so the row is exactly as it was rather than silently
    // unmeasured: it falls back to the press, which is the reading that shipped.
    @Test func anUnknownRunStartFallsBackToThePress() throws {
        let row = runningRow(startedMinutesAgo: 0, pressedMinutesAgo: 40)
        let t = try texts(row, probeRunning: true, checkRunSince: nil, checkLookups: nil)
        #expect(t.contains { $0.contains("looks stuck") })
    }

    @Test func aFrozenAnswerOffersTheControl() throws {
        #expect(try texts(item()).contains { $0.contains(ReachabilityCopy.checkAgain) })
    }

    // A show no check has ever run over is served by the ordinary check control. Offering to run this one
    // "again" beside it would claim an answer exists.
    @Test func anUncheckedShowOffersNothing() throws {
        let t = try texts(item(probed: false))
        #expect(!t.contains { $0.contains(ReachabilityCopy.checkAgain) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.recheckOutstanding) })
    }

    // The state the threading exists for: a check really in flight for THIS show says so on the card.
    @Test func aShowInARunningCheckShowsItRunning() throws {
        let t = try texts(item(requestedAt: probedAt), probeRunning: true)
        #expect(t.contains { $0.contains(ReachabilityCopy.recheckRunning) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.recheckOutstanding) })
    }

    // A run that ended without reaching it must NOT keep claiming to be running, which would be a spinner
    // over work that is not happening. It says the question is outstanding and offers to try again.
    @Test func aRequestWithNoRunShowsItIsWaitingAndOffersARetry() throws {
        let t = try texts(item(requestedAt: probedAt), probeRunning: false)
        #expect(t.contains { $0.contains(ReachabilityCopy.recheckOutstanding) })
        #expect(t.contains { $0.contains(ReachabilityCopy.checkAgainRetry) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.recheckRunning) })
    }

    // A Prep run holds the same single slot, so the control must be unpressable, but the card must NOT
    // claim its own check is under way: nothing is happening for this show.
    @Test func aPrepRunGreysTheControlWithoutClaimingACheck() throws {
        let t = try texts(item(), checkRunning: true)
        #expect(t.contains { $0.contains(ReachabilityCopy.checkAgain) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.recheckRunning) })
    }

    // #2621: the card that names a specific fault and, until now, carried nothing to act on. Rendered
    // rather than asserted of the rule, because the fact it turns on (the unanswered mark) has to be
    // threaded into the row, and a break there leaves every pure test green while the badge sits alone.
    @Test func acardACheckMissedOffersTheControlBeneathItsBadge() throws {
        var missed = item(probed: false)
        missed.reachabilityUnansweredAt = probedAt

        let t = try texts(missed)

        #expect(t.contains { $0.contains(ReachabilityCopy.checkMissedItBadge) })
        #expect(t.contains { $0.contains(ReachabilityCopy.checkAgain) })
    }

    // And the hover text beside it stops teaching the wider route, which the card now covers itself.
    @Test func themissedBadgeNoLongerSendsHimToTheWholeDate() throws {
        var missed = item(probed: false)
        missed.reachabilityUnansweredAt = probedAt

        let t = try texts(missed)

        #expect(t.contains { $0.contains(ReachabilityCopy.checkMissedItHelp) })
        #expect(!t.contains { $0.contains("picking its date again") })
    }
}
