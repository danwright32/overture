import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #710: retrofits the #470 ViewInspector harness onto ProspectRowView (the QueueView row), the
// first of the three consumers that issue named. Two real branches worth proving beyond what
// DraftReviewViewSendStateTests already covers for DraftReviewView's OWN internals: whether the
// row shows the nested DraftReviewView at all (gated on item.hasDraft), and whether
// outboundSendSince actually threads all the way from the row down into a rendered "Sending"
// state, not just into DraftReviewView directly.
@MainActor
@Suite("ProspectRowView send state (#710)")
struct ProspectRowViewSendStateTests {
    private func approvedItemWithDraft() -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi", hasPendingRecipient: true)
    }

    // #710 regression-check finding: an item that is both hasDraft == false AND status != .approved
    // would pass this test even if the row's own `if item.hasDraft` gate were completely removed,
    // since DraftReviewView's OWN internal isApproved gate would still hide the Send button,
    // masking the row-level regression this test exists to catch. Isolate the row's gate
    // specifically by giving this item every OTHER condition DraftReviewView's Send button
    // needs (status == .approved) except a draft, a combination that can't occur in the live app
    // (Dan can't approve a show with no draft) but is exactly what proves THIS gate in isolation.
    private func approvedItemWithNoDraft() -> QueueItem {
        QueueItem(id: "k2", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, hasPendingRecipient: true)
    }

    @Test func aRowWithNoDraftShowsNoSendButtonAtAll() throws {
        let view = ProspectRowView(item: approvedItemWithNoDraft(), today: "2026-07-09", onKeep: {}, onDismiss: { _ in })

        #expect((try? view.inspect().find(button: "Send")) == nil)
    }

    @Test func aRowWithADraftAndNoInFlightSendShowsTheSendButton() throws {
        let view = ProspectRowView(item: approvedItemWithDraft(), today: "2026-07-09", onKeep: {}, onDismiss: { _ in },
                                   outboundSendSince: nil)

        _ = try view.inspect().find(button: "Send")   // throws (fails the test) if not present
    }

    // The end-to-end integration check: proves the prop actually threads ProspectRowView ->
    // DraftReviewView -> LiveRunLabel, not just that DraftReviewView does the right thing when
    // handed the prop directly (already covered by DraftReviewViewSendStateTests).
    @Test func aRowWithAnInFlightOutboundSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let view = ProspectRowView(item: approvedItemWithDraft(), today: "2026-07-09", onKeep: {}, onDismiss: { _ in },
                                   outboundSendSince: since)

        #expect((try? view.inspect().find(button: "Send")) == nil)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }
}
