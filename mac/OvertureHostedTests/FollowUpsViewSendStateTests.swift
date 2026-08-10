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

        _ = try view.row(d, since: nil).inspect().find(button: "Send nudge")
    }

    @Test func aRowWithAnInFlightSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let (p, r) = prospectAndRecipient()
        let view = FollowUpsView()
        let d = FollowUp.DueRecipient(prospect: p, recipient: r)
        let since = Date(timeIntervalSince1970: 1000)

        #expect((try? view.row(d, since: since).inspect().find(button: "Send nudge")) == nil)
        let texts = try view.row(d, since: since).inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }

    // #2397: the post-event closing note is the conversation track's only remaining send, so this is the
    // row whose in-flight state has to be visible.
    @Test func aClosingNoteRowWithNoInFlightSendShowsTheSendButton() throws {
        let (p, r) = prospectAndRecipient()
        let view = FollowUpsView()
        let prompt = PostEventPrompt.Prompt(kind: .closingNote,
                                           reason: PostEventPrompt.reason(for: .closingNote))
        let d = PostEventPrompt.DueRecipient(prospect: p, recipient: r, prompt: prompt)

        _ = try view.postEventRow(d, since: nil).inspect().find(button: "Send closing note")
    }

    @Test func aClosingNoteRowWithAnInFlightSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let (p, r) = prospectAndRecipient()
        let view = FollowUpsView()
        let prompt = PostEventPrompt.Prompt(kind: .closingNote,
                                           reason: PostEventPrompt.reason(for: .closingNote))
        let d = PostEventPrompt.DueRecipient(prospect: p, recipient: r, prompt: prompt)
        let since = Date(timeIntervalSince1970: 1000)

        #expect((try? view.postEventRow(d, since: since).inspect().find(button: "Send closing note")) == nil)
        let texts = try view.postEventRow(d, since: since).inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }
}
