import Testing
import Foundation
import SwiftData

// #2869: the reply card's Copy button recorded an answer that may never have been sent.
//
// `copyReply` put the draft on the pasteboard and then called `AnsweredReply.record` unconditionally.
// That freezes the body as sent, stamps `replySentAt` and `replyHandledAt`, consumes the draft, and
// marks every peer on the same reply answered. Nothing between the copy and those writes established
// that anything left the machine. Copy and close the window, paste into the wrong place, or change your
// mind, and the conversation reads as answered while the person is still waiting. Report what
// verifiably happened (L12).
//
// THE REPO ALREADY SOLVED THIS ONE SCREEN AWAY, which is why this is a class fix and not a new idea.
// `beginFormPitch` copies the pitch and moves the row into the state that WAITS on Dan, and its own
// comment says it records no outreach because "claiming otherwise here is exactly the lie the confirm
// step exists to prevent". The reply card never got that treatment, so two controls doing the same kind
// of act disagreed about whether copying counts as doing it (L30).
@MainActor
@Suite("Copying a reply does not claim it was sent (#2869)")
struct CopyingAReplyDoesNotClaimItWasSentTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func showWithADraftedReply(_ ctx: ModelContext, peers: Int = 1) -> Prospect {
        let p = Prospect(naturalKey: "aurora", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-12-01",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        var rs: [Recipient] = []
        for n in 0..<peers {
            let r = Recipient(id: "c\(n)@example.com", email: "c\(n)@example.com", name: "Contact \(n)",
                              provenance: .act)
            r.sendState = .sent
            r.sentAt = now.addingTimeInterval(-3 * 86_400)
            r.replied = true
            r.repliedAt = now.addingTimeInterval(-3_600)
            r.lastReplyId = "m-1"
            r.lastReplyText = "What would this cost?"
            r.replyDraftBody = "Happy to talk it through."
            rs.append(r)
        }
        p.setRecipients(rs)
        return p
    }

    private func item(_ p: Prospect) -> QueueItem {
        QueueItem(id: p.naturalKey, groupName: p.groupName, discipline: "music", venue: p.venue,
                  performanceDate: p.performanceDate, sourceListingURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                  status: .contacted)
    }

    // MARK: - Copy records nothing about sending

