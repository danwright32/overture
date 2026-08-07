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
@MainActor
@Suite("The re-check control on a card (#2267)")
struct RecheckControlOnTheRowTests {

    private let probedAt = Date(timeIntervalSince1970: 1_780_000_000)

    private func item(probed: Bool = true, requestedAt: Date? = nil) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music",
                          venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                          sourceListingURL: "https://example.org/calendar", websiteURL: nil,
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

    private func texts(_ item: QueueItem, prepRunning: Bool = false,
                       probeRunning: Bool = false) throws -> [String] {
        let view = ProspectRowView(item: item, today: "2026-08-07", onKeep: {}, onDismiss: { _ in },
                                   prepRunning: prepRunning, probeRunning: probeRunning)
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
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
        let t = try texts(item(), prepRunning: true)
        #expect(t.contains { $0.contains(ReachabilityCopy.checkAgain) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.recheckRunning) })
    }
}
