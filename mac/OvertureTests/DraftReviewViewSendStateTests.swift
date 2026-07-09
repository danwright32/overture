import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #470: demonstrates the ViewInspector harness on a real consumer, not just LiveRunLabel in
// isolation, proving the QueueView outboundSending state -> DraftReviewView prop -> rendered
// branch link end to end (the exact gap the issue named).
@MainActor
@Suite("DraftReviewView send state (#470)")
struct DraftReviewViewSendStateTests {
    private func approvedItem() -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi", hasPendingRecipient: true)
    }

    @Test func noOutboundSendShowsTheSendButton() throws {
        let view = DraftReviewView(item: approvedItem(), onApprove: {}, onUnapprove: {}, onSkip: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        _ = try view.inspect().find(button: "Send")   // throws (fails the test) if not present
    }

    @Test func anInFlightOutboundSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let view = DraftReviewView(item: approvedItem(), onApprove: {}, onUnapprove: {}, onSkip: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: since)

        #expect((try? view.inspect().find(button: "Send")) == nil)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }
}
