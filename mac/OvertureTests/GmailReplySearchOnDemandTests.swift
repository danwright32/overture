import Testing
import Foundation
import SwiftData

// #3708 (milestone 82, Phase 2): the manual picker reads the mailbox ON DEMAND, with a window anchored
// on the pitch, instead of riding the tick's scope.
//
// WHY NOT WIDEN `ReplySearchScope`, which is the obvious fix and the wrong one. That scope is what the
// reconcile tick reads Gmail on automatically, every thirty minutes, and it refuses anything holding a
// conversation precisely so the read stays bounded. Widening it to every emailed pitch would put a
// mailbox read behind a case that is rare, and a sent pitch never ages off until Dan closes it out, so
// the window would widen by a day every day. The horizon comment in that file already says so.
//
// This route is Dan asking on purpose. It pays once, so it may look back to the pitch itself, and it
// touches neither the automatic scope nor the high-water mark that scope resumes from.
//
// THE ORDER IS THE OTHER HALF, and it is not a detail. The tick reads OLDEST first because a truncated
// tick has to be resumable: the mark may only advance over mail that was really examined. A one-shot
// read resumes from nothing, so oldest-first would spend its whole budget on the oldest mail in the
// window and report "found nothing" while the reply sat unread at the top of the inbox, which is the
// emptiest possible failure wearing the cleanest possible answer (L98).
//
// Every test injects `now` (L130) and none of them reaches the network (L2).
@MainActor
@Suite("Reading the mailbox on demand for a reply on another thread (#3708)")
struct GmailReplySearchOnDemandTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let day: TimeInterval = 86_400
    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "reply-search-on-demand-\(UUID().uuidString)"))
    }

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // #3706's shape: emailed, holding the thread the pitch went out on, no reply recorded.
    @discardableResult
    private func emailedPitch(_ ctx: ModelContext, on p: Prospect, daysAgo: Double = 9) -> Recipient {
        let r = Recipient(id: "them@act.example", email: "them@act.example", provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-daysAgo * day)
        r.gmailMessageId = "m-out"
        r.gmailThreadId = "t-out"
        p.addRecipient(r)
        return r
    }

    private func listJSON(_ ids: [String], nextPageToken: String? = nil) -> Data {
        var body: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": $0] },
                                   "resultSizeEstimate": ids.count]
        if let nextPageToken { body["nextPageToken"] = nextPageToken }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func metadataJSON(id: String, from: String, subject: String, sentAt: Date) -> Data {
        GmailFixture(selfEmail: "dan@danwrightphotography.com", threadId: id)
            .message(.init(from: from, subject: subject, id: id,
                           internalDateMillis: Int64(sentAt.timeIntervalSince1970 * 1000)))
    }

    // The same fake mailbox `GmailReplySearchTests` drives the tick through, so both entry points are
    // exercised against one Gmail rather than two ideas of one.
    private func mailbox(_ messages: [(id: String, from: String, subject: String, sentAt: Date)],
                         pageSize: Int = 100, listStatus: Int = 200, getStatus: Int = 200,
                         onRequest: @escaping (URLRequest) -> Void = { _ in })
    -> (URLRequest) async throws -> (Data, URLResponse) {
        let ordered = messages.sorted { $0.sentAt > $1.sentAt }   // Gmail answers newest first
        return { req in
            onRequest(req)
            let url = req.url!.absoluteString
            func respond(_ data: Data, _ code: Int) -> (Data, URLResponse) {
                (data, HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("/messages?") || url.hasSuffix("/messages") {
                guard listStatus == 200 else { return respond(Data(), listStatus) }
                let token = URLComponents(string: url)?.queryItems?
                    .first { $0.name == "pageToken" }?.value
                let start = token.flatMap(Int.init) ?? 0
                let slice = Array(ordered.dropFirst(start).prefix(pageSize))
                let next = start + pageSize < ordered.count ? "\(start + pageSize)" : nil
                return respond(self.listJSON(slice.map(\.id), nextPageToken: next), 200)
            }
            guard getStatus == 200 else { return respond(Data(), getStatus) }
            let id = String(url.split(separator: "/").last!.split(separator: "?").first!)
            let m = ordered.first { $0.id == id }!
            return respond(self.metadataJSON(id: m.id, from: m.from, subject: m.subject, sentAt: m.sentAt), 200)
        }
    }

    // MARK: the anchor

    // Two anchors, side by side, answering different questions. `replySearchAnchor` is the automatic
    // pass's and is nil on an emailed pitch by design; this one is what Dan asking by hand reads back to.
    @Test("an emailed pitch anchors on the day it was sent")
    func anEmailedPitchAnchorsOnItsSend() throws {
        let ctx = ModelContext(try container())
        let r = emailedPitch(ctx, on: show(ctx))

        #expect(r.replySearchAnchor == nil, "the premise: the automatic pass has no anchor here")
        #expect(r.manualSearchAnchor == r.sentAt)
    }

    @Test("a form pitch anchors on the day Dan recorded it, not on any later send stamp")
    func aFormPitchAnchorsOnWhatDanRecorded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "form:https://act.example/contact", email: nil, provenance: .act)
        r.outreachChannel = .contactForm
        r.formOutreachURL = "https://act.example/contact"
        r.formOutreachRecordedAt = now.addingTimeInterval(-30 * day)
        r.sentAt = now.addingTimeInterval(-2 * day)
        r.sendState = .sent
        p.addRecipient(r)

        #expect(r.manualSearchAnchor == r.formOutreachRecordedAt)
    }

    // No window at all is its own answer, never a read that found nothing (L98). It is why the picker
    // can say which of the two happened.
    @Test("a contact that was never sent has no anchor")
    func nothingSentHasNoAnchor() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "them@act.example", email: "them@act.example", provenance: .act)
        p.addRecipient(r)

        #expect(r.manualSearchAnchor == nil)
    }

    // MARK: it reads where the automatic pass will not

    // The whole point of the phase. This contact is refused by the tick twice over (it holds a
    // conversation, and it is months past the horizon), and the on-demand read still finds the message.
    @Test("it reads for a contact the automatic scope refuses")
    func itReadsWhereTheTickWillNot() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p, daysAgo: 90)
        #expect(ReplySearchScope.inScope(r, now: now) == false, "the premise of this test")

        let anchor = try #require(r.manualSearchAnchor)
        var asked: [String] = []
        let fetch = mailbox([(id: "m1", from: "Casey <casey@examplemail.com>",
                              subject: "About the show", sentAt: now.addingTimeInterval(-2 * day))],
                            onRequest: { asked.append($0.url!.absoluteString) })

        let outcome = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok", fetch: fetch)

        guard case .read(let candidates, let stoppedShort) = outcome else {
            Issue.record("expected a completed read, got \(outcome)"); return
        }
        #expect(candidates.map(\.messageId) == ["m1"])
        #expect(stoppedShort == nil)
        let listCall = try #require(asked.first { $0.contains("/messages?") })
        #expect(listCall.contains("after:\(Int(anchor.timeIntervalSince1970))"),
                "the window is not anchored on the pitch")
    }

    // The automatic pass resumes from the high-water mark and stamps every target it read for. A read
    // Dan asked for covers a DIFFERENT window and a different set, so advancing either would step the
    // tick over mail it never examined, permanently (L5, L512).
    @Test("it moves neither the high-water mark nor any contact's searched stamp")
    func itLeavesTheAutomaticPassAlone() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        let defaults = try scratchDefaults()
        let anchor = try #require(r.manualSearchAnchor)

        _ = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok",
                          fetch: mailbox([(id: "m1", from: "Casey <casey@examplemail.com>",
                                           subject: "Re: hi", sentAt: now.addingTimeInterval(-day))]))

        #expect(r.replyCandidateSearchedAt == nil)
        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == nil)
    }

    // MARK: it stops at the top of the inbox, not the bottom of the window

    @Test("it examines the newest mail first and says when it stopped short")
    func itReadsNewestFirstAndSaysWhenItStopped() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p, daysAgo: 40)
        let anchor = try #require(r.manualSearchAnchor)
        let messages = (1...5).map { i in
            (id: "m\(i)", from: "Casey <casey\(i)@examplemail.com>", subject: "Note \(i)",
             sentAt: now.addingTimeInterval(-Double(i) * day))
        }

        let outcome = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok", cap: 3, fetch: mailbox(messages))

        guard case .read(let candidates, let stoppedShort) = outcome else {
            Issue.record("expected a completed read, got \(outcome)"); return
        }
        #expect(Set(candidates.map(\.messageId)) == ["m1", "m2", "m3"],
                "the budget went on the oldest mail in the window instead of the newest")
        #expect(stoppedShort == .tooManyMessages)
    }

    @Test("a read that saw the whole window says it did not stop short")
    func aCompleteReadSaysSo() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        let anchor = try #require(r.manualSearchAnchor)

        let outcome = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok", cap: 300,
                          fetch: mailbox([(id: "m1", from: "Casey <casey@examplemail.com>",
                                           subject: "Re: hi", sentAt: now.addingTimeInterval(-day))]))

        #expect(outcome == .read(candidates: [
            GmailReplySearch.InboundMessage(messageId: "m1", threadId: "m1",
                                            fromAddress: "casey@examplemail.com", fromName: "Casey",
                                            subject: "Re: hi",
                                            sentAt: now.addingTimeInterval(-day), listUnsubscribe: nil)
        ], stoppedShort: nil))
    }

    // Dan's own sent copy would name HIM as the person who wrote back.
    @Test("it never offers Dan his own mail")
    func itNeverOffersHisOwnMail() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        let anchor = try #require(r.manualSearchAnchor)

        let outcome = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok",
                          fetch: mailbox([(id: "m1", from: "Dan <\(me)>", subject: "the pitch",
                                           sentAt: now.addingTimeInterval(-day))]))

        #expect(outcome == .read(candidates: [], stoppedShort: nil))
    }

    // MARK: a failure is never "nothing found"

    @Test("a refused list call is a failure naming Gmail, never an empty read")
    func aRefusedListIsAFailure() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        let anchor = try #require(r.manualSearchAnchor)

        let outcome = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok", fetch: mailbox([], listStatus: 401))

        guard case .failed(let reason) = outcome else {
            Issue.record("a 401 must not read as a completed read, got \(outcome)"); return
        }
        #expect(reason.contains("401"))
    }

    @Test("a refused message read is a failure, never a partial list Dan would pick from")
    func aRefusedMetadataReadIsAFailure() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        let anchor = try #require(r.manualSearchAnchor)

        let outcome = await GmailReplySearch(fromEmail: me)
            .readOnDemand(since: anchor, token: "tok",
                          fetch: mailbox([(id: "m1", from: "Casey <casey@examplemail.com>",
                                           subject: "Re: hi", sentAt: now.addingTimeInterval(-day))],
                                         getStatus: 429))

        guard case .failed(let reason) = outcome else {
            Issue.record("a 429 must not read as a completed read, got \(outcome)"); return
        }
        #expect(reason.contains("429"))
    }

    // MARK: the picker uses it

    @Test("the picker reads on demand rather than riding the tick's scope")
    func thePickerReadsOnDemand() throws {
        let picker = SourceGuardHelper.source("Overture/UI/LinkReplyPicker.swift")
        #expect(!picker.isEmpty)
        let readsOnDemand = picker.contains("searchOnDemand(since:")
        // The needle has to be text no PROSE about the old call can hold, or the guard is answered by
        // the comment explaining the change rather than by the code (L135). `.search(in: context)` is
        // the call as it was actually written; the comment beside it names `search(in:)` without the
        // argument for exactly this reason.
        let ridesTheTick = picker.contains(".search(in: context)")
        let saysWhenItStopped = picker.contains("stoppedShort")
        let saysWhenThereIsNoWindow = picker.contains("manualSearchAnchor")
        #expect(readsOnDemand, "the picker does not use the on-demand read")
        #expect(!ridesTheTick,
                "the picker still rides the automatic scope, which refuses every emailed pitch")
        #expect(saysWhenItStopped, "a truncated read renders as one that found nothing (L98)")
        #expect(saysWhenThereIsNoWindow,
                "a contact with no pitch date reads as one whose mailbox held no reply")
    }
}
