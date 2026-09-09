import Testing
import Foundation
import SwiftData

private let replacingAttachGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com",
                                                threadId: "thread-they-started")

// #3712 (milestone 82, Phase 6): every reader that treats the stored thread as the one Overture SENT on,
// re-asked now that a link can REPLACE that thread on a contact Overture really did email.
//
// #2717 swept this once, when `gmailThreadId != nil` stopped proving Overture had emailed a contact. The
// answer it reached was a predicate keyed on the CHANNEL, `replyWatchConversationIsAttached`, which is
// `outreachChannel == .contactForm && hasWatchableConversation && gmailMessageId == nil`. That was exactly
// right while an attached conversation could only ever sit on a form pitch. Phase 3 made an emailed pitch
// attachable, and every one of those three clauses is false on the row #3706 is about: the channel is
// `.email`, and `gmailMessageId` names a real message Overture sent, on a thread that is no longer the one
// stored. So the predicate answers "Overture sent on this conversation" about a stranger's thread, and
// three readers act on that answer.
//
// The three, derived from the code rather than remembered (L30, L96): `AttachedConversation.refusalToContinue`
// (which is what stops an unparented message being dropped into a conversation Overture is not a party to),
// `GmailThreadingRepair` (which would read the linked thread for a message of Dan's and store it as the
// pitch's own outgoing id), and `SendService.sendFollowUp`, whose recorded reason for carrying no guard at
// all is that the two states are "mutually exclusive by construction". They stopped being.
//
// Every test injects `now` (L130).
// A counter the injected fetch may write to from a non-escaping-safe closure without capturing `var`.
@MainActor
private final class Reads { var count = 0 }

