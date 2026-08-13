import Testing
import Foundation

private func item(_ id: String) -> QueueItem {
    QueueItem(
        id: id, groupName: id, discipline: "music", venue: "Weill Recital Hall",
        performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
    )
}

// #1922: what a send is doing right now, off the view that derives the store.
@MainActor
@Suite("The state a send moves through (#1922)")
struct SendProgressStateTests {
    @Test func aSendInFlightCarriesTheMomentItStarted() {
        let state = SendProgressState()
        let started = Date(timeIntervalSince1970: 1_780_000_000)

        state.markSending("carnegie-2026-07-01", at: started)

        // The moment itself, not merely "something is happening": the row counts its elapsed time from it.
        #expect(state.sendingSince("carnegie-2026-07-01") == started)
        #expect(state.sendingSince("someone-else") == nil)
    }

    @Test func clearingASendLeavesEveryOtherSendAlone() {
        let state = SendProgressState()
        state.markSending("a")
        state.markSending("b")

        state.clearSending("a")

        #expect(state.sendingSince("a") == nil)
        #expect(state.sendingSince("b") != nil)
    }

    // A multi-contact show can have one reply going out while the others sit untouched, so these are
    // keyed per recipient rather than per show.
    @Test func repliesAreTrackedPerRecipient() {
        let state = SendProgressState()
        state.markReplySending("recipient-1")

        #expect(state.replySendingSince("recipient-1") != nil)
        #expect(state.replySendingSince("recipient-2") == nil)

        state.clearReplySending("recipient-1")
        #expect(state.replySendingSince("recipient-1") == nil)
    }

    // The send has already dropped the row from the store's answer, so the card playing the exit is this
    // snapshot or it is nothing at all.
    @Test func aDepartingShowKeepsTheRowItIsAboutToLoseWith() {
        let state = SendProgressState()
        let sent = item("carnegie-2026-07-01")

        state.depart("carnegie-2026-07-01", as: sent)
        #expect(state.isDeparting("carnegie-2026-07-01"))
        #expect(state.departing["carnegie-2026-07-01"]?.groupName == "carnegie-2026-07-01")

        state.finishDeparting("carnegie-2026-07-01")
        #expect(!state.isDeparting("carnegie-2026-07-01"))
        #expect(state.departing.isEmpty)
    }

    // Two jumps in quick succession: the first one's timer must not wipe the mark the second one just
    // put on a different show. Dan searches, lands, searches again within the couple of seconds the
    // first highlight lasts, and the row he just asked for goes unmarked.
    @Test func anOlderJumpsTimerCannotClearANewerJumpsMark() {
        let state = SendProgressState()
        state.highlight("first-show")
        state.highlight("second-show")

        state.clearHighlight(ifStill: "first-show")

        #expect(state.highlighted == "second-show")

        state.clearHighlight(ifStill: "second-show")
        #expect(state.highlighted == nil)
    }

    // #2417: a row leaves for two quite different reasons, and they must not look alike.
    //
    // A send earns the gold seal. An ending recorded from the close-out menu does not: "no response" and
    // "they passed" are the commonest of them, and celebrating those with the same seal reads as the app
    // congratulating Dan on a rejection. Gold is reserved for what he can act on.
    @Test func aDepartureCarriesWhyTheRowIsLeaving() {
        let state = SendProgressState()

        state.depart("sent-show", as: item("sent-show"), because: .sent)
        state.depart("closed-show", as: item("closed-show"), because: .closedOut)

        #expect(state.departureReason("sent-show") == .sent)
        #expect(state.departureReason("closed-show") == .closedOut)
        #expect(state.departureReason("never-departed") == nil)

        // Only the send gets the celebration, and this is asserted on the reason rather than on any
        // rendering of it, so it stays true of whatever the two rows are drawn as (L103).
        #expect(DepartureReason.sent.showsSendDelight)
        #expect(!DepartureReason.closedOut.showsSendDelight)
    }

    // The existing send path must keep working untouched, and keep its seal.
    @Test func aDepartureWithNoStatedReasonIsASend() {
        let state = SendProgressState()

        state.depart("carnegie-2026-07-01", as: item("carnegie-2026-07-01"))

        #expect(state.departureReason("carnegie-2026-07-01") == .sent)
    }

    // Finishing clears the reason with the snapshot. A reason left behind would make the NEXT departure
    // of that same show render as whatever the last one was, and the two look different on purpose.
    @Test func finishingADepartureClearsItsReasonToo() {
        let state = SendProgressState()
        state.depart("closed-show", as: item("closed-show"), because: .closedOut)

        state.finishDeparting("closed-show")

        #expect(state.departureReason("closed-show") == nil)
        #expect(!state.isDeparting("closed-show"))
    }

    // The one sentence the departing row says, out here where a test can read it. The row itself says
    // the show is leaving by going dim and sliding away, and neither of those is a word, so for a
    // screen reader this label is the whole of it.
    @Test func theClosedOutRowSaysWhichShowLeftAndWhy() {
        #expect(DepartureCopy.spokenClosedOut(showName: "Every Voice Choirs")
                == "Every Voice Choirs, closed out")
    }
}