    @Test func copyingLeavesTheConversationStillWaiting() throws {
        let ctx = try context()
        let p = showWithADraftedReply(ctx)
        let r = p.recipients[0]

        ProspectMutations.copyReply(item(p), r.id, prospects: [p], context: ctx,
                                    feedback: ActionFeedback())

        #expect(r.replyHandledAt == nil, "copying marked the conversation answered (#2869)")
        #expect(r.replySentAt == nil, "copying stamped a send that may never have happened")
        #expect(r.sentReplyBody == nil, "copying froze a body as sent")
        #expect(r.replyDraftBody == "Happy to talk it through.",
                "copying consumed the draft, so changing your mind loses the words")
    }

    // The whole reason the unconditional record was worse than it looked: it travelled. One wrong copy
    // cleared every colleague on the same reply.
    @Test func copyingDoesNotClearThePeersOnTheSameReply() throws {
        let ctx = try context()
        let p = showWithADraftedReply(ctx, peers: 3)

        ProspectMutations.copyReply(item(p), p.recipients[0].id, prospects: [p], context: ctx,
                                    feedback: ActionFeedback())

        #expect(p.recipients.allSatisfy { $0.replyHandledAt == nil },
                "copying one contact's draft cleared the colleagues on the same reply (#2869)")
    }

    // It DOES record that the words are on the clipboard, which is what the confirm control is offered
    // from. Without a durable mark the second step has nothing to appear on, and the fix would be a
    // button Dan can never reach.
    @Test func copyingRecordsThatTheWordsWereTaken() throws {
        let ctx = try context()
        let p = showWithADraftedReply(ctx)
        let r = p.recipients[0]

        ProspectMutations.copyReply(item(p), r.id, prospects: [p], context: ctx,
                                    feedback: ActionFeedback())

        #expect(r.replyCopiedAt != nil, "nothing records that the draft was taken, so nothing can offer the confirm")
    }

    // MARK: - Confirm is the moment the answer becomes real

    @Test func confirmingRecordsTheAnswer() throws {
        let ctx = try context()
        let p = showWithADraftedReply(ctx)
        let r = p.recipients[0]

        ProspectMutations.copyReply(item(p), r.id, prospects: [p], context: ctx,
                                    feedback: ActionFeedback())
        ProspectMutations.confirmCopiedReplySent(item(p), r.id, prospects: [p], context: ctx,
                                                 feedback: ActionFeedback())

        #expect(r.replyHandledAt != nil)
        #expect(r.replySentAt != nil)
        #expect(r.sentReplyBody == "Happy to talk it through.")
    }

    // And it clears the copied mark, or the row keeps offering a confirm for an answer already recorded,
    // which is a control that reads as broken and gets pressed again (L44).
    @Test func confirmingTakesTheOfferAway() throws {
        let ctx = try context()
        let p = showWithADraftedReply(ctx)
        let r = p.recipients[0]

        ProspectMutations.copyReply(item(p), r.id, prospects: [p], context: ctx, feedback: ActionFeedback())
        ProspectMutations.confirmCopiedReplySent(item(p), r.id, prospects: [p], context: ctx,
                                                 feedback: ActionFeedback())
        #expect(r.replyCopiedAt == nil)
    }

    // Confirming something that was never copied records nothing. The control is only ever offered after
    // a copy, and a mutation reachable without one would be a second way to claim a send.
    @Test func confirmingWithoutHavingCopiedRecordsNothing() throws {
        let ctx = try context()
        let p = showWithADraftedReply(ctx)
        let r = p.recipients[0]

        ProspectMutations.confirmCopiedReplySent(item(p), r.id, prospects: [p], context: ctx,
                                                 feedback: ActionFeedback())

        #expect(r.replyHandledAt == nil, "an answer was recorded on a draft nobody took (#2869)")
    }

    // MARK: - Built is not wired (L3)

    // The card offers the confirm, or the copied state is a dead end Dan cannot leave.
    @Test func thecardOffersTheConfirmOnceTheDraftIsCopied() {
        let source = SourceGuardHelper.source("Overture/UI/ReplyConversationView.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("ReplyPanelCopy.confirmCopiedSent"),
                "the card copies a reply and never offers a way to say it was sent (#2869)")
        #expect(SourceGuardHelper.containsCode("contact.replyCopiedAt != nil", in: source),
                "the confirm is offered without asking whether anything was copied")
    }

    // The button is a LIVE one. Every layer between the card and the mutation defaults this callback to
    // a no-op, so a chain that forgets one link draws a control that does nothing and reports nothing,
    // which is worse than no control at all (L109).
    @Test func theconfirmReachesTheMutationThroughEveryLayer() {
        for file in ["Overture/UI/ProspectRowFactory.swift", "Overture/UI/ProspectRowView.swift",
                     "Overture/UI/DraftReviewView.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty)
            #expect(source.contains("onConfirmCopiedReplySent"),
                    Comment(rawValue: "\(file) drops the confirm callback, so the card's button is dead (#2869)"))
        }
        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        #expect(SourceGuardHelper.containsCode("ProspectMutations.confirmCopiedReplySent(", in: factory),
                "the callback is threaded and never reaches the mutation")
    }

    // And the Copy button's tooltip no longer promises the thing it stopped doing.
    @Test func thecopyButtonNoLongerSaysItMarksItReplied() {
        let source = SourceGuardHelper.source("Overture/UI/ReplyConversationView.swift")
        #expect(!ReplyPanelCopy.copyHelp.contains("mark it replied"),
                "the tooltip still says Copy marks the conversation replied, which it no longer does")
        #expect(ReplyPanelCopy.copyHelp.contains("Nothing is recorded"),
                "the tooltip does not say that copying records nothing, which is the whole change")
        // The confirm says the same words as the form pitch's confirm, from the same constant: both are
        // step two of one shape, and two spellings of one control drift (#843).
        #expect(ReplyPanelCopy.confirmCopiedSent == FormOutreachCopy.sentIt)
        #expect(!source.contains("mark it replied"),
                "the tooltip still says Copy marks the conversation replied, which it no longer does")
    }
}