@MainActor
@Suite("Readers of the stored thread after a replacing attach (#3712)")
struct ThreadReadersAfterAReplacingAttachTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let pitched = "producer@presenter.example"
    private let writer = "performer@theirown.example"

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "show-key", groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-12-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func emailedPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: pitched, email: pitched, name: "Corin Hale", provenance: .presenter)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-9 * 86_400)
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.gmailReferences = "<ours@mail.gmail.com>"
        r.gmailThreadId = "thread-we-sent-on"
        p.addRecipient(r)
        return r
    }

    // A thread carrying NOTHING of theirs, which is the case #3706's own write-up names as the one that
    // survives: the attach's detection finds no reply, so `replied` stays false and the row is still
    // silent and still nudgeable.
    private func threadWithNoReply() -> Data {
        replacingAttachGmail.thread([
            .init(from: "Dan Wright <dan@danwrightphotography.com>", subject: "Photos for the run?",
                  messageID: "<mine-over-there@mail.gmail.com>", id: "msg-1",
                  internalDateMillis: Int64(now.timeIntervalSince1970 - 3600) * 1000)
        ])
    }

    @discardableResult
    private func linkTheOtherThread(_ r: Recipient, on p: Prospect, in ctx: ModelContext,
                                    threadJSON: Data? = nil) -> AttachConversation.Outcome {
        AttachConversation.attach(threadId: "thread-they-started",
                                  threadJSON: threadJSON ?? threadWithNoReply(),
                                  subject: "Photos for the run?", fromAddress: writer,
                                  to: r, on: p, ledger: ContactRefusal.ledger(in: ctx),
                                  selfEmail: me, now: now)
    }

    // MARK: the predicate the three readers ask

    @Test("the linked thread is not one Overture sent on, whatever the channel says")
    func theLinkedThreadIsNotOurs() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)

        linkTheOtherThread(r, on: p, in: ctx)

        #expect(r.replyWatchConversationIsAttached,
                "the stored thread is the writer's, and Overture has never sent a message on it")
    }

    // It heals, which is why the displaced id is recorded rather than the fact being inferred from the
    // attach alone. The moment Overture's own reply lands on the linked thread there IS a message of its
    // own to thread off, and a rule keyed on the attach would go on refusing long after its reason had
    // gone (L68).
    @Test("it stops being someone else's conversation once Overture answers on it")
    func itHealsOnceOvertureSendsOnTheLinkedThread() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        linkTheOtherThread(r, on: p, in: ctx)

        r.gmailMessageId = "<ours-on-their-thread@mail.gmail.com>"   // what sendReplyDraft stores

        #expect(!r.replyWatchConversationIsAttached)
    }

    // MARK: what threads onto it

    // `ReplyThreading` falls back to OUR last outgoing message when theirs is unknown, which is right
    // while the two are on one conversation. After a replacing attach they are not: `gmailMessageId`
    // names a message on the thread the pitch went out on, so the fallback would parent an answer on the
    // writer's thread to a message that is not in it.
    @Test("an answer never hangs off a message on the displaced thread")
    func itNeverThreadsOffTheDisplacedMessage() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        linkTheOtherThread(r, on: p, in: ctx)

        #expect(ReplyThreading.inReplyTo(for: r) == nil)
        #expect(ReplyThreading.references(for: r) == nil,
                "the pitch thread's ancestry belongs to a different conversation")
    }

    // With nothing to hang off, the send must REFUSE rather than drop an unparented message into a
    // conversation Overture is not a party to, which is #2647, #2649 and #2653's defect by a new route.
    @Test("Overture refuses to add a message to the conversation it did not send on")
    func itRefusesToContinueSomebodyElsesConversation() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        linkTheOtherThread(r, on: p, in: ctx)

        let refusal = AttachedConversation.refusalToContinue(r, displayName: p.groupName)

        #expect(refusal != nil)
        #expect(refusal?.contains(p.groupName) == true)
    }

    // MARK: the nudge

    // A nudge is a cold chase, sent onto the conversation Overture itself started. After a replacing
    // attach the row holds neither: the stored thread is the writer's, and the address is the writer's
    // too, so the nudge would arrive as a chase of a pitch that person never received, on a conversation
    // Overture never opened.
    @Test("a replacing attach takes the contact out of the nudge sequence")
    func itIsNoLongerNudgeable() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        #expect(FollowUp.isAwaitingNudge(r, in: p, now: now), "it is an ordinary silent emailed pitch")

        linkTheOtherThread(r, on: p, in: ctx)

        #expect(r.replied == false, "the linked thread carries nothing of theirs, so it is still silent")
        #expect(!FollowUp.isAwaitingNudge(r, in: p, now: now))
    }

    // MARK: the threading repair

    // It selects rows still holding a locally minted id (a send whose read back failed, #2647) and reads
    // the stored thread for a message of Dan's to replace it with. On a replaced row that thread is the
    // writer's, and the premise of the manual route is that Dan answered there, so the repair would find
    // his message and store it as the PITCH's own outgoing id: the record of what Overture actually sent
    // would be overwritten by a message on a different conversation.
    @Test("the threading repair leaves a replaced conversation alone")
    func theThreadingRepairSkipsAReplacedConversation() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        // The shape #2647 leaves behind: an id under Dan's OWN domain, which Gmail never carried.
        r.gmailMessageId = "<locally-minted@danwrightphotography.com>"
        #expect(GmailMessage.isLocallyMintedMessageID(r.gmailMessageId, senderEmail: me))
        linkTheOtherThread(r, on: p, in: ctx)
        let minted = r.gmailMessageId

        let reads = Reads()
        let outcome = await GmailThreadingRepair(fromEmail: me).repairMessageIds(
            in: ctx, token: "tok",
            fetch: { req in
                reads.count += 1
                return (self.threadWithNoReply(),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: nil)!)
            })

        #expect(reads.count == 0, "it must not even read a conversation it did not send on")
        #expect(outcome.repaired == 0)
        #expect(r.gmailMessageId == minted, "the pitch's own outgoing id is untouched")
        #expect(r.threadingDegraded == false,
                "and it is not warned about a conversation that threads perfectly well")
    }

    // MARK: what the panel says

    // #2715's line, "You linked this conversation. Overture didn't email them", is true of the form pitch
    // it was written for and reads as a denial of a real pitch here: Overture emailed the producer, at
    // the address the link displaced.
    @Test("the reply panel names the address Overture actually emailed")
    func theReplyPanelNamesTheAddressOvertureEmailed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        linkTheOtherThread(r, on: p, in: ctx)

        let line = try #require(ReplyPanel.linkedByHandLine(for: r))

        #expect(line.contains(pitched))
        #expect(!line.contains("didn't email"))
    }

    // And the form pitch it was written for is untouched: nothing was displaced there, so there is no
    // address to name and the original sentence is the true one.
    @Test("a link that displaced no address still says Overture emailed nobody here")
    func aLinkThatDisplacedNoAddressIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "form:https://www.corinhale.example/contact", email: nil,
                          name: "Corin Hale", provenance: .act)
        r.contactFormURL = "https://www.corinhale.example/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        linkTheOtherThread(r, on: p, in: ctx)

        #expect(r.attachDisplacedEmail == nil)
        #expect(ReplyPanel.linkedByHandLine(for: r) == AttachConversationWriteCopy.linkedByHand)
    }

    // MARK: taking it back

    // Phase 4's rule: the detach restores exactly what the replacing attach changed (L574). The displaced
    // message id is one of those things now, so it goes back with the rest.
    @Test("detaching clears the record of the displaced message")
    func detachingClearsTheDisplacedMessage() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        linkTheOtherThread(r, on: p, in: ctx)

        let outcome = DetachConversation.detach(r, on: p, now: now, omniFocusEnabled: false)

        guard case .detached = outcome else { Issue.record("expected a detach, got \(outcome)"); return }
        #expect(r.attachDisplacedMessageId == nil)
        #expect(!r.replyWatchConversationIsAttached,
                "the pitch is back on its own thread, which Overture did send on")
    }
}
