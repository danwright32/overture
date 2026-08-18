import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let inquiryAttachGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2712: a hire inquiry Dan answers in Gmail, which is the natural thing to do when the mail is already
// open in front of him, was never watched for replies at all.
//
// `Inquiry.gmailThreadId` had exactly one writer, the send receipt in `InquiryReplySender`, and
// `GmailReplyChecker.threadsToCheck` skips any recipient whose thread id is empty. So their next message
// was invisible and nothing reopened the row.
//
// The fix is the mechanism #2713 to #2718 already built for a form pitch, widened rather than copied: the
// same one-search-per-tick mailbox read, the same refusals, the same attach-and-detect-in-one-write. What
// differs is WHICH message is theirs. A form pitch has no address to search on and so is scored, ranked
// and put to Dan as a question; an inquiry carries the address it came from, so the match is identity
// rather than a guess and there is nothing to ask.
//
// Every test injects `now` and every dated fixture is anchored to it. None reads the clock (L130).
@MainActor
@Suite("An inquiry answered in Gmail (#2712)")
struct InquiryConversationAttachTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let them = "priya.raman@example.com"

    // Logged by hand four days ago, never answered from inside Overture: no thread, no message id.
    @discardableResult
    private func inquiry(_ ctx: ModelContext, email: String? = "priya.raman@example.com",
                         loggedDaysAgo: Double = 4) -> Inquiry {
        let i = Inquiry(source: .directEmail, inquirerName: "Priya Raman", inquirerEmail: email,
                        eventName: "Spring gala", performanceDate: nil, venue: "Merkin Hall",
                        notes: nil, createdAt: now.addingTimeInterval(-loggedDaysAgo * 86_400))
        ctx.insert(i)
        return i
    }

    private func message(_ id: String, from: String, subject: String, hoursAgo: Double = 1,
                         threadId: String = "thread-1",
                         listUnsubscribe: String? = nil) -> GmailReplySearch.InboundMessage {
        GmailReplySearch.InboundMessage(messageId: id, threadId: threadId,
                                        fromAddress: ReplyDetection.email(from: from),
                                        fromName: ReplyDetection.displayName(from: from),
                                        subject: subject,
                                        sentAt: now.addingTimeInterval(-hoursAgo * 3600),
                                        listUnsubscribe: listUnsubscribe)
    }

    // A Gmail thread as `threads.get` returns it. `internalDate` orders the messages, not their position
    // in the array, which is what every reader in ReplyDetection relies on.
    //
    // #2918 put `labelIds` on these, which is what says whether one was actually sent or is still an
    // unsent draft. #2928 moved the shape into `GmailFixture`.
    private func threadJSON(_ messages: [(from: String, secondsAgo: Int64, subject: String,
                                          messageId: String?)]) -> Data {
        inquiryAttachGmail.thread(messages.map { m in
            let at = Int64(now.timeIntervalSince1970) - m.secondsAgo
            return .init(from: m.from, subject: m.subject, messageID: m.messageId,
                         id: "msg-\(at)", internalDateMillis: at * 1000)
        })
    }

    // The conversation this issue is about: they wrote, Dan answered in Gmail, they wrote again.
    private func answeredInGmail() -> Data {
        threadJSON([(from: "Priya Raman <\(them)>", secondsAgo: 4 * 86_400,
                     subject: "Photography for our spring gala", messageId: "<first@mail.gmail.com>"),
                    (from: "Dan Wright <\(me)>", secondsAgo: 3 * 86_400,
                     subject: "Re: Photography for our spring gala", messageId: "<mine@mail.gmail.com>"),
                    (from: "Priya Raman <\(them)>", secondsAgo: 3600,
                     subject: "Re: Photography for our spring gala", messageId: "<second@mail.gmail.com>")])
    }

    private func gmail(_ body: Data, status: Int = 200) -> (URLRequest) async throws -> (Data, URLResponse) {
        { req in
            (status == 200 ? body : Data(),
             HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: the defect

    // The whole issue in one test, asserted where the blindness actually lived: the watcher's own subject
    // list. Before this change nothing could ever put a thread on an inquiry except a send from inside
    // Overture, so this set was empty and their second message was invisible for ever.
    @Test("an inquiry Dan answered in Gmail is watched for replies once they write back")
    func anInquiryAnsweredInGmailJoinsTheWatchedThreads() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: "Priya Raman <\(them)>", subject: "Re: Photography for our spring gala")]

        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now,
                 token: "tok", fetch: gmail(answeredInGmail()))

        #expect(outcome.attached == 1)
        #expect(GmailReplyChecker.threadsToCheck(in: [i]).contains("thread-1"))
        #expect(i.replied)
        #expect(i.lastReplyId != nil)
        // #2653: the parent for Dan's answer, so answering from Overture threads under THEIR message.
        #expect(i.inboundReplyMessageId == "<second@mail.gmail.com>")
    }

    // The row said "Awaiting your first reply" for ever, because `sentAt` has only ever been written by a
    // send from inside Overture. Taken from the instant Dan's own message was actually sent, never from
    // the clock: a stamp of `now` would restart the follow-up nudge days late (L37).
    @Test("the inquiry is dated by Dan's own message on the thread, not by when Overture noticed")
    func sentAtComesFromDansOwnMessage() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: them, subject: "Re: spring gala")]

        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(i.sentAt == now.addingTimeInterval(-3 * 86_400))
    }

    // A thread carrying nothing of Dan's is a person who wrote twice before he ever answered. Claiming he
    // had replied would take the one row genuinely waiting on him out of the state that says so.
    @Test("an inquiry Dan has not answered anywhere is not dated as answered")
    func noMessageOfDansMeansNoSendDate() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let theirsOnly = threadJSON([
            (from: "Priya Raman <\(them)>", secondsAgo: 4 * 86_400, subject: "Spring gala",
             messageId: "<first@mail.gmail.com>"),
            (from: "Priya Raman <\(them)>", secondsAgo: 3600, subject: "Spring gala, following up",
             messageId: "<second@mail.gmail.com>")])

        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "following up")],
                 now: now, token: "tok", fetch: gmail(theirsOnly))

        #expect(i.gmailThreadId == "thread-1")
        #expect(i.sentAt == nil)
    }

    // A send whose thread id Gmail never returned is in the same position for a different reason, and it
    // carries its own real send date. Overwriting that with Dan's message on the recovered thread, or with
    // the clock, would move a date the row already had right.
    @Test("a send that lost its thread id keeps its own send date when the conversation is recovered")
    func aDegradedSendKeepsItsSendDate() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let itsOwnSend = now.addingTimeInterval(-2 * 86_400)
        i.sentAt = itsOwnSend
        i.threadIdDegraded = true

        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "Re: spring gala")],
                 now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(i.gmailThreadId == "thread-1")
        #expect(i.sentAt == itsOwnSend)
    }

    // MARK: who is theirs

    @Test("a message from anybody else is never attached to the inquiry")
    func aStrangerIsNotThem() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: "Someone Else <hello@merkinhall.org>", subject: "Spring gala")]

        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(outcome.attached == 0)
        #expect(i.gmailThreadId == nil)
        #expect(i.conversationAttachedAt == nil)
    }

    // The refusals #2714 exists for have to survive the widening, or they are a rule nothing applies. A
    // newsletter really can go out from the same address a person writes from, and attaching one would
    // watch a mailing list instead of a conversation.
    @Test("a newsletter from the inquirer's own address is refused")
    func bulkMailFromTheirAddressIsRefused() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: them, subject: "Merkin Hall this week",
                             listUnsubscribe: "<https://example.com/u>")]

        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(outcome.attached == 0)
        #expect(i.gmailThreadId == nil)
    }

    // Dan logged himself as the inquirer by mistake, or a bounce notice came back from his own address.
    // Attaching his own mail would make Overture watch a conversation with itself.
    @Test("Dan's own address is never taken for the inquirer")
    func dansOwnMailIsRefused() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx, email: me)
        let found = [message("m2", from: me, subject: "Spring gala")]

        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(outcome.attached == 0)
        #expect(i.gmailThreadId == nil)
    }

    // Two messages from them in the window. The OLDEST is taken, because that is the conversation the
    // inquiry itself is on; a later unrelated thread would attach the wrong one and hide the real answer.
    @Test("the earliest message from them decides the conversation")
    func theEarliestMessageWins() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("later", from: them, subject: "Something else", hoursAgo: 1,
                             threadId: "thread-later"),
                     message("earlier", from: them, subject: "Re: spring gala", hoursAgo: 20,
                             threadId: "thread-1")]

        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(i.gmailThreadId == "thread-1")
    }

    // MARK: what is read for at all

    @Test("an inquiry that already holds a conversation is left exactly as it is")
    func anAlreadyWatchedInquiryIsNotTouched() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.gmailThreadId = "sent-by-overture"
        i.gmailMessageId = "<mine@mail.gmail.com>"
        i.sentAt = now.addingTimeInterval(-2 * 86_400)

        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "Re: spring gala")],
                 now: now, token: "tok", fetch: gmail(answeredInGmail()))

        // Asserted at the scope as well as at the outcome, because the two are different protections and
        // the write's own refusal would answer for a missing scope rule while the tick went on paying for
        // a thread fetch it had no use for.
        #expect(!ReplySearchScope.inScope(i, now: now))
        #expect(outcome.attached == 0)
        #expect(i.gmailThreadId == "sent-by-overture")
        #expect(i.conversationAttachedAt == nil)
    }

    @Test("a closed inquiry is not read for")
    func aClosedInquiryIsOutOfScope() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.markOutcomeManually(.lostHard, now: now)

        #expect(!ReplySearchScope.inScope(i, now: now))
    }

    // No address means no key to match on, so there is nothing this pass could ever do for it. Saying so
    // in the scope rather than failing to match later keeps "there is nothing to read for" apart from
    // "we read and found nothing" (L98).
    @Test("an inquiry with no address on it has no key to search on")
    func anInquiryWithNoAddressIsOutOfScope() async throws {
        let ctx = ModelContext(try container())
        #expect(!ReplySearchScope.inScope(inquiry(ctx, email: nil), now: now))
        #expect(!ReplySearchScope.inScope(inquiry(ctx, email: "   "), now: now))
    }

    @Test("an inquiry older than the search horizon is no longer read for")
    func theHorizonApplies() async throws {
        let ctx = ModelContext(try container())
        let fresh = inquiry(ctx, loggedDaysAgo: Double(ReplySearchScope.horizonDays) - 1)
        let stale = inquiry(ctx, loggedDaysAgo: Double(ReplySearchScope.horizonDays) + 1)
        #expect(ReplySearchScope.inScope(fresh, now: now))
        #expect(!ReplySearchScope.inScope(stale, now: now))
    }

    // The window an inquiry needs is its own logging instant, exactly as a form pitch's is the moment it
    // was sent. A mark set while this inquiry was not yet in scope says nothing about it.
    @Test("an inquiry never read for widens the window back to when it was logged")
    func windowStartReachesBackToTheInquiry() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let mark = now.addingTimeInterval(-3600)
        #expect(ReplySearchScope.windowStart(for: [i], searchedThrough: mark, now: now)
                == now.addingTimeInterval(-4 * 86_400))
    }

    // MARK: honest failure

    // Gmail refusing the thread must leave the inquiry exactly as it was. A stamped thread id with no
    // detection behind it is the half state #2715 exists to avoid: the row would hold a conversation, no
    // reply, and no parent message, and answering in that window sends an unparented message (L12).
    @Test("a thread Gmail will not return attaches nothing at all")
    func anUnreadableThreadAttachesNothing() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: them, subject: "Re: spring gala")]

        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: found, now: now, token: "tok",
                 fetch: gmail(answeredInGmail(), status: 500))

        #expect(outcome.attached == 0)
        #expect(outcome.unreadable == 1)
        #expect(i.gmailThreadId == nil)
        #expect(i.conversationAttachedAt == nil)
        #expect(!i.replied)
        // #2798: and the pass SAYS that every thread it tried was refused, which is the fact that has to
        // travel. Until this, `unreadable` had no reader outside these tests, so a tick where Gmail
        // refused every inquiry thread was silent and read exactly like a tick where nobody had written.
        #expect(outcome.threadsTried == 1)
        #expect(outcome.everyThreadUnreadable)
    }

    // #2798: a RATE, not a count, which is the same rule the thread watcher already applies (#2741). One
    // refused thread beside one that attached is ordinary contention, and an alert that fires on it is one
    // Dan learns to ignore by the time a real outage comes (L77).
    @Test("one refused thread beside one that worked is not an outage")
    func oneRefusedThreadIsNotEveryThread() async throws {
        let ctx = ModelContext(try container())
        let good = inquiry(ctx)
        let bad = inquiry(ctx, email: "other@presenter.test")
        var calls = 0
        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [good, bad],
                 candidates: [message("m2", from: them, subject: "Re: spring gala"),
                              message("m3", from: "other@presenter.test", subject: "Re: spring gala")],
                 now: now, token: "tok",
                 fetch: { req in
                     calls += 1
                     // The first inquiry's two reads (metadata, then the full thread) succeed; every
                     // later one is refused, so exactly one of the two inquiries attaches.
                     return try await self.gmail(self.answeredInGmail(),
                                                 status: calls <= 2 ? 200 : 500)(req)
                 })

        #expect(outcome.threadsTried == 2)
        #expect(outcome.unreadable >= 1)
        #expect(!outcome.everyThreadUnreadable,
                "some threads were read, so this tick did establish something about somebody's replies")
    }

    // And a pass with nothing to match is not an outage either: finding no subjects is its own outcome,
    // never a failure and never a pass (L98). Without the `threadsTried > 0` half, an ordinary quiet tick
    // would report Gmail as refusing everything.
    @Test("a pass that matched nothing reports no outage")
    func nothingMatchedIsNotAnOutage() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let outcome = await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [], now: now, token: "tok",
                 fetch: gmail(answeredInGmail(), status: 500))

        #expect(outcome.threadsTried == 0)
        #expect(!outcome.everyThreadUnreadable)
    }

    // Assume it runs twice. A second pass over the same inquiry must not replace the conversation, which
    // would strand everything detection wrote about the first one.
    //
    // Two separate protections, exercised separately on purpose. The pass as a whole is guarded by the
    // scope, which drops an inquiry the moment it holds a conversation; the WRITE has its own refusal
    // underneath it, because the write is reachable without the pass. A test that only drove the pass
    // would have the outer guard answering for the inner one, and the inner one could be deleted with the
    // suite still green (measured: it was, until this test called the write directly).
    @Test("running the pass twice keeps the conversation the first one attached")
    func theSweepDoesNotReAttach() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: them, subject: "Re: spring gala")]
        let attach = InquiryConversationAttach(fromEmail: me)

        await attach.run(inquiries: [i], candidates: found, now: now, token: "tok",
                         fetch: gmail(answeredInGmail()))
        let first = i.conversationAttachedAt
        let second = await attach.run(inquiries: [i],
                                      candidates: [message("m3", from: them, subject: "another",
                                                           threadId: "thread-2")],
                                      now: now.addingTimeInterval(1800), token: "tok",
                                      fetch: gmail(answeredInGmail()))

        #expect(second.attached == 0)
        #expect(i.gmailThreadId == "thread-1")
        #expect(i.conversationAttachedAt == first)
    }

    @Test("the write itself refuses a second conversation on the same inquiry")
    func theWriteRefusesASecondConversation() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        AttachConversation.attach(threadId: "thread-1", threadJSON: answeredInGmail(), to: i,
                                  selfEmail: me, now: now)
        let attachedAt = i.conversationAttachedAt

        let second = AttachConversation.attach(threadId: "thread-2", threadJSON: answeredInGmail(), to: i,
                                               selfEmail: me, now: now.addingTimeInterval(1800))

        guard case .refused = second else { Issue.record("expected a refusal, got \(second)"); return }
        #expect(i.gmailThreadId == "thread-1")
        #expect(i.conversationAttachedAt == attachedAt)
    }

    @Test("the write refuses a thread id that names nothing")
    func theWriteRefusesAnEmptyThread() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)

        let outcome = AttachConversation.attach(threadId: "   ", threadJSON: answeredInGmail(), to: i,
                                                selfEmail: me, now: now)

        guard case .refused = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(i.gmailThreadId == nil)
        #expect(i.conversationAttachedAt == nil)
    }

    // MARK: what Overture may then do with the conversation

    // #2717's rule, on the entity whose comment said it could never apply here. Overture sent nothing on
    // this thread, so the threading repair must not find Dan's own hand-sent message and store it as
    // Overture's.
    //
    // #2796: and what Overture may then SEND here. This conversation is answerable, because detection
    // read their message off the thread and an answer threads under it, which is the whole reason for
    // attaching one. The refusal is for the state where there is no such message, asserted below and
    // driven through the send itself in `AttachedConversationContinuationTests`.
    @Test("a found conversation is one Overture never sent on")
    func aFoundConversationIsAttachedNotSent() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "Re: spring gala")],
                 now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(i.replyWatchConversationIsAttached)
        #expect(i.inboundReplyMessageId == "<second@mail.gmail.com>")
        #expect(AttachedConversation.refusalToContinue(i, displayName: "Priya Raman") == nil)
    }

    // #2796: the same sweep over a thread whose newest inbound message carries no `Message-ID` header.
    // Detection keys the reply on the Gmail resource `id`, which is always there, so the row still says
    // somebody is waiting on Dan, while `inboundReplyMessageId` stays nil and there is nothing for an
    // answer of Overture's to hang off. That is the one state the refusal exists for.
    @Test("a found conversation with no readable message of theirs cannot be continued")
    func aFoundConversationWithNoParentIsRefused() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let headerless = threadJSON([(from: "Priya Raman <\(them)>", secondsAgo: 3600,
                                      subject: "Photography for our spring gala", messageId: nil)])

        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "Re: spring gala")],
                 now: now, token: "tok", fetch: gmail(headerless))

        #expect(i.replied)
        #expect(i.inboundReplyMessageId == nil)
        #expect(AttachedConversation.refusalToContinue(i, displayName: "Priya Raman")
                == AttachedConversationCopy.cannotContinue(groupName: "Priya Raman"))
    }

    // Self-healing, exactly as the Recipient side is: the moment Overture's own reply lands on the thread
    // there IS a message of its own to thread off, and a rule keyed on the channel alone would go on
    // refusing long after its reason had gone (L68).
    @Test("once Overture answers on it, the conversation stops being merely attached")
    func sendingOnItHealsTheRefusal() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "Re: spring gala")],
                 now: now, token: "tok", fetch: gmail(answeredInGmail()))
        #expect(i.replyWatchConversationIsAttached)

        i.gmailMessageId = "<overtures@mail.gmail.com>"
        #expect(!i.replyWatchConversationIsAttached)
    }

    // MARK: the shipping runtime

    // L3: built is not wired, and wired is not proven. The attach reaches the store only through the
    // reconcile tick's sweep, which is where #2713's candidates get their reader.
    @Test("the reconcile tick's sweep attaches an inquiry's conversation")
    func theSweepWiresItUp() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let found = [message("m2", from: them, subject: "Re: spring gala")]

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now,
                 search: { .searched(candidates: found, searchedThrough: now, saveFailed: false) },
                 attach: { inquiries, candidates in
                     await InquiryConversationAttach(fromEmail: self.me)
                         .run(inquiries: inquiries, candidates: candidates, now: self.now,
                              token: "tok", fetch: self.gmail(self.answeredInGmail()))
                 })

        #expect(outcome == .swept(proposed: 0, attached: 1, saveFailed: false))
        #expect(i.gmailThreadId == "thread-1")
    }

    // Every test above injects the attach, which proves the sweep calls whatever it is given and says
    // nothing about what it is given by DEFAULT. That is the half L3 is about: an injected seam makes a
    // pass provable and a real wiring is a separate claim. Scoped to the one function rather than searched
    // over the whole file, or a mention anywhere in it would answer for the branch this is about (L135).
    @Test("the sweep's own default is the real attach, not only whatever a test hands it")
    func theDefaultAttachIsTheRealOne() throws {
        let source = SourceGuardHelper.source("Overture/Integration/ReplyProposalSweep.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "run", in: source))
        #expect(SourceGuardHelper.containsCode("InquiryConversationAttach(fromEmail: fromEmail)", in: body))
    }

    // MARK: the row says so

    // Overture has changed what this inquiry is, on the strength of something it read in his mailbox, so
    // the row has to say where the conversation came from. Nothing else on the row carries that fact: the
    // state line says whether he has answered, never how Overture came to know.
    @Test("the row says the conversation came from Gmail rather than from a send")
    func theRowNamesWhereTheConversationCameFrom() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(InquiryCopy.foundInGmailBadge(attachedAt: i.conversationAttachedAt) == nil)

        await InquiryConversationAttach(fromEmail: me)
            .run(inquiries: [i], candidates: [message("m2", from: them, subject: "Re: spring gala")],
                 now: now, token: "tok", fetch: gmail(answeredInGmail()))

        #expect(InquiryCopy.foundInGmailBadge(attachedAt: i.conversationAttachedAt) != nil)
    }
}
