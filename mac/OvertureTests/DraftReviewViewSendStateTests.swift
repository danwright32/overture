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

// #407: a draft still carrying an old, un-strippable inline greeting shows Dan a plain warning
// (no dismiss action; this is a fact about the stored text, not an AI guess he can override).
// #718: he CAN override the block itself (a distinct, deliberate action), which the warning then
// reflects in a toned-down form rather than disappearing entirely.
@MainActor
@Suite("DraftReviewView salutation review warning (#407, #718)")
struct DraftReviewViewSalutationReviewTests {
    private func item(draftNeedsSalutationReview: Bool, overridden: Bool = false) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi",
                 hasPendingRecipient: !draftNeedsSalutationReview || overridden,
                 draftNeedsSalutationReview: draftNeedsSalutationReview,
                 salutationReviewOverridden: overridden)
    }

    @Test func flaggedDraftShowsTheWarning() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true), onApprove: {}, onUnapprove: {},
                                   onSkip: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("greeting") })
    }

    @Test func unflaggedDraftShowsNoWarning() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: false), onApprove: {}, onUnapprove: {},
                                   onSkip: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("greeting") })
    }

    @Test func flaggedAndNotOverriddenShowsAnOverrideButton() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true, overridden: false),
                                   onApprove: {}, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in },
                                   outboundSendSince: nil)

        _ = try view.inspect().find(button: "Override")   // throws (fails the test) if absent
    }

    @Test func flaggedAndOverriddenShowsNoOverrideButtonButAToneDownedMessage() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true, overridden: true),
                                   onApprove: {}, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in },
                                   outboundSendSince: nil)

        #expect((try? view.inspect().find(button: "Override")) == nil)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("despite") })
    }

    // ViewInspector can't inspect inside a native .alert's content, so this only proves the first
    // half of the two-step gate: tapping "Override" alone must NOT fire the callback directly (it
    // must open the confirm alert instead). The alert's own "Send Anyway" wiring is a one-line,
    // directly-visible closure call, verified by reading the source rather than a second test here.
    @Test func tappingOverrideAloneDoesNotFireTheCallbackWithoutConfirming() throws {
        var overridden = false
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true, overridden: false),
                                   onApprove: {}, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in },
                                   onOverrideSalutationReview: { overridden = true }, outboundSendSince: nil)

        let button = try view.inspect().find(button: "Override")
        try button.tap()

        #expect(overridden == false)
    }
}
