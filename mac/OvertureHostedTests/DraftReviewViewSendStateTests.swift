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

    // #2050: the drafted card, which is now where Dan presses the one button that sends.
    private func draftedItem() -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .drafted, draftSubject: "S", draftBody: "Hi", hasPendingRecipient: true)
    }

    // A draft carries ONE button to sent, and it names the screen it opens rather than claiming to send.
    @Test func aDraftOffersOneButtonThatOpensTheFinalReview() throws {
        let view = DraftReviewView(item: draftedItem(), onUnapprove: {}, onSaveDraft: { _, _ in }, gmailConnected: true, outboundSendSince: nil)

        _ = try view.inspect().find(button: "Final review")
        #expect((try? view.inspect().find(button: "Approve")) == nil)
    }

    // #2050/#2012: that button is disabled without Gmail, and a disabled control that explains itself only
    // on hover is a dead end. This is now the likeliest reason it is greyed, because every draft in the
    // queue is stopped by it, so it has to be readable on the card.
    @Test func aDraftSaysWhenGmailIsWhatIsStoppingIt() throws {
        let view = DraftReviewView(item: draftedItem(), onUnapprove: {}, onSaveDraft: { _, _ in }, gmailConnected: false, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains(GmailCopy.notConnected) })
    }

    @Test func aConnectedDraftSaysNothingAboutGmail() throws {
        let view = DraftReviewView(item: draftedItem(), onUnapprove: {}, onSaveDraft: { _, _ in }, gmailConnected: true, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains(GmailCopy.notConnected) })
    }

    @Test func noOutboundSendShowsTheSendButton() throws {
        let view = DraftReviewView(item: approvedItem(), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        _ = try view.inspect().find(button: "Send")   // throws (fails the test) if not present
    }

    @Test func anInFlightOutboundSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let view = DraftReviewView(item: approvedItem(), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: since)

        #expect((try? view.inspect().find(button: "Send")) == nil)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }

    // #1311: an approved show with no emailable contact can never send (SendService hard-blocks a blank
    // address). The greyed Send button never said why; this note explains the stall on the Send surface.
    private func approvedItemWithNoEmail() -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi",
                 hasPendingRecipient: false, hasAnyEmailContact: false)
    }

    @Test func anApprovedShowWithNoEmailExplainsWhyItCannotSend() throws {
        let view = DraftReviewView(item: approvedItemWithNoEmail(), onUnapprove: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("No email to send to") })
    }

    @Test func aSendableApprovedShowShowsNoSuchNote() throws {
        let view = DraftReviewView(item: approvedItem(), onUnapprove: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("no email to send to") })
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
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true), onUnapprove: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("greeting") })
    }

    @Test func unflaggedDraftShowsNoWarning() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: false), onUnapprove: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("greeting") })
    }

    @Test func flaggedAndNotOverriddenShowsAnOverrideButton() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true, overridden: false),
                                   onUnapprove: {}, onSaveDraft: { _, _ in },
                                   outboundSendSince: nil)

        _ = try view.inspect().find(button: "Override")   // throws (fails the test) if absent
    }

    @Test func flaggedAndOverriddenShowsNoOverrideButtonButAToneDownedMessage() throws {
        let view = DraftReviewView(item: item(draftNeedsSalutationReview: true, overridden: true),
                                   onUnapprove: {}, onSaveDraft: { _, _ in },
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
                                   onUnapprove: {}, onSaveDraft: { _, _ in },
                                   onOverrideSalutationReview: { overridden = true }, outboundSendSince: nil)

        let button = try view.inspect().find(button: "Override")
        try button.tap()

        #expect(overridden == false)
    }
}

// #789: the draft-lint block on the review surface. Same two-step shape as the salutation block
// above (a plain statement of fact plus a deliberate Override), but it must NAME the finding, and,
// unlike the advisory voice warnings, it must still show on a draft Dan edited himself.
@MainActor
@Suite("DraftReviewView draft lint block (#789)")
struct DraftReviewViewDraftLintTests {
    private func item(blockers: [DraftIssue], blocked: Bool, editedByDan: Bool = false) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "See https://smugmug.com/dan",
                 draftEditedByDan: editedByDan,
                 hasPendingRecipient: !blocked,
                 draftLintBlockers: blockers, draftLintBlocked: blocked)
    }

    private func view(_ item: QueueItem, onOverride: @escaping () -> Void = {}) -> DraftReviewView {
        DraftReviewView(item: item, onUnapprove: {}, onSaveDraft: { _, _ in },
                        onOverrideDraftLint: onOverride, outboundSendSince: nil)
    }

    @Test func aBlockedDraftNamesTheFindingRatherThanSayingSomethingIsWrong() throws {
        let texts = try view(item(blockers: [.foreignLink], blocked: true))
            .inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("won't send") })
        #expect(texts.contains { $0.contains(DraftIssue.foreignLink.label) })
    }

    @Test func aCleanDraftShowsNoBlock() throws {
        let texts = try view(item(blockers: [], blocked: false))
            .inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("won't send") })
    }

    @Test func aBlockedDraftOffersAnOverrideThatDoesNotFireOnASingleTap() throws {
        var overridden = false
        let v = view(item(blockers: [.placeholder], blocked: true), onOverride: { overridden = true })
        let button = try v.inspect().find(button: "Override")
        try button.tap()
        #expect(overridden == false)   // must open the confirm alert, not send
    }

    @Test func anOverriddenBlockKeepsAVisibleTrailInsteadOfDisappearing() throws {
        let texts = try view(item(blockers: [.foreignLink], blocked: false))
            .inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect((try? view(item(blockers: [.foreignLink], blocked: false)).inspect().find(button: "Override")) == nil)
        #expect(texts.contains { $0.contains("despite") })
    }

    // Dan's #789 call: the advisory voice warnings hide once he edits ("it's his text now"), but a
    // blocking finding is a fact about the words a stranger reads, so his own edit still shows it.
    @Test func aBlockerStillShowsOnADraftDanEditedHimself() throws {
        let texts = try view(item(blockers: [.placeholder], blocked: true, editedByDan: true))
            .inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains(DraftIssue.placeholder.label) })
    }
}

