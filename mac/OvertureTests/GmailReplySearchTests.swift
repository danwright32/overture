import Testing
import Foundation
import SwiftData

// #2713: read the mailbox for a reply to a pitch Overture cannot watch.
//
// A pitch sent through a contact form or a social DM deliberately never stamps `gmailThreadId`
// (`FormOutreach.recordFormOutreach`), so there is nothing for the reply watcher to fetch and no way
// to be told when the presenter writes back by email. Measured live 2026-08-14: a form pitch through
// caseengaines.com was answered from a gmail.com address, and Overture knew nothing about it while the
// row went on saying it could not see a reply to that one.
//
// The two things this suite exists to hold, because both are the shape of a defect this repo keeps
// meeting rather than a nicety:
//
// 1. NOTHING FOUND is reachable from exactly one outcome. A token expiry, a 429 and an unreadable
//    message must never render as a cheerful "they never wrote" (L10, L11, L98). Every failure test
//    below asserts the outcome is `.failed`, and separately that it is NOT `.searched`, because the
//    whole risk is the two collapsing into one answer.
// 2. The search is SELF LIMITING. A sent pitch never ages off until Dan closes it out, so without a
//    high-water mark and a horizon this tick would re-read a widening window of mail every thirty
//    minutes for ever.
@MainActor
@Suite("Reading the mailbox for a reply Overture cannot watch (#2713)")
struct GmailReplySearchTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let day: TimeInterval = 86_400
    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "reply-search-\(UUID().uuidString)"))
    }

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect, id: String = "form:https://act.com/contact",
                           daysAgo: Double = 3) -> Recipient {
        let r = Recipient(id: id, email: nil, provenance: .act)
        r.contactFormURL = "https://act.com/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-daysAgo * day)
        r.formOutreachURL = "https://act.com/contact"
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-daysAgo * day)
        p.addRecipient(r)
        return r
    }

    // MARK: the recorded shapes

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: RepoRoot.url.appendingPathComponent("fixtures/gmail-reply-search")
            .appendingPathComponent(name))
    }

    @Test("the recorded messages.list response parses into ids and a page token")
    func parsesTheRecordedListShape() throws {
        let page = try #require(GmailReplySearch.parseList(try fixture("messages-list-page1.json")))

        #expect(page.messages.map(\.id) == ["198f2a1c9d0e4b77", "198f13b8ac55d201"])
        #expect(page.messages.map(\.threadId) == ["198f2a1c9d0e4b77", "198f0be2117a3345"])
        #expect(page.nextPageToken == "10428855297661234567")
    }

    @Test("a final messages.list page carries no token")
    func aFinalPageHasNoToken() throws {
        let page = try #require(GmailReplySearch.parseList(try fixture("messages-list-page2.json")))

        #expect(page.messages.map(\.id) == ["198ea77e31c0b9f4"])
        #expect(page.nextPageToken == nil)
    }

    // `internalDate` is a STRING holding milliseconds since the epoch, which is the field most likely
    // to be read wrongly: taken as seconds it dates every message to 1970 and the window drops the lot.
    @Test("the recorded metadata response parses into a sender, a subject and the instant it was sent")
    func parsesTheRecordedMetadataShape() throws {
        let m = try #require(GmailReplySearch.parseMetadata(try fixture("message-metadata.json")))

        #expect(m.messageId == "198f2a1c9d0e4b77")
        #expect(m.threadId == "198f2a1c9d0e4b77")
        #expect(m.fromAddress == "casey.grainger@examplemail.com")
        #expect(m.fromName == "Casey Grainger")
        #expect(m.subject == "Re: Photography for the anniversary celebration")
        #expect(m.sentAt == Date(timeIntervalSince1970: 1_785_900_000))
    }

    // The fixture's content is written rather than captured (see its README), so the one thing a real
    // capture would have proved beyond the published reference is held here instead: the parser reads
    // named fields and ignores everything else, so a field Google adds cannot break it.
    @Test("a response carrying fields the parser does not know still parses")
    func aResponseCarryingUnknownFieldsStillParses() throws {
        var raw = try #require(try JSONSerialization.jsonObject(with: try fixture("message-metadata.json"))
                               as? [String: Any])
        raw["somethingGoogleAddedLater"] = ["nested": true]
        var payload = try #require(raw["payload"] as? [String: Any])
        payload["mimeType"] = "multipart/alternative"
        raw["payload"] = payload

        let m = try #require(GmailReplySearch.parseMetadata(try JSONSerialization.data(withJSONObject: raw)))

        #expect(m.fromAddress == "casey.grainger@examplemail.com")
    }

    // MARK: driving the search

    private func listJSON(_ ids: [String], nextPageToken: String? = nil) -> Data {
        var body: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": $0] },
                                   "resultSizeEstimate": ids.count]
        if let nextPageToken { body["nextPageToken"] = nextPageToken }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func metadataJSON(id: String, from: String, subject: String, sentAt: Date) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": id, "threadId": id, "internalDate": "\(Int64(sentAt.timeIntervalSince1970 * 1000))",
            "payload": ["headers": [["name": "From", "value": from],
                                    ["name": "Subject", "value": subject]]],
        ])
    }

    // One fake mailbox: a list call answers with every id whose message is in the window, and a get
    // answers with that message. Nothing here is a stub of Overture's own code, only of Gmail's.
    private func mailbox(_ messages: [(id: String, from: String, subject: String, sentAt: Date)],
                         pageSize: Int = 100, listStatus: Int = 200, getStatus: Int = 200,
                         onRequest: @escaping (URLRequest) -> Void = { _ in })
    -> (URLRequest) async throws -> (Data, URLResponse) {
        // Gmail answers newest first.
        let ordered = messages.sorted { $0.sentAt > $1.sentAt }
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

    @Test("a message in the window comes back as a candidate")
    func aMessageInTheWindowIsACandidate() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let sentAt = now.addingTimeInterval(-1 * day)
        let fetch = mailbox([(id: "m1", from: "Casey <casey@examplemail.com>", subject: "Re: your note", sentAt: sentAt)])

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(), fetch: fetch)

        guard case .searched(let candidates, _, _) = outcome else {
            Issue.record("expected a completed search, got \(outcome)"); return
        }
        #expect(candidates.map(\.messageId) == ["m1"])
        #expect(candidates.first?.fromAddress == "casey@examplemail.com")
    }

    @Test("a mailbox with nothing in the window is its own answer, not a failure")
    func nothingInTheWindowIsItsOwnAnswer() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(), fetch: mailbox([]))

        #expect(outcome == .searched(candidates: [], searchedThrough: nil, saveFailed: false))
    }

    // L98 on the subject list rather than on the result: a tick with no live form pitch has not
    // searched a mailbox and found nothing, it has not searched at all. Collapsing the two would make
    // "Dan has no unwatchable pitches open" indistinguishable from "the mailbox holds no reply", and
    // the second is the one a surface is entitled to act on.
    @Test("a tick with no contact in scope is not an empty search")
    func noContactInScopeIsNotAnEmptySearch() async throws {
        let ctx = ModelContext(try container())
        show(ctx)
        var asked = false

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(),
                           fetch: mailbox([], onRequest: { _ in asked = true }))

        #expect(outcome == .nothingInScope)
        #expect(asked == false, "a tick with nothing in scope must not call Gmail at all")
    }

    // MARK: failures are never "nothing found"

    @Test("a refused list call reports a failure naming Gmail, never an empty result")
    func aRefusedListIsAFailure() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(),
                           fetch: mailbox([], listStatus: 401))

        guard case .failed(let reason) = outcome else {
            Issue.record("a 401 must not read as a completed search, got \(outcome)"); return
        }
        #expect(reason.contains("401"))
    }

    @Test("a refused message read reports a failure, never a partial result")
    func aRefusedMetadataReadIsAFailure() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let fetch = mailbox([(id: "m1", from: "Casey <casey@examplemail.com>", subject: "Re: hi",
                              sentAt: now.addingTimeInterval(-1 * day))], getStatus: 429)

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(), fetch: fetch)

        guard case .failed(let reason) = outcome else {
            Issue.record("a 429 must not read as a completed search, got \(outcome)"); return
        }
        #expect(reason.contains("429"))
    }

    // A failed tick must leave the mark exactly where it was, or the messages it never examined are
    // skipped for ever and the failure becomes permanent data loss rather than one bad tick.
    @Test("a failed tick does not advance the high-water mark")
    func aFailedTickDoesNotAdvanceTheMark() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let defaults = try scratchDefaults()

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: defaults, fetch: mailbox([], listStatus: 500))

        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == nil)
    }

    // MARK: bounding the cost

    @Test("the mark advances to the newest message this tick examined")
    func theMarkAdvancesToTheNewestExamined() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let defaults = try scratchDefaults()
        let newest = now.addingTimeInterval(-1 * day)
        let fetch = mailbox([(id: "m1", from: "a@x.com", subject: "one", sentAt: now.addingTimeInterval(-2 * day)),
                             (id: "m2", from: "b@x.com", subject: "two", sentAt: newest)])

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: defaults, fetch: fetch)

        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == newest)
    }

    @Test("the mark never moves backwards")
    func theMarkNeverMovesBackwards() async throws {
        let defaults = try scratchDefaults()
        let later = now.addingTimeInterval(-1 * day)
        ReplySearchHighWater.record(later, into: defaults)

        ReplySearchHighWater.record(now.addingTimeInterval(-5 * day), into: defaults)

        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == later)
    }

    // Gmail answers newest first, so a tick that read the newest N and advanced the mark past them
    // would step over every older message it never looked at. Reading oldest first and advancing only
    // to what was examined is what makes a truncated tick resumable instead of lossy.
    @Test("a truncated tick advances the mark only to what it examined, so the next tick continues")
    func aTruncatedTickResumesRatherThanSkipping() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p, daysAgo: 20)
        let defaults = try scratchDefaults()
        let cap = GmailReplySearch.maxMessagesPerTick
        let messages = (0..<(cap + 5)).map {
            (id: "m\($0)", from: "a\($0)@x.com", subject: "s\($0)",
             sentAt: now.addingTimeInterval(-Double(cap + 5 - $0) * 3600))
        }

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: defaults, fetch: mailbox(messages))

        guard case .searched(let candidates, _, _) = outcome else {
            Issue.record("expected a completed search, got \(outcome)"); return
        }
        #expect(candidates.count == cap)
        // The oldest `cap` messages, not the newest, and the mark sits on the newest of THOSE.
        #expect(candidates.map(\.messageId) == messages.prefix(cap).map(\.id))
        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == messages[cap - 1].sentAt)
    }

    @Test("a second tick reads only the mail that arrived since the mark")
    func aSecondTickReadsOnlyWhatIsNew() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p, daysAgo: 10)
        let defaults = try scratchDefaults()
        let mark = now.addingTimeInterval(-1 * day)
        ReplySearchHighWater.record(mark, into: defaults)
        r.replyCandidateSearchedAt = mark
        var queries: [String] = []

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: defaults,
                           fetch: mailbox([], onRequest: { req in
                               if let q = URLComponents(string: req.url!.absoluteString)?.queryItems?
                                   .first(where: { $0.name == "q" })?.value { queries.append(q) }
                           }))

        #expect(queries.first?.contains("after:\(Int(mark.timeIntervalSince1970))") == true)
    }

    // MARK: the window is exact, not approximate

    // Gmail's `after:` is a search operator, not a filter this code controls, so anything it lets
    // through that predates the window is dropped here. Without this the first tick on a new contact
    // would propose a message that arrived before the pitch was even made.
    @Test("a message older than the window is not a candidate even when Gmail returns it")
    func aMessageOlderThanTheWindowIsDropped() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p, daysAgo: 3)
        let fetch = mailbox([(id: "old", from: "a@x.com", subject: "before the pitch",
                              sentAt: now.addingTimeInterval(-9 * day)),
                             (id: "new", from: "b@x.com", subject: "after the pitch",
                              sentAt: now.addingTimeInterval(-1 * day))])

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(), fetch: fetch)

        guard case .searched(let candidates, _, _) = outcome else {
            Issue.record("expected a completed search, got \(outcome)"); return
        }
        #expect(candidates.map(\.messageId) == ["new"])
    }

    @Test("the query excludes Dan's own mail and the chat pseudo-folder")
    func theQueryExcludesDansOwnMail() {
        let q = GmailReplySearch.query(since: Date(timeIntervalSince1970: 1_785_000_000))

        #expect(q.contains("after:1785000000"))
        #expect(q.contains("-from:me"))
        #expect(q.contains("-in:chats"))
    }

    // MARK: every contact searched says so

    @Test("every contact in scope is stamped as searched, so nothing found can be told from never asked")
    func everyContactSearchedIsStamped() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        #expect(r.replyCandidateSearchedAt == nil)

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(), fetch: mailbox([]))

        #expect(r.replyCandidateSearchedAt == now)
    }

    @Test("a failed tick does not stamp a contact as searched")
    func aFailedTickDoesNotStamp() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(),
                           fetch: mailbox([], listStatus: 503))

        #expect(r.replyCandidateSearchedAt == nil)
    }

    // MARK: the stamp is a claim about the store

    // The stamp is what tells a contact never read for from one already read for, and it decides how
    // far back the NEXT tick reads. Written to the model and never committed it would vanish on
    // relaunch, so every tick after that would widen its window back to the pitch and the mark would
    // buy nothing, silently and for ever (L12).
    @Test("the searched stamp is committed, not merely written to the object in memory")
    func theStampIsCommitted() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let p = show(ctx)
        formPitch(ctx, on: p)

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(), fetch: mailbox([]))

        // A SECOND context over the same container sees only what was committed.
        let fresh = ModelContext(container)
        let reread = try #require(try fresh.fetch(FetchDescriptor<Recipient>()).first)
        #expect(reread.replyCandidateSearchedAt == now)
    }

    // A tick that read the mailbox and could not record that it looked has still genuinely found what
    // it found, so the candidates survive and only the bookkeeping is in doubt.
    @Test("a tick that cannot record that it looked says so and still reports what it found")
    func aSaveFailureIsReportedWithoutLosingTheCandidates() async throws {
        struct Nope: Error {}
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let fetch = mailbox([(id: "m1", from: "a@x.com", subject: "s", sentAt: now.addingTimeInterval(-1 * day))])

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(),
                           save: { throw Nope() }, fetch: fetch)

        guard case .searched(let candidates, _, let saveFailed) = outcome else {
            Issue.record("a save failure must not discard the search, got \(outcome)"); return
        }
        #expect(saveFailed)
        #expect(candidates.map(\.messageId) == ["m1"])
    }

    // The mark lives in UserDefaults and the stamps live in the store, so a mark that advanced over a
    // save that failed would leave every contact reading as never searched while the mark said that
    // stretch of mailbox was already read. The two would then disagree for ever, in the direction that
    // skips mail.
    @Test("the mark does not advance when the stamps could not be saved")
    func theMarkWaitsForTheStampsToBeDurable() async throws {
        struct Nope: Error {}
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let defaults = try scratchDefaults()
        let fetch = mailbox([(id: "m1", from: "a@x.com", subject: "s", sentAt: now.addingTimeInterval(-1 * day))])

        _ = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: defaults,
                           save: { throw Nope() }, fetch: fetch)

        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == nil)
    }

    // MARK: the wait has a deadline

    // L110: a wait with no deadline cannot fail, it can only hang, and it joins a tick that already
    // fetches serially. The reason names what it was waiting for, because the first person to meet it
    // otherwise spends the afternoon believing the machine is merely busy.
    @Test("a search that outruns its deadline fails, naming what it waited for")
    func aTimeoutSaysWhatItWaitedFor() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        var readings = [now, now, now.addingTimeInterval(GmailReplySearch().timeout + 1)]
        let fetch = mailbox([(id: "m1", from: "a@x.com", subject: "s", sentAt: now.addingTimeInterval(-1 * day)),
                             (id: "m2", from: "b@x.com", subject: "s", sentAt: now.addingTimeInterval(-2 * day))])

        let outcome = await GmailReplySearch(fromEmail: me)
            .searchMailbox(in: ctx, token: "tok", now: now, defaults: try scratchDefaults(),
                           clock: { readings.isEmpty ? Date.distantFuture : readings.removeFirst() },
                           fetch: fetch)

        guard case .failed(let reason) = outcome else {
            Issue.record("a search past its deadline must fail, got \(outcome)"); return
        }
        #expect(reason.lowercased().contains("gmail"))
        #expect(reason.lowercased().contains("waiting") || reason.lowercased().contains("waited"))
    }
}
