import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let threadingRepairGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2649: #2647 fixed what Overture STORES from the next send onward. It did not touch what is already in
// the store, so every `gmailMessageId` written by a past send is an `@danwrightphotography.com` id Gmail
// discarded, and the next follow-up on each of those live conversations would still ship a dangling
// reference in every client that threads on headers rather than on Gmail's internal threadId.
//
// Already sent mail cannot be repaired. Live conversations can, and that is the whole point: these are
// the shows Dan is still waiting on, so their next nudge is the one that matters.
//
// Sizing, measured on the live Release store 2026-08-13: 6 recipients hold a `gmailThreadId`, all 6
// carrying a minted `@danwrightphotography.com` id, and 0 inquiries. Small enough that the repair is an
// ordinary pass rather than a migration, and small enough that it can be read back one thread at a time.
//
// The constraints below are the issue's, and each has a test here: read only, never blank a stored id,
// never guess one, report the outcomes separately, and be a no-op on a second pass.
@MainActor
@Suite("A follow-up references the id Gmail really assigned (#2649)")
struct GmailThreadingRepairTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let minted = "<AA037CFE-0D5F-4B13-8E67-5B765CD60A56@danwrightphotography.com>"
    private let real = "<CADqB9x8h1@mail.gmail.com>"

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func sentContact(_ ctx: ModelContext, on p: Prospect, address: String = "them@example.com",
                             thread: String = "t1", storedMessageId: String?) -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.gmailThreadId = thread
        r.gmailMessageId = storedMessageId
        r.sendState = .sent
        r.sentAt = Date()
        p.addRecipient(r)
        return r
    }

    // One Gmail thread as the API returns it for `format=metadata`. `internalDate` is what orders the
    // messages, deliberately, rather than their position in the array.
    //
    // #2918 put `labelIds` on these: the repair refuses to reference a message that claims nothing about
    // having been sent. #2928 moved the shape into `GmailFixture`.
    private func threadJSON(_ messages: [(from: String, messageId: String?, at: Int64)]) -> Data {
        threadingRepairGmail.thread(messages.map { m in
            .init(from: m.from, messageID: m.messageId, internalDateMillis: m.at)
        })
    }

    private func responder(_ body: @escaping (URLRequest) -> (Data, Int))
    -> (URLRequest) async throws -> (Data, URLResponse) {
        { req in
            let (data, code) = body(req)
            return (data, HTTPURLResponse(url: req.url!, statusCode: code,
                                          httpVersion: nil, headerFields: nil)!)
        }
    }

    // The repair itself, on the shape every one of the six live rows is in.
    @Test func theRealMessageIdReplacesTheOneGmailDiscarded() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.gmailMessageId == real)
        #expect(outcome.repaired == 1)
        #expect(outcome == GmailThreadingRepair.Outcome(repaired: 1))
    }

    // "Running it twice must be a no-op on the second pass." Stronger than writing nothing: the repaired
    // row now holds an id Gmail assigned, so the second pass does not select it and never reaches Gmail
    // for it at all. Asserting the read count as well as the outcome, because a version that re-fetched
    // every thread and then decided nothing had changed would satisfy the words "no-op" while paying for
    // the whole pass again on every tick.
    @Test func aSecondPassReadsNothingAtAll() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])
        let repair = GmailThreadingRepair(fromEmail: me)
        var reads = 0
        let fetch = responder { _ in reads += 1; return (thread, 200) }

        let first = await repair.repairMessageIds(in: ctx, token: "tok", fetch: fetch)
        let second = await repair.repairMessageIds(in: ctx, token: "tok", fetch: fetch)

        #expect(r.gmailMessageId == real)
        #expect(first == GmailThreadingRepair.Outcome(repaired: 1))
        #expect(second == GmailThreadingRepair.Outcome())
        #expect(reads == 1)
    }

    // A thread Gmail will not return leaves the stored value ALONE. Never blanked: a blank id silently
    // turns the next follow-up into a fresh unthreaded message, which is a different defect rather than a
    // fix (L5). And "could not reach Gmail" is its own outcome, never folded into "nothing to do" (L11).
    @Test func aThreadGmailWillNotReturnLeavesTheStoredIdAlone() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (Data(), 500) })

        #expect(r.gmailMessageId == minted)
        #expect(outcome == GmailThreadingRepair.Outcome(unreadable: 1))
    }

    // A thread that reads fine but carries nothing Dan sent: refuse rather than reach for the nearest
    // message. Substituting somebody else's Message-ID would thread his next mail onto a stranger's
    // message and look exactly like success (L75).
    @Test func aThreadWithNothingDanSentIsRefusedRatherThanGuessed() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: "them@example.com", messageId: "<theirs@example.com>", at: 2_000)])

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.gmailMessageId == minted)
        #expect(outcome == GmailThreadingRepair.Outcome(refused: 1))
    }

    // Dan's newest message on the thread carries no Message-ID header at all. Refused for the same reason,
    // and specifically NOT by falling back to an older message of his: the follow-up must reference the
    // message it is actually following up.
    @Test func aSentMessageWithNoMessageIdHeaderIsRefused() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: me, messageId: "<older@mail.gmail.com>", at: 1_000),
                                 (from: me, messageId: nil, at: 3_000)])

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.gmailMessageId == minted)
        #expect(outcome == GmailThreadingRepair.Outcome(refused: 1))
    }

    // The one a follow-up should reference is the NEWEST message of Dan's, ordered by internalDate rather
    // than by where Gmail happened to put it in the array.
    @Test func theNewestMessageDanSentIsTheOneReferenced() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: me, messageId: real, at: 5_000),
                                 (from: "them@example.com", messageId: "<theirs@example.com>", at: 4_000),
                                 (from: me, messageId: "<older@mail.gmail.com>", at: 1_000)])

        _ = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.gmailMessageId == real)
    }

    // #2046 sends one email to several contacts, so several rows share one thread. The newest message Dan
    // sent on that thread is a fact about the CONVERSATION, true of every contact on it, so it is read
    // once and applied to all of them (L66). Asserting the read count as well as the result, because
    // fetching the same thread once per row is the version that looks identical from the outside.
    @Test func contactsSharingOneThreadAreAllRepairedFromOneRead() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let a = sentContact(ctx, on: p, address: "a@example.com", thread: "shared", storedMessageId: minted)
        let b = sentContact(ctx, on: p, address: "b@example.com", thread: "shared", storedMessageId: minted)
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])
        var reads = 0

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in reads += 1; return (thread, 200) })

        #expect(a.gmailMessageId == real)
        #expect(b.gmailMessageId == real)
        #expect(outcome == GmailThreadingRepair.Outcome(repaired: 2))
        #expect(reads == 1)
    }

    // An inquiry carries its own thread and its own stored id, and is its own recipient. It is repaired by
    // the same pass rather than by a second copy of it: the store holds none today, so a separate path for
    // inquiries would be one nothing ever ran (L30).
    @Test func anInquiryIsRepairedTheSameWay() async throws {
        let ctx = ModelContext(try container())
        let inquiry = Inquiry(source: .directEmail, inquirerName: "A Person",
                              inquirerEmail: "them@example.com", eventName: "An Evening")
        inquiry.gmailThreadId = "t-inquiry"
        inquiry.gmailMessageId = minted
        inquiry.sentAt = Date()
        ctx.insert(inquiry)
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(inquiry.gmailMessageId == real)
        #expect(outcome == GmailThreadingRepair.Outcome(repaired: 1))
    }

    // A contact that was never sent has no thread to read, so the pass never reaches Gmail for it and it
    // is not counted as anything. Zero subjects is not a success to report (L98): an empty outcome here
    // means there was nothing in this state, which is what the caller says.
    @Test func aContactWithNoThreadIsNeverTouched() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "pending@example.com", email: "pending@example.com", provenance: .act)
        p.addRecipient(r)
        var reads = 0

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok",
                              fetch: responder { _ in reads += 1; return (Data(), 200) })

        #expect(r.gmailMessageId == nil)
        #expect(reads == 0)
        #expect(outcome == GmailThreadingRepair.Outcome())
    }

    // A row that never stored an id at all is still repaired: it has the same dangling next follow-up, and
    // nil is not a value worth protecting the way a real id would be.
    @Test func aRowHoldingNoIdAtAllIsFilledIn() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: nil)
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.gmailMessageId == real)
        #expect(outcome == GmailThreadingRepair.Outcome(repaired: 1))
    }

    // The pass selects only rows still holding an id Gmail cannot have assigned, which is what makes it
    // one pass with no marker file to keep honest. A row already carrying a real `mail.gmail.com` id is
    // not even read: asserting the read COUNT, because a version that fetched every thread and then
    // decided nothing had changed would pass every other test in this file.
    @Test func aRowAlreadyHoldingGmailsOwnIdIsNotEvenRead() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: real)
        var reads = 0

        let outcome = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok",
                              fetch: responder { _ in reads += 1; return (Data(), 200) })

        #expect(r.gmailMessageId == real)
        #expect(reads == 0)
        #expect(outcome == GmailThreadingRepair.Outcome())
    }

    // The selection is the minting rule read backwards, so the two sit in one file and cannot drift.
    @Test("an id under our own sending domain is one we minted, and Gmail's is not",
          arguments: [("<AA037CFE@danwrightphotography.com>", true),
                      ("<CADqB9x8h1@mail.gmail.com>", false),
                      ("<UPPER@DanWrightPhotography.com>", true),
                      (nil as String?, true)])
    func theMintedIdTestRecognisesWhatOvertureWrote(_ pair: (String?, Bool)) {
        #expect(GmailMessage.isLocallyMintedMessageID(pair.0,
                                                      senderEmail: "dan@danwrightphotography.com") == pair.1)
    }

    // A refusal is RECORDED on the row, not just counted in the outcome. The count is gone the moment the
    // pass returns; the flag is what a surface can read afterwards, and #2647 already renders it through
    // the `.sendThreadingDegraded` focus.
    @Test func aRefusalIsRecordedOnTheRow() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: "them@example.com", messageId: "<theirs@example.com>", at: 2_000)])

        _ = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.threadingDegraded == true)
        #expect(r.gmailMessageId == minted)
    }

    // And a thread Gmail simply could not be read does NOT mark the row, because that says nothing about
    // whether this conversation can be threaded. Two causes, two outcomes (L11).
    @Test func anUnreadableThreadDoesNotMarkTheRowAsUnthreadable() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)

        _ = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (Data(), 503) })

        #expect(r.threadingDegraded == false)
    }

    // A repair clears a flag an earlier failure set, so the warning does not outlive the reason for it.
    @Test func aRepairClearsAFlagAnEarlierFailureSet() async throws {
        let ctx = ModelContext(try container())
        let r = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        r.threadingDegraded = true            // #2647: this send's read back failed
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])

        _ = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { _ in (thread, 200) })

        #expect(r.gmailMessageId == real)
        #expect(r.threadingDegraded == false)
    }

    // The pass never sends. Asserted rather than intended: every request it makes is a GET, so a change
    // that reached for the send endpoint would go red here rather than in Dan's outbox.
    @Test func thePassNeverSends() async throws {
        let ctx = ModelContext(try container())
        _ = sentContact(ctx, on: show(ctx), storedMessageId: minted)
        let thread = threadJSON([(from: me, messageId: real, at: 1_000)])
        var methods: [String] = []
        var urls: [String] = []

        _ = await GmailThreadingRepair(fromEmail: me)
            .repairMessageIds(in: ctx, token: "tok", fetch: responder { req in
                methods.append(req.httpMethod ?? "GET")
                urls.append(req.url?.absoluteString ?? "")
                return (thread, 200)
            })

        #expect(methods.allSatisfy { $0 == "GET" })
        #expect(urls.allSatisfy { !$0.contains("/send") })
    }
}
