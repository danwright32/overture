import Testing
import Foundation
import SwiftData

// #4224: the reply window offered a draft that predates the contact's newest email.
//
// Luigi: The Musical, 2026-09-24. The window opened on an AI draft written at 10:19 answering Alan's
// morning message, with "Written by AI" and Send under it, although Alan had written again at 19:02. The
// card's reply block already refused that draft (#3573, `ReplyConversationMode`), but the window seeded
// its compose box from `replyDraftBody` unconditionally, so one conversation gave two answers to "is this
// draft current" depending on which surface was open (L16, L30).
//
// The same holds while a replacement is being drafted (#4208): the draft on file is the one being
// replaced, so neither surface offers it for sending until the new one lands.
@MainActor
@Suite("A draft older than their newest message is offered by neither the window nor the card (#4224)")
struct StaleReplyDraftIsNotOfferedTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private static let morningRequest = Date(timeIntervalSince1970: 1_790_000_000)
    private static let staleDraft = "Hi Alan, understood. If plans change I would love to help."

    // The row in the report: a draft requested in the morning and landed, then Alan wrote again.
    private func luigi(_ ctx: ModelContext, theyWroteAgain: Bool = true) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "luigi", groupName: "Luigi: The Musical", discipline: "theater",
                         venue: "V", performanceDate: "2026-11-09", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "alan@x.org", email: "alan@x.org", provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.replied = true
        r.replyFromAddress = "alan@x.org"
        r.replyDraftRequestedAt = Self.morningRequest
        r.replyDraftBody = Self.staleDraft
        let theirs = Self.morningRequest.addingTimeInterval(theyWroteAgain ? 8 * 3_600 : -3_600)
        r.inboundReplySentAt = theirs
        r.repliedAt = theirs
        r.lastReplyText = theyWroteAgain ? "Possibly one night." : "We have no plans for photos as of yet!"
        p.addRecipient(r)
        return (p, r)
    }

    private func window(_ r: Recipient, _ p: Prospect, _ ctx: ModelContext) -> ReplyComposition {
        ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())
    }

    // The report itself: the window must not hand the box a draft answering the message before this one.
    @Test func theWindowDoesNotOfferADraftOlderThanTheirNewestMessage() throws {
        let ctx = ModelContext(try container())
        let (p, r) = luigi(ctx)
        #expect(r.replyPostdatesDraftRequest)
        #expect(window(r, p, ctx).aiDraft?.current() == nil,
                "the reply window offered a draft written before the contact's newest message (#4224)")
    }

    // The ordinary case is untouched: a draft written for the message still waiting opens in the box.
    @Test func aDraftForTheirNewestMessageIsStillOffered() throws {
        let ctx = ModelContext(try container())
        let (p, r) = luigi(ctx, theyWroteAgain: false)
        #expect(window(r, p, ctx).aiDraft?.current() == Self.staleDraft)
    }

    // While a replacement is being drafted the old text is the one being replaced, so it does not
    // reappear in the box during the run, and the card shows the run rather than the old draft.
    @Test func aDraftBeingReplacedIsOfferedByNeither() throws {
        let ctx = ModelContext(try container())
        let (p, r) = luigi(ctx, theyWroteAgain: false)
        r.replyDraftRequestedAt = Self.morningRequest.addingTimeInterval(60)
        r.replyDraftReplacesDraftOnFile = true
        #expect(window(r, p, ctx).aiDraft?.current() == nil)
        #expect(RecipientSnapshot(r).replyConversationMode == .drafting)
    }

    // And a fresh draft arriving still fills the box: the press stamps a request after their message,
    // the new draft lands, and the window both sees it and adopts it into the empty box it opened on.
    @Test func aFreshDraftArrivingStillFillsTheBox() throws {
        let ctx = ModelContext(try container())
        let (p, r) = luigi(ctx)
        let c = window(r, p, ctx)
        let opened = c.aiDraft?.current() ?? ""
        #expect(opened == "")

        // Dan presses Draft with AI: the request postdates Alan's message and asks for a replacement.
        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 1_790_000_000 + 9 * 3_600)
        r.replyDraftReplacesDraftOnFile = true
        #expect(c.aiDraft?.current() == nil, "the old draft reappeared while its replacement was running")

        // The replacement lands, as `ReplyClassifyImporter` writes it.
        r.replyDraftBody = "Hi Alan, one night would be plenty."
        r.replyDraftReplacesDraftOnFile = false
        let arrived = c.aiDraft?.current()
        #expect(arrived == "Hi Alan, one night would be plenty.")
        #expect(ReplyPanel.arriving(draft: arrived, typed: opened, seeded: opened)
                == .adopt("Hi Alan, one night would be plenty."))
    }

    // One predicate: for every combination of the three facts, the window offers a draft exactly when the
    // card offers Send. Enumerated rather than sampled, because two readings of one rule disagree in the
    // corner nobody wrote a case for (L16, L517).
    @Test func theWindowAndTheCardAgreeInEveryCombination() throws {
        for theyWroteAgain in [false, true] {
            for replacing in [false, true] {
                for hasDraft in [false, true] {
                    let ctx = ModelContext(try container())
                    let (p, r) = luigi(ctx, theyWroteAgain: theyWroteAgain)
                    r.replyDraftReplacesDraftOnFile = replacing
                    if !hasDraft { r.replyDraftBody = nil }
                    let windowOffers = window(r, p, ctx).aiDraft?.current() != nil
                    let cardOffers = RecipientSnapshot(r).replyConversationMode.offersToSend
                    #expect(r.hasUnhandledReply)
                    #expect(windowOffers == cardOffers,
                            "window and card disagree: wroteAgain \(theyWroteAgain), replacing \(replacing), draft \(hasDraft)")
                }
            }
        }
    }
}
