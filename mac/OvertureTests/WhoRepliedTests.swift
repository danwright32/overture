import Testing
import Foundation
import SwiftData

// #2113: a card in the reached-out queue named the wrong person. Dan (2026-08-05): the Pumpkin
// Singalong card showed chelsea@everyvoicechoirs.org, but Nicole Becker (nbecker@everyvoicechoirs.org)
// is the one who replied.
//
// Two layers, both covered here. Overture never recorded WHO wrote back (the sender was computed at
// detection and thrown away), and the card picked a peer by lowest sorted id, which is alphabetical
// order and nothing to do with the conversation.
//
// Also #2111's remaining gap: `repliedAt` is stamped when Overture NOTICES a reply, so one that lands
// while the app is shut is dated the next launch. Gmail names the real send time in the same response
// the loop already reads, so it is captured here and preferred as the queue's anchor.
@MainActor
@Suite("Who replied is recorded and shown")
struct WhoRepliedTests {
    private let me = "dan@danwrightphotography.com"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Pumpkin Singalong", discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String, name: String? = nil,
                         thread: String = "t", group: String? = "g") -> Recipient {
        let r = Recipient(id: address, email: address, name: name, provenance: .act)
        r.gmailThreadId = thread
        r.sendGroupId = group
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        p.addRecipient(r)
        return r
    }

    // A Gmail threads.get body: one message from `from`, sent at `internalDate` (epoch millis).
    private func thread(from: String, internalDate: String = "1000000") -> Data {
        Data("""
        {"messages":[{"id":"m1","internalDate":"\(internalDate)",
          "payload":{"headers":[{"name":"From","value":"\(from)"}]}}]}
        """.utf8)
    }

    // MARK: reading the sender out of the thread

    // The display name has to survive: the whole point is naming a person, and `latestReplySender`
    // already lowercases to a bare address for comparison, which is the wrong shape to show anyone.
    @Test func theRawSenderHeaderKeepsTheDisplayName() {
        let json = thread(from: "Nicole Becker <nbecker@everyvoicechoirs.org>")
        #expect(ReplyDetection.latestReplySenderHeader(threadJSON: json, selfEmail: me)
                == "Nicole Becker <nbecker@everyvoicechoirs.org>")
    }

    @Test func aDisplayNameIsSplitOutOfTheHeader() {
        #expect(ReplyDetection.displayName(from: "Nicole Becker <nbecker@everyvoicechoirs.org>") == "Nicole Becker")
    }

    // A bare address names nobody, and inventing "nbecker" as a person's name would be worse than
    // showing the address, so this stays nil and the caller falls back to the address.
    @Test func aBareAddressYieldsNoDisplayName() {
        #expect(ReplyDetection.displayName(from: "nbecker@everyvoicechoirs.org") == nil)
    }

    // A quoted display name may itself contain a comma, the same case `addresses(inHeader:)` handles.
    @Test func aQuotedDisplayNameKeepsItsComma() {
        #expect(ReplyDetection.displayName(from: "\"Becker, Nicole\" <nbecker@everyvoicechoirs.org>")
                == "Becker, Nicole")
    }

    // Dan's own messages and automated senders are not replies, so neither may be reported as the writer.
    @Test func danAndAutomatedSendersAreNeverTheSender() {
        let mine = Data("""
        {"messages":[{"id":"m1","payload":{"headers":[{"name":"From","value":"\(me)"}]}}]}
        """.utf8)
        #expect(ReplyDetection.latestReplySenderHeader(threadJSON: mine, selfEmail: me) == nil)
        let robot = thread(from: "no-reply@mailer.example")
        #expect(ReplyDetection.latestReplySenderHeader(threadJSON: robot, selfEmail: me) == nil)
    }

    // #2111's gap: when the reply was actually WRITTEN, straight off the message Gmail already returned.
    @Test func theReplysOwnSendTimeIsReadFromTheThread() {
        let json = thread(from: "Nicole Becker <nbecker@everyvoicechoirs.org>", internalDate: "1754355390000")
        #expect(ReplyDetection.latestReplySentAt(threadJSON: json, selfEmail: me)
                == Date(timeIntervalSince1970: 1_754_355_390))
    }

    // MARK: recording it at detection

    @Test func detectionRecordsWhoWroteAndWhen() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        let json = thread(from: "Nicole Becker <nbecker@everyvoicechoirs.org>", internalDate: "1754355390000")
        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9_999),
                                       fetchThread: { _ in json }, fetchFullThread: { _ in json })
        let r = try #require(p.recipients.first)
        #expect(r.replyFromAddress == "nbecker@everyvoicechoirs.org")
        #expect(r.replyFromName == "Nicole Becker")
        #expect(r.inboundReplySentAt == Date(timeIntervalSince1970: 1_754_355_390))
    }

    // Dan's exact case. One email to two people, one thread: BOTH rows learn that Nicole is the writer,
    // because whichever of them the list happens to stand on has to be able to name her. Who wrote is a
    // fact about the conversation and Gmail names it outright, unlike a bounce (L66), which is a claim
    // about one mailbox and must never be spread across the group.
    @Test func bothContactsOnASharedThreadRecordTheSameWriter() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "chelsea@everyvoicechoirs.org")
        contact(p, "nbecker@everyvoicechoirs.org")
        let json = thread(from: "Nicole Becker <nbecker@everyvoicechoirs.org>")
        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9_999),
                                       fetchThread: { _ in json }, fetchFullThread: { _ in json })
        #expect(p.recipients.count == 2)
        for r in p.recipients {
            #expect(r.replyFromAddress == "nbecker@everyvoicechoirs.org")
            #expect(r.replyFromName == "Nicole Becker")
        }
    }

    // Somebody nobody was written at (a colleague brought in, an answer from a personal account). The
    // address is recorded as-is rather than credited to one of the original contacts.
    @Test func aWriterWhoWasNeverWrittenAtIsRecordedAsThemselves() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "chelsea@everyvoicechoirs.org")
        let json = thread(from: "Ray Ortiz <ray@elsewhere.example>")
        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9_999),
                                       fetchThread: { _ in json }, fetchFullThread: { _ in json })
        let r = try #require(p.recipients.first)
        #expect(r.replyFromAddress == "ray@elsewhere.example")
        #expect(r.replyFromName == "Ray Ortiz")
    }

    // MARK: backfilling threads that replied before any of this was recorded

    @Test func backfillNamesTheWriterOnAnAlreadyRepliedRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "chelsea@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.repliedAt = Date(timeIntervalSince1970: 5_000)
        let json = thread(from: "Nicole Becker <nbecker@everyvoicechoirs.org>", internalDate: "1754355390000")

        let filled = ReplyService.backfillResponders(in: [p], selfEmail: me, fetchThread: { _ in json })
        #expect(filled == 1)
        #expect(r.replyFromAddress == "nbecker@everyvoicechoirs.org")
        #expect(r.inboundReplySentAt == Date(timeIntervalSince1970: 1_754_355_390))
        // The backfill records who wrote; it must not disturb what the row already knew.
        #expect(r.repliedAt == Date(timeIntervalSince1970: 5_000))
    }

    // Once filled it costs nothing, so a steady state never pays a Gmail call for it again.
    @Test func backfillDoesNotRefetchARowThatAlreadyNamesItsWriter() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "chelsea@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        // #2147: a COMPLETE row is one that names its writer and holds the words. A row missing the words
        // is still a gap to repair, because a sender matching none of the contacts used to leave them
        // filed against nobody.
        r.lastReplyText = "Thanks, that sounds good."
        var fetches = 0
        let filled = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                                     fetchThread: { _ in fetches += 1; return nil })
        #expect(filled == 0)
        #expect(fetches == 0)
    }

    // A row that never replied is not a gap to fill, so it is never fetched either.
    @Test func backfillIgnoresARowThatNeverReplied() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "chelsea@everyvoicechoirs.org", group: nil)
        var fetches = 0
        let filled = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                                     fetchThread: { _ in fetches += 1; return nil })
        #expect(filled == 0)
        #expect(fetches == 0)
    }

    // What the row actually SAYS is now the audience roster (#2121), covered in RowAudienceTests: the row
    // lists everyone its next email reaches with the writer marked, which subsumes naming a single writer.

    // MARK: the queue anchors on when they WROTE, not when Overture noticed

    // #2111 dated the card by `repliedAt`, which is the moment of detection. With the real send time
    // recorded, a reply that landed while the app was shut groups under the evening it was written.
    @Test func theQueueDatesAReplyByWhenItWasWrittenNotNoticed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        let wrote = Date(timeIntervalSince1970: 1_754_355_390)          // evening
        let noticed = wrote.addingTimeInterval(13 * 3_600)              // next morning's launch
        r.replied = true
        r.repliedAt = noticed
        r.inboundReplySentAt = wrote
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: noticed.addingTimeInterval(3_600)) == wrote)
    }

    // With no send time recorded (an older row the backfill has not reached), the detection stamp is
    // still the best thing known, so the row keeps its date rather than losing one.
    @Test func theQueueFallsBackToTheDetectionStampWhenNoSendTimeIsKnown() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        let noticed = Date(timeIntervalSince1970: 1_754_355_390)
        r.replied = true
        r.repliedAt = noticed
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: noticed.addingTimeInterval(3_600)) == noticed)
    }
}

