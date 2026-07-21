import Testing
import Foundation
import SwiftData
@testable import Overture

// QueueItem(_ p: Prospect) and RecipientSnapshot(_ r: Recipient) convert a SwiftData model into the
// flat, Equatable view-model the UI (and QueueModel's pure logic) actually work with. Split out of
// the former ResultsImportTests.swift (#669): that file mixed these live conversion tests with tests
// of the (now-removed) ResultsFileDecoder/ResultsImporter results-file handoff, which had no live
// writer anywhere since #493.
@MainActor
@Suite("QueueItem and RecipientSnapshot construction from the domain model")
struct QueueItemSnapshotTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // #394: the queue item exposes whether the performance can still send, so the Send button persists
    // for the next recipient until every one is sent (the lead sentAt rollup flips on the FIRST send,
    // so the button must NOT gate on that alone under fan-out).
    @Test func queueItemTracksWhetherARecipientCanStillSend() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
        ctx.insert(p)
        let act = Recipient(id: "a@x.example", email: "a@x.example", name: "A", provenance: .act)
        let presenter = Recipient(id: "b@x.example", email: "b@x.example", name: "B", provenance: .presenter)
        p.setRecipients([act, presenter])

        #expect(QueueItem(p).hasPendingRecipient == true)            // both pending

        act.sendState = .sent; act.sentAt = Date()
        #expect(QueueItem(p).hasPendingRecipient == true)            // one sent, one still pending

        presenter.sendState = .sent; presenter.sentAt = Date()
        #expect(QueueItem(p).hasPendingRecipient == false)          // every recipient sent

        // A form-only contact (no email) is pending but not auto-sendable, so it does NOT keep the row sendable.
        let formOnly = Recipient(id: "form:https://x", email: nil, name: "C", provenance: .act,
                                 contactFormURL: "https://x")
        p.setRecipients([formOnly])
        #expect(QueueItem(p).hasPendingRecipient == false)
    }

    // #1324: a probe that found only a venue/press address flags that recipient (looksLikeVenue), which
    // makes it not sendable-pending, so the row would read "No email found" though an email exists. The
    // queue item exposes hasWeakContactEmail so the badge can say "Weak contact only" instead.
    @Test func aProbedShowWhoseOnlyContactLooksLikeAVenueReadsAsWeakContactOnly() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.reachabilityProbedAt = Date()
        ctx.insert(p)
        let venue = Recipient(id: "info@hall.example", email: "info@hall.example", name: "Front desk",
                              provenance: .act)
        venue.looksLikeVenue = true          // held by the venue guard: not sendable, but a real address
        p.setRecipients([venue])

        #expect(QueueItem(p).hasPendingRecipient == false)            // the venue contact is not sendable
        #expect(QueueItem(p).hasWeakContactEmail == true)             // but a weak email does exist
        #expect(QueueItem(p).reachabilityBadge() == .weakContactOnly) // so the badge is honest about it

        // Dismissing the venue guess makes the same address sendable, so the badge firms up.
        venue.looksLikeVenueDismissed = true
        #expect(QueueItem(p).hasPendingRecipient == true)
        #expect(QueueItem(p).reachabilityBadge() == .emailFound)
    }

    // #1325: a probe result is fresh only within Reachability.probeFreshness. Past that window the firm
    // badge becomes the "worth re-checking" state so a stale answer never misleads a keep/dismiss.
    @Test func aProbeResultGoesStaleAfterTheFreshnessWindow() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        let probedAt = Date(timeIntervalSince1970: 1_000_000)
        p.reachabilityProbedAt = probedAt
        ctx.insert(p)
        let act = Recipient(id: "a@x.example", email: "a@x.example", name: "A", provenance: .act)
        p.setRecipients([act])

        // Fresh: the firm result.
        #expect(QueueItem(p).reachabilityBadge(now: probedAt.addingTimeInterval(1)) == .emailFound)
        // Stale: worth re-checking.
        #expect(QueueItem(p).reachabilityBadge(
            now: probedAt.addingTimeInterval(Reachability.probeFreshness + 1)) == .staleProbe)
    }

    // #367: the re-prep flags and eligibility carry through to the view-model so the UI can show a
    // "Re-prep queued" badge and gate the action to non-terminal statuses.
    @Test func queueItemCarriesReprepFlagsAndEligibility() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftBody = "Hi"
        ctx.insert(p)

        #expect(QueueItem(p).isReprepQueued == false)
        #expect(QueueItem(p).isReprepEligible == true)

        p.reprepDraftRequested = true
        #expect(QueueItem(p).isReprepQueued == true)

        p.status = .contacted
        #expect(QueueItem(p).isReprepEligible == false)

        p.status = .dismissed
        #expect(QueueItem(p).isReprepEligible == false)

        p.status = .approved
        #expect(QueueItem(p).isReprepEligible == true)
    }

    // #733: reprepLastServedAt carries through so the UI can warn before re-prepping something
    // just researched.
    @Test func queueItemCarriesReprepLastServedAt() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftBody = "Hi"
        ctx.insert(p)
        #expect(QueueItem(p).reprepLastServedAt == nil)

        let servedAt = Date(timeIntervalSince1970: 1_000_000)
        p.reprepLastServedAt = servedAt
        #expect(QueueItem(p).reprepLastServedAt == servedAt)
    }

    // #418 B1 — QueueItem carries per-contact snapshots in send order (act before presenter) for the
    // conversation surface, with each contact's reply text and a derived status.
    @Test func queueItemBuildsContactSnapshotsInSendOrder() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.draftSubject = "S"; p.draftBody = "Hi"; p.sentAt = Date()
        ctx.insert(p)
        let presenter = Recipient(id: "b@present.example", email: "b@present.example", name: "Bo", provenance: .presenter)
        presenter.sendState = .sent
        let act = Recipient(id: "a@act.example", email: "a@act.example", name: "Ann Lee", provenance: .act)
        act.sendState = .sent; act.replied = true; act.lastReplyText = "Yes, let's talk."
        p.setRecipients([presenter, act])   // inserted out of send order on purpose

        let item = QueueItem(p)
        #expect(item.contacts.map(\.id) == ["a@act.example", "b@present.example"])  // act first
        let ann = item.contacts.first!
        #expect(ann.displayName == "Ann Lee")
        #expect(ann.statusLabel == "In conversation")
        #expect(ann.isAutoReplied == true)
        #expect(ann.lastReplyText == "Yes, let's talk.")
    }

    // #654: contactConfidence/contactMethod/contactFormURL move from the lead-level QueueItem fields
    // (deleted) onto each contact's own snapshot, since the display data is genuinely per-recipient.
    @Test func queueItemCarriesEachContactsOwnConfidenceMethodFormURLAndSourceURL() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act,
                            contactMethodRaw: "named_decision_maker", contactConfidenceRaw: "high",
                            contactFormURL: "https://x.example/contact", contactSourceURL: "https://act.example/about/staff")
        act.looksLikeDuplicateContact = true
        p.setRecipients([act])

        let item = QueueItem(p)
        let a = item.contacts.first
        #expect(a?.contactMethod == .namedDecisionMaker)
        #expect(a?.contactConfidence == .high)
        #expect(a?.contactFormURL == "https://x.example/contact")
        #expect(a?.contactSourceURL == "https://act.example/about/staff")
        #expect(a?.looksLikeDuplicateContact == true)
        #expect(a?.looksLikeDuplicateContactDismissed == false)
    }

    // #642 (#634 Phase D): a performer recipient's overrideBody must reach the snapshot the review
    // screen reads, or there is no text for it to show Dan before he approves/sends.
    @Test func queueItemCarriesAPerformersOverrideBody() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "Midnight Quartet", discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-08-15", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let performer = Recipient(id: "maya@performer.example", email: "maya@performer.example",
                                  name: "Maya Chen", provenance: .performer)
        performer.overrideBody = "I saw you're self-presenting Midnight Quartet."
        let presenter = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        p.setRecipients([performer, presenter])

        let item = QueueItem(p)
        #expect(item.contacts.first { $0.id == "maya@performer.example" }?.overrideBody
                == "I saw you're self-presenting Midnight Quartet.")
        #expect(item.contacts.first { $0.id == "b@present.example" }?.overrideBody == nil)
    }

    // #652: each contact's OWN conversation state must reach the snapshot the per-contact review
    // controls read, not just the lead-level QueueItem field.
    @Test func queueItemCarriesEachContactsOwnConversationState() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let interested = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        interested.sendState = .sent
        interested.setConversationState(.interested, now: now)
        let untouched = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        untouched.sendState = .sent
        p.setRecipients([interested, untouched])

        let item = QueueItem(p)
        let a = item.contacts.first { $0.id == "a@act.example" }
        #expect(a?.conversationState == .interested)
        #expect(a?.conversationStateSource == .manual)
        let b = item.contacts.first { $0.id == "b@present.example" }
        #expect(b?.conversationState == nil)
        #expect(b?.conversationRemindedAt == nil)
    }

    // #459 — the per-recipient "Dan edited this reply draft" flag must reach the snapshot the view reads,
    // so the deterministic warnings can be suppressed on his edited text.
    @Test func queueItemCarriesTheReplyDraftEditedFlag() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let edited = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        edited.sendState = .sent; edited.replied = true; edited.applyReplyDraftEdit("Dan's edit.")
        let fresh = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        fresh.sendState = .sent; fresh.replied = true; fresh.replyDraftBody = "AI draft."
        p.setRecipients([edited, fresh])

        let item = QueueItem(p)
        #expect(item.contacts.first { $0.id == "a@act.example" }?.replyDraftEditedByDan == true)
        #expect(item.contacts.first { $0.id == "b@present.example" }?.replyDraftEditedByDan == false)
    }

    // #418 B1 — the derived per-contact status line: terminal resolution wins, then bounce, then reply,
    // then send state; and isAutoReplied is true only for an auto (not hand-marked) reply.
    @Test func recipientSnapshotStatusLabelsAndAutoReplied() {
        func s(_ sendState: SendState = .sent, replied: Bool = false, resolution: RecipientResolution? = nil,
               bounced: Bool = false, email: String? = "a@act.example", source: OutcomeSource? = nil,
               suppressionReason: RecipientSuppressionReason = .bookedElsewhere) -> RecipientSnapshot {
            RecipientSnapshot(id: "x", name: "N", email: email, role: nil, provenance: .act,
                              sendState: sendState, replied: replied, lastReplyText: nil,
                              resolution: resolution, bounced: bounced, outcomeSource: source,
                              suppressionReason: suppressionReason)
        }
        #expect(s(resolution: .booked).statusLabel == "Booked")
        #expect(s(resolution: .declinedSoft).statusLabel == "Closed (not now)")
        #expect(s(resolution: .declinedHard).statusLabel == "Closed (not interested)")
        #expect(s(bounced: true).statusLabel == "Bounced")
        #expect(s(replied: true).statusLabel == "In conversation")
        #expect(s().statusLabel == "Awaiting reply")
        #expect(s(.pending).statusLabel == "Not sent yet")
        #expect(s(.pending, email: nil).statusLabel == "No email yet")
        #expect(s(.suppressed).statusLabel == "Paused (booked elsewhere)")
        // #542: the same suppressed sendState now carries a specific reason so the label doesn't lie
        // about why the contact was taken out of play.
        #expect(s(.suppressed, suppressionReason: .declined).statusLabel == "Paused (show declined)")
        #expect(s(.suppressed, suppressionReason: .removedByDan).statusLabel == "Removed")
        #expect(s(.sending).statusLabel == "Sending…")   // #475/#476: claimed, in flight
        #expect(s(replied: true).isAutoReplied == true)
        #expect(s(replied: true, source: .manual).isAutoReplied == false)   // Dan's mark, not an auto reply
        let noName = RecipientSnapshot(id: "x", name: nil, email: "e@e.example", role: nil, provenance: .act,
                                       sendState: .pending, replied: false, lastReplyText: nil,
                                       resolution: nil, bounced: false, outcomeSource: nil)
        #expect(noName.displayName == "e@e.example")
    }

    // #420 C6 — the draft-state computed props that drive the conversation surface (draft present vs
    // drafting-in-progress vs neither) and the plain-language intent-hint label.
    @Test func recipientSnapshotDraftStatesAndIntentLabel() {
        func s(body: String? = nil, requestedAt: Date? = nil) -> RecipientSnapshot {
            RecipientSnapshot(id: "x", name: "N", email: "e@e.example", role: nil, provenance: .act,
                              sendState: .sent, replied: true, lastReplyText: nil, resolution: nil,
                              bounced: false, outcomeSource: nil, replyDraftSubject: nil,
                              replyDraftBody: body, replyDraftRequestedAt: requestedAt, intentHint: nil)
        }
        #expect(s(body: "a draft").hasReplyDraft == true)
        #expect(s().hasReplyDraft == false)
        #expect(s(requestedAt: Date()).isDraftingReply == true)            // requested, not yet arrived
        #expect(s(body: "a draft", requestedAt: Date()).isDraftingReply == false)  // arrived
        #expect(s().isDraftingReply == false)                             // never requested

        #expect(QueueModel.replyIntentLabel("wants_to_book") == "wants to book")
        #expect(QueueModel.replyIntentLabel("has_question") == "has a question")
        #expect(QueueModel.replyIntentLabel("weird") == "weird")          // unknown passes through
    }

    // #939: QueueModel.items(from:) is what QueueView and ArchiveView actually call to build their rows,
    // so the cross-venue engagement link (computed across the WHOLE prospects array, not one prospect at
    // a time) is exercised end to end here rather than only through its pure pieces.
    @Test func itemsFromCarriesTheLinkedEngagementAcrossTwoVenues() throws {
        let ctx = ModelContext(try makeContainer())
        let p1 = Prospect(naturalKey: "moca-25", groupName: "MOCA PERFORMS", discipline: "theater",
                          venue: "Museum of Chinese in America", performanceDate: "2026-07-25", sourceListingURL: nil,
                          websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let p2 = Prospect(naturalKey: "moca-24", groupName: "MOCA PERFORMS", discipline: "theater",
                          venue: "Open Door Senior Center", performanceDate: "2026-07-24", sourceListingURL: nil,
                          websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p1); ctx.insert(p2)

        let items = QueueModel.items(from: [p1, p2])

        let item25 = try #require(items.first { $0.id == "moca-25" })
        #expect(item25.linkedEngagementMembers == [EngagementLink.Member(venue: "Open Door Senior Center", date: "2026-07-24")])
        #expect(QueueModel.linkedEngagementNote(item25) == "This production also plays at Open Door Senior Center on Jul 24.")
    }

    @Test func itemsFromCarriesNoLinkWhenThereIsNoSiblingVenue() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "Solo Show", discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)

        let items = QueueModel.items(from: [p])

        #expect(items.first?.linkedEngagementMembers.isEmpty == true)
    }
}