// #733: guard against repeatedly re-prepping the same prospect.
@MainActor
@Suite("DraftReviewView re-prep cooldown (#733)")
struct DraftReviewViewReprepCooldownTests {
    private func item(status: ReviewStatus = .drafted, reprepDraftRequested: Bool = false,
                      reprepContactsRequested: Bool = false, reprepLastServedAt: Date? = nil) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: status, draftSubject: "S", draftBody: "Hi",
                 reprepDraftRequested: reprepDraftRequested, reprepContactsRequested: reprepContactsRequested,
                 reprepLastServedAt: reprepLastServedAt)
    }

    @Test func reprepMenuIsDisabledWhileARequestIsAlreadyPending() throws {
        let view = DraftReviewView(item: item(reprepDraftRequested: true), onUnapprove: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let menu = try view.inspect().find(ViewType.Menu.self)
        #expect(try menu.isDisabled() == true)
    }

    @Test func reprepMenuIsEnabledWhenNothingIsPending() throws {
        let view = DraftReviewView(item: item(), onUnapprove: {},
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let menu = try view.inspect().find(ViewType.Menu.self)
        #expect(try menu.isDisabled() == false)
    }

    // Mirrors the #718 salutation-override precedent above: prove tapping a re-prep choice within
    // the cooldown does NOT fire onReprep directly (the confirm alert must gate it), rather than
    // trying to inspect inside the native .alert itself.
    @Test func tappingAReprepChoiceWithinCooldownDoesNotFireTheCallbackWithoutConfirming() throws {
        var requestedMode: ReprepMode?
        let recentlyServed = Date().addingTimeInterval(-3600)   // 1h ago, well within the 24h cooldown
        let view = DraftReviewView(item: item(reprepLastServedAt: recentlyServed), onUnapprove: {},
                                   onReprep: { mode in requestedMode = mode },
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let button = try view.inspect().find(button: "Find contacts only")
        try button.tap()

        #expect(requestedMode == nil)
    }

    @Test func tappingAReprepChoiceOutsideCooldownFiresTheCallbackDirectly() throws {
        var requestedMode: ReprepMode?
        let longAgo = Date().addingTimeInterval(-48 * 3600)   // 48h ago, past the 24h cooldown
        let view = DraftReviewView(item: item(reprepLastServedAt: longAgo), onUnapprove: {},
                                   onReprep: { mode in requestedMode = mode },
                                   onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let button = try view.inspect().find(button: "Find contacts only")
        try button.tap()

        #expect(requestedMode == .contactsOnly)
    }
}

// #2073: the approved card's missing-subject note says "Edit the draft to add one", but the approved
// branch drew no Edit control at all: Edit existed only on the drafted card, two states away behind
// Unapprove, and nothing said so. Dan met the note on a hand-written manual prep and read the surface
// as offering no way to edit short of a re-prep that would destroy his text. The note and the control
// it names must live on the same card.
@MainActor
@Suite("DraftReviewView approved card offers Edit (#2073)")
struct DraftReviewViewApprovedEditTests {
    private func approvedItem(subject: String? = "S") -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: subject, draftBody: "Hi", hasPendingRecipient: true)
    }

    @Test func anApprovedCardOffersEdit() throws {
        let view = DraftReviewView(item: approvedItem(), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        _ = try view.inspect().find(button: "Edit")   // throws (fails the test) if absent
    }

    // The exact card Dan was stuck on: approved, hand-written, no subject, the note telling him to
    // edit. The remediation the note names must be present beside it.
    @Test func theCardWhoseNoteSaysEditTheDraftActuallyOffersEdit() throws {
        let view = DraftReviewView(item: approvedItem(subject: nil), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("No subject line") })
        _ = try view.inspect().find(button: "Edit")
    }

    // While a send is in flight the card shows the live label and nothing else: an edit control
    // beside an email already leaving would invite changing text the approval no longer covers.
    @Test func anInFlightSendOffersNoEdit() throws {
        let view = DraftReviewView(item: approvedItem(), onUnapprove: {}, onSaveDraft: { _, _ in },
                                   outboundSendSince: Date(timeIntervalSince1970: 1000))

        #expect((try? view.inspect().find(button: "Edit")) == nil)
    }
}

// #388: a contact whose address looks like the host venue shows a dismissible warning, listed for
// EVERY flagged contact (not just the primary one contactLine shows), since a secondary contact
// (e.g. a presenter) would otherwise be invisible before send.
@MainActor
@Suite("DraftReviewView venue-match warning (#388)")
struct DraftReviewViewVenueMatchTests {
    private func recipient(id: String, name: String?, looksLikeVenue: Bool, dismissed: Bool = false,
                           provenance: RecipientProvenance = .act) -> RecipientSnapshot {
        RecipientSnapshot(id: id, name: name, email: "\(id)@example.com", role: nil, provenance: provenance,
                          sendState: .pending, replied: false, lastReplyText: nil, resolution: nil,
                          bounced: false, outcomeSource: nil, looksLikeVenue: looksLikeVenue,
                          looksLikeVenueDismissed: dismissed)
    }

    private func item(contacts: [RecipientSnapshot]) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi", contacts: contacts)
    }

    @Test func aFlaggedSecondaryContactShowsTheWarningEvenThoughItIsNotThePrimary() throws {
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "act", name: "Emma Robinson", looksLikeVenue: false),
            recipient(id: "presenter", name: nil, looksLikeVenue: true, provenance: .presenter),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("may be the venue") })
        _ = try view.inspect().find(button: "Not the venue")
    }

    @Test func noFlaggedContactsShowNoWarning() throws {
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "act", name: "Emma Robinson", looksLikeVenue: false),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("may be the venue") })
        #expect((try? view.inspect().find(button: "Not the venue")) == nil)
    }

    @Test func aDismissedFlagShowsNoWarning() throws {
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "presenter", name: nil, looksLikeVenue: true, dismissed: true, provenance: .presenter),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("may be the venue") })
    }

    @Test func tappingNotTheVenueFiresTheCallbackWithTheRightRecipientId() throws {
        var dismissedId: String?
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "presenter", name: nil, looksLikeVenue: true, provenance: .presenter),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in },
           onDismissVenueMatch: { rid in dismissedId = rid }, outboundSendSince: nil)

        let button = try view.inspect().find(button: "Not the venue")
        try button.tap()

        #expect(dismissedId == "presenter")
    }
}