// A backfill that works and a backfill that RUNS are two claims, and only the second one reaches Dan's
// store. These drive the real `GmailReplyChecker.markReplies` against the full app schema, because the
// pass depends on an edit in a different file: the checker's thread-collection deliberately skips any
// row that has already replied, so without that edit the backfill would run every poll, be handed no
// thread at all, and quietly fill nothing forever.
@MainActor
@Suite("The responder backfill runs in the live reply check")
struct ResponderBackfillWiringTests {
    private let me = "dan@danwrightphotography.com"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func repliedShow(_ ctx: ModelContext) -> Recipient {
        let p = Prospect(naturalKey: "k", groupName: "Pumpkin Singalong", discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "chelsea@everyvoicechoirs.org", email: "chelsea@everyvoicechoirs.org",
                          provenance: .act)
        r.gmailThreadId = "t1"
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "m1"
        r.replied = true                       // replied before any writer was ever recorded
        r.repliedAt = Date(timeIntervalSince1970: 5_000)
        p.addRecipient(r)
        return r
    }

    private func fetching(from: String, internalDate: String, count: UnsafeMutablePointer<Int>)
    -> (URLRequest) async throws -> (Data, URLResponse) {
        let json = """
        {"messages":[{"id":"m9","internalDate":"\(internalDate)",
          "payload":{"headers":[{"name":"From","value":"\(from)"}]}}]}
        """
        return { req in
            count.pointee += 1
            return (Data(json.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func aThreadThatRepliedLongAgoLearnsWhoWroteOnTheNextCheck() async throws {
        let ctx = ModelContext(try container())
        let r = repliedShow(ctx)
        var fetches = 0
        await GmailReplyChecker(fromEmail: me).markReplies(
            in: ctx, token: "tok", now: Date(timeIntervalSince1970: 9_999),
            fetch: fetching(from: "Nicole Becker <nbecker@everyvoicechoirs.org>",
                            internalDate: "1754355390000", count: &fetches))
        #expect(fetches > 0, "the already-replied thread has to be fetched at all")
        #expect(r.replyFromAddress == "nbecker@everyvoicechoirs.org")
        #expect(r.replyFromName == "Nicole Becker")
        #expect(r.inboundReplySentAt == Date(timeIntervalSince1970: 1_754_355_390))
        // The backfill names the writer; it must not restamp what the row already knew.
        #expect(r.repliedAt == Date(timeIntervalSince1970: 5_000))
    }

    // Once named, the thread drops back out of the fetch set, so the pass cannot become a standing Gmail
    // cost on every poll for the life of the row.
    @Test func aThreadThatAlreadyNamesItsWriterIsNotFetchedAgain() async throws {
        let ctx = ModelContext(try container())
        let r = repliedShow(ctx)
        r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        r.lastReplyText = "Thanks, that sounds good."   // #2147: complete means writer AND words
        var fetches = 0
        await GmailReplyChecker(fromEmail: me).markReplies(
            in: ctx, token: "tok", now: Date(timeIntervalSince1970: 9_999),
            fetch: fetching(from: "Nicole Becker <nbecker@everyvoicechoirs.org>",
                            internalDate: "1754355390000", count: &fetches))
        #expect(fetches == 0)
    }
}
