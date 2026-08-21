import Testing
import Foundation
import SwiftData

// #2934: what the reply block offers, decided once for both surfaces that draw it.
//
// `ReplyConversationView` is shared by the reached-out queue and the Archive card, and it chose between
// its four states from its own reading of the reply fields, none of which consulted whether the
// conversation had already been ANSWERED. A conversation Dan has answered is still `replied`, so the
// block appeared with its "Draft a reply" button on the Archive card.
//
// What that costs since #2921: the queue builder now refuses an answered conversation, so pressing the
// button stamps the request, launches the paid run, and the run correctly finds nothing for that row. The
// row then reads "Drafting a reply" until the timeout flips it to the stuck state, whose Retry stamps and
// launches again and lands in the same place. A control that cannot do anything, with no sentence saying
// why (L109, L148).
//
// Before #2921 it "worked", by drafting a reply to a message Dan had already answered, which is the spend
// #2921 exists to stop. So the fix is not to let the run through again.
@Suite("What the reply block offers, per conversation (#2934)")
struct ReplyConversationModeTests {

    // The live case: a reply nobody has answered. Every control stays exactly as it was.
    @Test func anUnansweredReplyKeepsTheWholeSurface() {
        #expect(ReplyConversationMode.of(hasUnhandledReply: true, replyIsAnswered: false,
                                         hasReplyDraft: false, isDrafting: false) == .offerADraft)
        #expect(ReplyConversationMode.of(hasUnhandledReply: true, replyIsAnswered: false,
                                         hasReplyDraft: false, isDrafting: true) == .drafting)
        #expect(ReplyConversationMode.of(hasUnhandledReply: true, replyIsAnswered: false,
                                         hasReplyDraft: true, isDrafting: false) == .draftReadyToSend)
    }

    // THE fix: an answered conversation never offers to draft, and never claims to be drafting.
    @Test func anAnsweredConversationNeverOffersADraft() {
        #expect(ReplyConversationMode.of(hasUnhandledReply: false, replyIsAnswered: true,
                                         hasReplyDraft: false, isDrafting: false) == .answeredNothingToShow)
        #expect(ReplyConversationMode.of(hasUnhandledReply: false, replyIsAnswered: true,
                                         hasReplyDraft: false, isDrafting: true) == .answeredNothingToShow)
    }

    // The draft that was already written stays, as a RECORD: the Archive card is where Dan looks at what
    // happened, so the text belongs. What it must not carry is Send, which would answer a second time.
    @Test func adraftOnAnAnsweredConversationIsKeptAsARecord() {
        #expect(ReplyConversationMode.of(hasUnhandledReply: false, replyIsAnswered: true,
                                         hasReplyDraft: true, isDrafting: false) == .answeredDraftAsRecord)
    }

    // A conversation that is not unhandled for some OTHER reason (a contact stood down, a bounce) is not
    // "answered", so it must not be told it was. It shows the record and says nothing.
    @Test func aConversationClosedWithoutAnAnswerClaimsNoAnswer() {
        #expect(ReplyConversationMode.of(hasUnhandledReply: false, replyIsAnswered: false,
                                         hasReplyDraft: true, isDrafting: false) == .closedDraftAsRecord)
        #expect(ReplyConversationMode.of(hasUnhandledReply: false, replyIsAnswered: false,
                                         hasReplyDraft: false, isDrafting: false) == .closedNothingToShow)
    }

    // Only the two answered modes may speak, and only they carry the sentence. A mode that says nothing
    // must have nothing to say, or a blank line appears on the card.
    @Test func onlyTheAnsweredModesExplainThemselves() {
        for mode in ReplyConversationMode.allCases {
            let speaks = mode.explanation != nil
            #expect(speaks == (mode == .answeredDraftAsRecord || mode == .answeredNothingToShow),
                    Comment(rawValue: "\(mode) says \(mode.explanation ?? "nothing"), which is not its job"))
        }
    }

    // The rule above decides correctly and would keep doing so if the snapshot carried a hardwired
    // answer, which is how the card came to disagree with the queue in the first place. Measured with
    // `scripts/mutate.sh`: pinning `hasUnhandledReply: true` at the build site was reported SURVIVED.
    // So the CARRY is asserted, from a real Recipient in each state.
    @MainActor
    @Test func theSnapshotCarriesTheContactsOwnAnswer() throws {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let now = Date()

        for answered in [false, true] {
            let p = Prospect(naturalKey: "k-\(answered)", groupName: "Aurora Strings", discipline: "music",
                             venue: "Carnegie Hall", performanceDate: "2026-11-14",
                             sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil)
            let r = Recipient(id: "ada@aurora.test", email: "ada@aurora.test", name: "Ada",
                              provenance: .act)
            r.sendState = .sent
            r.sentAt = now.addingTimeInterval(-6 * 86_400)
            r.replied = true
            r.repliedAt = now.addingTimeInterval(-5 * 86_400)
            r.inboundReplySentAt = now.addingTimeInterval(-5 * 86_400)
            if answered { r.replyHandledAt = now.addingTimeInterval(-4 * 86_400) }
            p.addRecipient(r)
            ctx.insert(p)

            let snapshot = RecipientSnapshot(r)
            #expect(snapshot.hasUnhandledReply == r.hasUnhandledReply,
                    "the snapshot must carry the contact's own answer, never its own reading of the fields")
            #expect(snapshot.replyIsAnswered == r.replyIsAnswered)
            // And the whole point: the mode follows from it, so the card and the queue agree.
            #expect(snapshot.replyConversationMode.offersToDraft == !answered)
        }
    }

    // The request control and the drafting state are the two things this exists to withdraw, so which
    // modes carry them is asserted over ALL of them rather than sampled.
    @Test func onlyALiveConversationCarriesTheRequestControl() {
        for mode in ReplyConversationMode.allCases {
            #expect(mode.offersToDraft == (mode == .offerADraft),
                    Comment(rawValue: "\(mode) offers a control the run would find nothing for"))
            #expect(mode.showsDraftingProgress == (mode == .drafting),
                    Comment(rawValue: "\(mode) claims a run is working on this"))
            #expect(mode.offersToSend == (mode == .draftReadyToSend),
                    Comment(rawValue: "\(mode) offers to send an answer on a conversation that is over"))
        }
    }
}
