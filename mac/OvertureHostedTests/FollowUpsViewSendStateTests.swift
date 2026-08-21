import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #710: retrofits the #470 ViewInspector harness onto FollowUpsView, the second of the three
// consumers that issue named. `row`/`conversationRow` used to read `self.sending[r.id]` directly
// (a @State property, not settable from outside a view instance), so they're refactored to take
// `since: Date?` explicitly, the same prop-threading shape DraftReviewView/ProspectRowView already
// use, making them directly testable without needing to fight @State from outside the view.
@MainActor
@Suite("FollowUpsView send state (#710)")
struct FollowUpsViewSendStateTests {
    private func prospectAndRecipient() -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        let r = Recipient(id: "act@example.com", email: "act@example.com", name: "Emma", provenance: .act)
        r.sendState = .sent
        return (p, r)
    }

    @Test func aRowWithNoInFlightSendShowsTheNudgeButton() throws {
        let (p, r) = prospectAndRecipient()
        let view = FollowUpsView()
        let d = FollowUp.DueRecipient(prospect: p, recipient: r)

        _ = try view.row(d, since: nil, sourceCalendars: [:]).inspect().find(button: SendConfirmCopy.openReview)
    }

    @Test func aRowWithAnInFlightSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let (p, r) = prospectAndRecipient()
        let view = FollowUpsView()
        let d = FollowUp.DueRecipient(prospect: p, recipient: r)
        let since = Date(timeIntervalSince1970: 1000)

        #expect((try? view.row(d, since: since, sourceCalendars: [:]).inspect().find(button: SendConfirmCopy.openReview)) == nil)
        let texts = try view.row(d, since: since, sourceCalendars: [:]).inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }

    // #2710: two tests stood here, covering the closing-note row's send button and its in-flight label.
    // Both are gone with the email: after the show there is no send, only a close-out menu, which
    // `NoClosingNoteAfterTheShowTests` covers at the level the decision lives at.
}