// #722: same shape as DraftReviewViewVenueMatchTests above, for a suspected press/media contact.
@MainActor
@Suite("DraftReviewView press-contact warning (#722)")
struct DraftReviewViewPressContactTests {
    private func recipient(id: String, name: String?, looksLikePressContact: Bool, dismissed: Bool = false,
                           provenance: RecipientProvenance = .act) -> RecipientSnapshot {
        RecipientSnapshot(id: id, name: name, email: "\(id)@example.com", role: nil, provenance: provenance,
                          sendState: .pending, replied: false, lastReplyText: nil, resolution: nil,
                          bounced: false, outcomeSource: nil, looksLikePressContact: looksLikePressContact,
                          looksLikePressContactDismissed: dismissed)
    }

    private func item(contacts: [RecipientSnapshot]) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi", contacts: contacts)
    }

    @Test func aFlaggedSecondaryContactShowsTheWarningEvenThoughItIsNotThePrimary() throws {
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "act", name: "Emma Robinson", looksLikePressContact: false),
            recipient(id: "presenter", name: nil, looksLikePressContact: true, provenance: .presenter),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("may be a press/media contact") })
        _ = try view.inspect().find(button: "Not press/media")
    }

    @Test func noFlaggedContactsShowNoWarning() throws {
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "act", name: "Emma Robinson", looksLikePressContact: false),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("may be a press/media contact") })
        #expect((try? view.inspect().find(button: "Not press/media")) == nil)
    }

    @Test func aDismissedFlagShowsNoWarning() throws {
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "presenter", name: nil, looksLikePressContact: true, dismissed: true, provenance: .presenter),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in }, outboundSendSince: nil)

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("may be a press/media contact") })
    }

    @Test func tappingNotPressMediaFiresTheCallbackWithTheRightRecipientId() throws {
        var dismissedId: String?
        let view = DraftReviewView(item: item(contacts: [
            recipient(id: "presenter", name: nil, looksLikePressContact: true, provenance: .presenter),
        ]), onUnapprove: {}, onSaveDraft: { _, _ in },
           onDismissPressContactMatch: { rid in dismissedId = rid }, outboundSendSince: nil)

        let button = try view.inspect().find(button: "Not press/media")
        try button.tap()

        #expect(dismissedId == "presenter")
    }
}
