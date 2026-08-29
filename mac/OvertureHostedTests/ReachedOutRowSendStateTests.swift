import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2644: Dan pressed the button to send a closing note on a show whose performance had passed. Nothing
// on screen changed, and about a second later the row simply vanished. His words: "at first I thought it
// didn't work."
//
// The send was running during that second and nothing said so. `performRowNudge` clears
// `pendingRowNudge` on its first line, so the sheet closes at once, and then starts the async Gmail
// send; until it returns the row underneath is unchanged, showing the same button. The whole gap between
// press and result was indistinguishable from a dead button, which is the state a person answers by
// pressing again (L44).
//
// The state already existed: the send calls `sendState.markSending` and `clearSending`, and nothing
// rendered it. This is the reader (L46), and it is the same `LiveRunLabel` the Review card and the
// Follow-ups rows have had since #710. The closing note sent from Follow-ups showed "Sending"; the same
// closing note sent from the queue showed nothing, and the queue is where Dan works.
@MainActor
@Suite("The reached-out row's send state (#2644)")
struct ReachedOutRowSendStateTests {

    // A show that was pitched and whose night has passed, which is the row that offers a closing note.
    private func pitched() -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-01",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        let r = Recipient(id: "act@example.com", email: "act@example.com", name: "Emma", provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1_000_000)
        p.setRecipients([r])
        p.sentAt = r.sentAt
        return (p, r)
    }

    private func row(since: Date?) -> some View {
        let (p, r) = pitched()
        return QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
            .reachedOutRow((prospect: p, recipient: r, next: Date()), now: Date(), since: since,
                           sourceCalendars: [:])
    }

    private func texts(_ view: some View) -> [String] {
        ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
    }

    // The defect: pressing Send left the row exactly as it was for the whole send. Now the words appear.
    @Test func aSendInFlightPutsAWorkingStateOnTheRow() {
        #expect(texts(row(since: Date(timeIntervalSince1970: 1000))).contains { $0.hasPrefix("Sending") })
    }

    // And the row says nothing of the sort at rest, or every reached-out row would claim to be sending.
    @Test func aRowWithNothingInFlightSaysNothingAboutSending() {
        #expect(!texts(row(since: nil)).contains { $0.hasPrefix("Sending") })
    }

    // The row still says who and what it always said, so the working state is an addition rather than a
    // replacement for the row Dan reads.
    @Test func theRowStillNamesItsShowWhileSending() {
        #expect(texts(row(since: Date(timeIntervalSince1970: 1000))).contains("Aurora Strings"))
    }
}
