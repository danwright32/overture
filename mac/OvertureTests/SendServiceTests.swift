import Testing
import Foundation
import SwiftData

private struct FakeSender: MailSender {
    var receipt = SentReceipt(threadId: "t-123", messageID: "<mid-1@x.org>")
    var error: Error? = nil
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        if let error { throw error }
        return receipt
    }
}

// Records the last mail it was handed, so a test can assert how a follow-up was addressed (#74).
private final class CapturingSender: MailSender, @unchecked Sendable {
    var last: OutgoingMail?
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        last = mail
        return SentReceipt(threadId: "t", messageID: "<m>")
    }
}

private struct AlwaysFailSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
}

// #483: a real Gmail 2xx whose body had no parseable threadId. The send itself succeeded, so
// this must never throw; it comes back flagged instead.
private struct DegradedThreadIdSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "", messageID: "<mid-degraded@x.org>", threadIdDegraded: true)
    }
}

// #2647: the guard the issue names. Gmail DISCARDS the Message-ID a client puts in the raw message and
// stamps its own, so this sender returns one that deliberately differs from whatever it was handed. What
// gets stored has to be the RETURNED one; storing the supplied one is the defect, and it is invisible
// unless the two values differ.
private struct ReassigningMessageIDSender: MailSender {
    static let assigned = "<assigned-by-gmail@mail.gmail.com>"
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t-reassigned", messageID: Self.assigned)
    }
}

// #2647: a send that succeeded but whose real Message-ID could not be read back off Gmail. Never a
// minted fall back: nil, plus the flag.
private struct UnreadableMessageIDSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t-ok", messageID: nil, messageIDDegraded: true)
    }
}

// Records the URL the injected fetch was handed, so a test can prove the live network path
// was never reached when driving the real GmailSender through sendOne (#194).
private final class Hit: @unchecked Sendable { var url: URL? }

// Gated so a test can inspect state exactly while a send is suspended mid-flight (#475/#476):
// ONLY the first call parks, on a continuation the test explicitly releases; any further call
// (the exact case under test: a second attempt reaching the network while the first is still in
// flight) returns immediately instead of also parking. That keeps a missing in-flight guard a
// fast, clean assertion failure (callCount == 2) rather than a hung suite (a second parked call
// with nothing left to release it).
private final class GatedSender: MailSender, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasParked = false
    private(set) var callCount = 0
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        callCount += 1
        if !hasParked {
            hasParked = true
            await withCheckedContinuation { self.continuation = $0 }
        }
        return SentReceipt(threadId: "t-gated", messageID: "<gated@x.org>")
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite("Send service")
struct SendServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func approved(_ ctx: ModelContext, group: String, email: String? = "to@org.org",
                          draft: String? = "Hello,\n\nI photograph performing arts.", ingested: Date) {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved, ingestedAt: ingested)
        p.draftSubject = "S"; p.draftBody = draft
        ctx.insert(p)
        seedRecipient(p, email: email, name: nil)
        try? ctx.save()
    }

    // Mirror the live flow: a performance has its act Recipient row before any send runs. The send
    // path reads recipients, not any lead-level field, so a test prospect needs one seeded directly.
    @discardableResult
    private func seedRecipient(_ p: Prospect, email: String?, name: String?,
                              role: String? = nil, method: ContactMethod? = nil) -> Recipient? {
        guard let id = Recipient.makeId(email: email, formURL: nil) else { return nil }
        let r = Recipient(id: id, email: email, name: name, role: role, provenance: .act,
                          contactMethodRaw: method?.rawValue)
        p.setRecipients([r])
        return r
    }

    private func approvedNamed(_ ctx: ModelContext, group: String, name: String?, email: String,
                               body: String, ingested: Date,
                               role: String? = nil, method: ContactMethod? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved, ingestedAt: ingested)
        p.draftSubject = "S"; p.draftBody = body
        ctx.insert(p)
        seedRecipient(p, email: email, name: name, role: role, method: method)
        try? ctx.save()
        return p
    }

    // Phase 2.5 (#393): the body is salutation-free; the app composes the greeting at send. The frozen
    // sent copy stays the BARE body so the voice pair learns the shared template, not the greeting.
    // #2545: the send composes NOTHING. What Gmail receives is the stored body, greeting and all, and the
    // frozen sent copy is that same text. The two used to differ, because the greeting was added on the
    // way out and deliberately kept out of the sent copy so the voice-learning pair saw the bare template;
    // there is no bare template any more, so they are now the same string and this pins that they are.
    @Test func sendOneSendsTheStoredBodyAndFreezesTheSameText() async throws {
        let ctx = ModelContext(try container())
        let body = "Hi Emma,\n\nI photograph performing arts in New York."
        let p = approvedNamed(ctx, group: "Aurora", name: "Emma Robinson", email: "emma@act.example",
                              body: body, ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(sender.last?.body == body)
        #expect(p.sentBody == body)
    }

    @Test func sendOneGreetsHelloWhenNoName() async throws {
        let ctx = ModelContext(try container())
        let p = approvedNamed(ctx, group: "Aurora", name: nil, email: "info@act.example",
                              body: "Hello,\n\nI document dance unobtrusively.",
                              ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(sender.last?.body == "Hello,\n\nI document dance unobtrusively.")
    }

    // #610's Attn: line routes a shared-inbox pitch to the right desk. #2545 made it the DRAFTER's job to
    // write rather than the app's to compose, so what this pins now is that the send passes it through
    // untouched: it is part of the body, and the body is what leaves.
    @Test func sendOnePassesThroughTheAttnLineAGenericInboxNeeds() async throws {
        let ctx = ModelContext(try container())
        let p = approvedNamed(ctx, group: "Clarion Society", name: "Jane Doe", email: "info@clarion.example",
                              body: "Attn: Jane Doe, PR Associate Director\n\nHello,\n\n"
                                    + "I photograph performing arts in New York.",
                              ingested: Date(timeIntervalSince1970: 1),
                              role: "PR Associate Director", method: .genericInbox)
        let sender = CapturingSender()

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(sender.last?.body ==
                "Attn: Jane Doe, PR Associate Director\n\nHello,\n\nI photograph performing arts in New York.")
    }

    // #2545 RETIRED the two #407 send-gate tests that sat here, for the same reason as their siblings in
    // RecipientTests: both set `draftNeedsSalutationReview = true` by hand, and nothing in the app has set
    // that flag since #2010, so the block they asserted could not fire in production. They passed on a
    // value only they wrote (L90). The live gate is now the greeting hold, which SendServiceTests exercises
    // throughout: every fixture in this file greets, because one that does not is refused.

    @Test func sendingSnapshotsTheRelationshipAtContact() async throws {
        // #66: capture what the relationship was the moment Dan pitched, so a later Downbeat
        // match can tell a genuine new booking from a pre-existing client.
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Repeat Client", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "booked", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hello,\n\nI photograph performing arts."
        ctx.insert(p)
        seedRecipient(p, email: "to@org.org", name: nil)

        let sent = await SendService.sendOne(p, now: Date(), sender: FakeSender())
        #expect(sent)
        #expect(p.priorRelationshipAtSend == "booked")
    }

    // #200: "contacted" means the pitch went out, not merely that Dan approved it. An approved
    // prospect still waiting in the send queue is NOT contacted; once sent it is.
    @Test func approvedButUnsentIsNotYetContacted() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Held", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Held", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        ctx.insert(p)
        #expect(p.wasContacted == false)
        p.status = .contacted
        p.sentAt = Date(timeIntervalSince1970: 9)
        #expect(p.wasContacted == true)
    }

    @Test func sendOneRecordsReceiptAndAdvancesToContacted() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(await SendService.sendOne(p, now: now, sender: FakeSender()) == true)

        #expect(p.sentAt == now)
        #expect(p.gmailThreadId == "t-123")
        // #200: sending advances the lifecycle to an explicit contacted state, not just a date.
        #expect(p.status == .contacted)
    }

    @Test func sendOneSendsThatSpecificProspectImmediately() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        approved(ctx, group: "B", ingested: Date(timeIntervalSince1970: 2))
        let b = try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.groupName == "B" }!
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(await SendService.sendOne(b, now: now, sender: FakeSender()) == true)
        #expect(b.sentAt == now)
        #expect(b.gmailThreadId == "t-123")
        // A is untouched (manual send targets exactly one).
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.groupName == "A" }!
        #expect(a.sentAt == nil)
    }

    // A performance with one SENT, still-silent contact (awaiting a reply), for the per-recipient
    // follow-up tests (#418 D).
    @discardableResult
    private func sentContact(_ ctx: ModelContext, group: String, threadId: String? = "th",
                             msgId: String? = "<m>") -> (Prospect, Recipient) {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.draftSubject = "Photographs for \(group)"; p.draftBody = "Hello,\n\nI photograph performing arts."; p.sentAt = Date(timeIntervalSince1970: 100)
        ctx.insert(p)
        let r = Recipient(id: group + "@act.example", email: group + "@act.example", name: "Emma", provenance: .act)
        r.sendState = .sent; r.sentAt = Date(timeIntervalSince1970: 100)
        r.gmailThreadId = threadId; r.gmailMessageId = msgId
        p.addRecipient(r)
        try? ctx.save()
        return (p, r)
    }

    @Test func sendFollowUpRecordsTheNudgeAndCapsAtTheMax() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(await SendService.sendFollowUp(r, of: p, now: now, sender: FakeSender()) == true)
        #expect(r.followUpCount == 1)
        #expect(r.lastFollowUpAt == now)

        #expect(await SendService.sendFollowUp(r, of: p, now: now, sender: FakeSender()) == true)
        #expect(r.followUpCount == 2)
        // Capped at 2: a third nudge is refused.
        #expect(await SendService.sendFollowUp(r, of: p, now: now, sender: FakeSender()) == false)
        #expect(r.followUpCount == 2)
    }

    @Test func sendFollowUpStopsOnceTheContactReplied() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")
        r.replied = true   // this contact replied -> no longer awaiting a follow-up
        #expect(await SendService.sendFollowUp(r, of: p, now: Date(), sender: FakeSender()) == false)
        #expect(r.followUpCount == 0)
    }

    // A contact Dan hand-marked (e.g. Closed) is never nudged, even though it's sent + silent.
    @Test func sendFollowUpSkipsAHandMarkedContact() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")
        r.markOutcomeManually(resolution: .declinedSoft)
        #expect(await SendService.sendFollowUp(r, of: p, now: Date(), sender: FakeSender()) == false)
    }

    // #194: sendOne must be able to drive the REAL GmailSender send chain (token acquisition +
    // HTTP), not just a substitute MailSender, with the token and fetch injected so the live
    // path runs from the main actor without the network. Proves the injected fetch fired (so no
    // live request escaped) and the receipt was recorded onto the prospect.
    @Test func sendOneDrivesTheRealGmailSenderWithInjectedTokenAndFetch() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Real", ingested: Date(timeIntervalSince1970: 1))
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let now = Date(timeIntervalSince1970: 2_000_000)

        let hit = Hit()
        let sender = GmailSender(
            fromEmail: "dan@danwrightphotography.com",
            token: { "tok" },
            // #2647: the send is a POST followed by a GET that reads the real Message-ID back, so the
            // send URL is recorded off the POST specifically rather than off whichever call happened
            // to be last.
            fetch: { req in
                if req.httpMethod == "POST" {
                    hit.url = req.url
                    return (Data(#"{"threadId":"t-194","id":"m1"}"#.utf8),
                            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let meta = #"{"payload":{"headers":[{"name":"Message-ID","value":"<real-194@mail.gmail.com>"}]}}"#
                return (Data(meta.utf8),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })

        #expect(await SendService.sendOne(p, now: now, sender: sender) == true)
        #expect(p.sentAt == now)
        #expect(p.gmailThreadId == "t-194")
        #expect(p.gmailMessageId == "<real-194@mail.gmail.com>")
        // The injected fetch was the one that ran (the real URLSession path was never reached).
        #expect(hit.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
    }

    @Test func sendOneRecordsErrorOnFailure() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        #expect(await SendService.sendOne(a, now: Date(), sender: AlwaysFailSender()) == false)
        #expect(a.sentAt == nil)
        #expect(a.sendError != nil)
    }

    // #483: a 2xx send with no parseable threadId must never leave reply watching silently
    // broken. The send itself succeeded (never reverted to pending, never treated as a
    // failure), but the recipient comes back flagged so Dan can see the gap.
    @Test func aSendWithAnUnparseableThreadIdFlagsReplyTrackingDegraded() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let recipient = a.recipients.first!

        #expect(await SendService.sendOne(a, now: Date(), sender: DegradedThreadIdSender()) == true)

        #expect(recipient.sendState == .sent)
        #expect(recipient.gmailThreadId == "")
        #expect(recipient.replyTrackingDegraded == true)
        #expect(recipient.sendError == nil)   // this is a degraded success, not a failure
    }

    // #2647: the id stored is the one the SEND came back with, never the one Overture put in the raw
    // message. Gmail throws the supplied one away, so a stored copy of it references a message that
    // exists nowhere and every follow-up written from it comes adrift in any client but Gmail.
    @Test func theStoredMessageIdIsTheOneTheSendReturnedNotTheOneSupplied() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let recipient = p.recipients.first!
        let sender = ReassigningMessageIDSender()

        #expect(await SendService.sendOne(p, now: Date(), sender: sender) == true)

        #expect(recipient.gmailMessageId == ReassigningMessageIDSender.assigned)
        #expect(recipient.threadingDegraded == false)
        // Deliberately NOT asserting here that nothing was minted: minting lived in GmailSender, and a
        // fake sender cannot mint, so through this seam such a check would pass for a reason unrelated
        // to the rule and be green forever (L1). `GmailSenderTests` asserts it where it can actually
        // fail, against the real raw message.
    }

    // The failure path: the send worked, the id could not be read back. The recipient is FLAGGED, so a
    // conversation whose threading cannot be trusted is visible rather than quietly wrong, and no minted
    // value is stored in place of the real one.
    @Test func anUnreadableMessageIdFlagsTheRecipientAndStoresNothing() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let recipient = p.recipients.first!

        #expect(await SendService.sendOne(p, now: Date(), sender: UnreadableMessageIDSender()) == true)

        #expect(recipient.sendState == .sent)          // a degraded success, not a failure
        #expect(recipient.sendError == nil)
        #expect(recipient.gmailMessageId == nil)
        #expect(recipient.threadingDegraded == true)
        #expect(recipient.replyTrackingDegraded == false)   // the threadId was fine: two separate checks
    }

    // L5: a follow-up whose own Message-ID could not be read back must KEEP the prior id rather than
    // blank it. The prior id is a real ancestor of the conversation, so referencing it still threads
    // everywhere; blanking it turns the next message into an unthreaded one, a worse defect than a
    // slightly stale reference.
    @Test func aFollowUpWithAnUnreadableMessageIdKeepsThePriorId() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let recipient = p.recipients.first!
        let sentAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(await SendService.sendOne(p, now: sentAt, sender: FakeSender()) == true)
        #expect(recipient.gmailMessageId == "<mid-1@x.org>")

        let later = sentAt.addingTimeInterval(60 * 60 * 24 * 7)
        #expect(await SendService.sendFollowUp(recipient, of: p, now: later,
                                               sender: UnreadableMessageIDSender()) == true)

        #expect(recipient.gmailMessageId == "<mid-1@x.org>")   // kept, not blanked
        #expect(recipient.threadingDegraded == true)
    }

    // MARK: - #475/#476 send-path claim (crash safety + concurrency guard)

    @Test func deliverClaimsSendingAndPersistsItBeforeTheNetworkCallResolves() async throws {
        let modelContainer = try container()
        let ctx = ModelContext(modelContainer)
        let p = approvedNamed(ctx, group: "Aurora", name: "Emma", email: "emma@act.example",
                              body: "Hello,\n\nHi", ingested: Date(timeIntervalSince1970: 1))
        let recipient = p.recipients.first!
        let sender = GatedSender()

        let task = Task { await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        await waitUntil("the send to reach the sender") { sender.callCount > 0 }

        // Claimed in memory before the send resolves: not sent yet, not plain pending either.
        #expect(recipient.sendState == .sending)
        #expect(recipient.sendClaimedAt == Date(timeIntervalSince1970: 10))
        // A SECOND, independent context on the same store proves it was actually persisted (not
        // just mutated in memory) before the network call resolves: the crash-safety guarantee
        // #475 needs: a relaunch right now would see .sending, never silently-still-pending.
        let secondContext = ModelContext(modelContainer)
        let persisted = try secondContext.fetch(FetchDescriptor<Recipient>()).first!
        #expect(persisted.sendState == .sending)

        sender.release()
        #expect(await task.value == true)
        #expect(recipient.sendState == .sent)
        #expect(recipient.sendClaimedAt == nil)
    }

    // MARK: - #2031 one pitch to several contacts at once

    // Two contacts on one show, both still to be written to, sharing the same letter.
    private func showWithTwoContacts(_ ctx: ModelContext, body: String = "Hello,\n\nI document dance.",
                                     secondName: String? = "Noah Ellis") -> (Prospect, Recipient, Recipient) {
        let key = Prospect.makeNaturalKey(groupName: "Aurora", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Aurora", discipline: "dance", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, ingestedAt: Date(timeIntervalSince1970: 1))
        p.draftSubject = "S"; p.draftBody = body
        ctx.insert(p)
        let a = Recipient(id: "emma@act.example", email: "emma@act.example", name: "Emma Robinson",
                          provenance: .presenter)
        let b = Recipient(id: "noah@act.example", email: "noah@act.example", name: secondName,
                          provenance: .presenter)
        p.setRecipients([a, b])
        try? ctx.save()
        return (p, a, b)
    }

    // The point of the whole feature: ONE email, and every person on it recorded as having received
    // that same email. The shared thread is what makes a reply from either of them findable at all.
    @Test func onejointSendReachesEveryContactOnOneThread() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoContacts(ctx)
        let sender = CapturingSender()

        #expect(await SendService.sendJointly(p, to: [a, b], now: Date(timeIntervalSince1970: 10),
                                              sender: sender) == true)

        #expect(sender.last?.to == ["emma@act.example", "noah@act.example"])
        #expect(a.sendState == .sent && b.sendState == .sent)
        #expect(a.gmailThreadId == b.gmailThreadId)
        #expect(a.gmailMessageId == b.gmailMessageId)
        #expect(a.sentAt == Date(timeIntervalSince1970: 10) && b.sentAt == a.sentAt)
        // Recorded as ONE send, which is what every later surface has to read to know these two people
        // are reading the same conversation.
        #expect(a.sendGroupId != nil)
        #expect(a.sendGroupId == b.sendGroupId)
        #expect(p.status == .contacted, "nobody is left to write to")
    }

    // The failure path. A joint send that does not leave is not a partial send: nobody may be left
    // recorded as written to, and nobody may be left looking un-attempted either (L47).
    @Test func afailedJointSendLeavesNobodySentAndRecordsItOnEveryContact() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoContacts(ctx)

        #expect(await SendService.sendJointly(p, to: [a, b], now: Date(timeIntervalSince1970: 10),
                                              sender: AlwaysFailSender()) == false)

        #expect(a.sendState == .pending && b.sendState == .pending)
        #expect(a.sendClaimedAt == nil && b.sendClaimedAt == nil)
        #expect(a.sentAt == nil && b.sentAt == nil)
        #expect(a.sendError != nil, "a contact with no trace of the attempt reads as never tried")
        #expect(b.sendError != nil)
        #expect(p.status == .approved)
    }

    // The refusal that has to exist before this can be offered at all. A performer carries their OWN
    // second-person letter; putting them on one message with somebody reading a different letter means
    // one of the two receives text written for the other, greeted by the other's name.
    @Test func agroupWhoseContactsWouldReadDifferentLettersIsRefused() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoContacts(ctx)
        b.provenance = .performer
        b.overrideBody = "Hi Noah,\n\nI document dance."
        let sender = CapturingSender()

        #expect(await SendService.sendJointly(p, to: [a, b], now: Date(timeIntervalSince1970: 10),
                                              sender: sender) == false)

        #expect(sender.last == nil, "nothing may go out when the app would have to choose whose letter")
        #expect(a.sendState == .pending && b.sendState == .pending)
        #expect(SendService.jointSendRefusal([a, b], of: p) != nil)
        // And the ordinary case is not refused by the same rule.
        #expect(SendService.jointSendRefusal([a], of: p) == nil)
    }

    // One show in the live store already has one contact written to and one waiting. The person who
    // already had their email must never receive it twice.
    @Test func acontactWhoAlreadyHadTheEmailIsNotInTheGroup() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoContacts(ctx)
        a.sendState = .sent
        a.sentAt = Date(timeIntervalSince1970: 5)
        let sender = CapturingSender()

        #expect(await SendService.sendJointly(p, to: [a, b], now: Date(timeIntervalSince1970: 10),
                                              sender: sender) == true)

        #expect(sender.last?.to == ["noah@act.example"])
        #expect(a.sentAt == Date(timeIntervalSince1970: 5), "the earlier send is not restamped")
        #expect(b.sendState == .sent)
    }

    // #2033: a draft Dan has not approved sends to nobody, however ready its contacts look. The
    // per-contact rule (`isSendablePending`) only says THIS CONTACT is ready; approval is a fact about the
    // show, and a send that read only the first would put out an unapproved draft.
    @Test func adraftThatWasNeverApprovedCannotBeSentJointly() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoContacts(ctx)
        p.status = .drafted
        let sender = CapturingSender()

        #expect(await SendService.sendJointly(p, to: [a, b], now: Date(timeIntervalSince1970: 10),
                                              sender: sender) == false)

        #expect(sender.last == nil)
        #expect(a.sendState == .pending && b.sendState == .pending)
    }

    // Nothing to send to: refused rather than reported as a send that happened.
    @Test func ajointSendWithNobodyLeftToWriteToDoesNothing() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoContacts(ctx)
        for r in [a, b] { r.sendState = .sent; r.sentAt = Date(timeIntervalSince1970: 5) }
        let sender = CapturingSender()

        #expect(await SendService.sendJointly(p, to: [a, b], now: Date(timeIntervalSince1970: 10),
                                              sender: sender) == false)
        #expect(sender.last == nil)
    }

    // #2030's rule, extended: a contact carrying a group id has been written to, whatever else is true
    // of it. `wasWrittenTo` fails closed by design and its comment requires every field that records
    // contact to be listed there, because the merges delete a contact it answers false for.
    @Test func acontactThatWentOutWithAGroupCountsAsWrittenTo() throws {
        let ctx = ModelContext(try container())
        let (_, a, _) = showWithTwoContacts(ctx)

        #expect(a.wasWrittenTo == false)
        a.sendGroupId = "grp-1"

        #expect(a.wasWrittenTo, "a contact on a sent group must never read as an untouched address")
    }

    // #2030. A send can refuse for a reason that has nothing to do with the network: there is no text to
    // put in the email. That refusal must leave the contact exactly as it found them, still pending and
    // still sendable, because a contact left claimed is a contact nothing will ever retry: no send goes
    // out, no error is recorded, and only Dan noticing the stuck state gets it back.
    //
    // The composition therefore happens BEFORE the claim. Nothing about it awaits or writes, so there is
    // no reason for it to sit after.
    @Test func adraftWithNothingToSendLeavesTheContactPendingAndUnclaimed() async throws {
        let ctx = ModelContext(try container())
        // Non-nil but empty: it passes every earlier guard and is caught where the email is composed.
        let p = approvedNamed(ctx, group: "Aurora", name: "Emma", email: "emma@act.example",
                              body: "", ingested: Date(timeIntervalSince1970: 1))
        let recipient = p.recipients.first!
        let sender = CapturingSender()

        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == false)

        #expect(sender.last == nil, "nothing may reach the network when there is no email to send")
        #expect(recipient.sendState == .pending, "the contact must still be sendable, never stuck sending")
        #expect(recipient.sendClaimedAt == nil)
        #expect(p.status == .approved)
    }

    // #2397: the test that used to sit here proved a non-sendable KIND held no claim. That case is now
    // unrepresentable rather than merely guarded: `sendClosingNote` takes no kind at all, and
    // `PostEventPrompt.nudgeContent` returns nil for anything but the closing note (asserted in
    // PostEventPromptTests). A guarantee the type system enforces beats one a test watches for.

    @Test func aFailedSendRevertsTheRecipientToPendingNotStuckSending() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let recipient = a.recipients.first!

        #expect(await SendService.sendOne(a, now: Date(), sender: AlwaysFailSender()) == false)

        #expect(recipient.sendState == .pending)   // retryable, never stuck at .sending
        #expect(recipient.sendClaimedAt == nil)
        #expect(recipient.sendError != nil)
    }

    // The direct regression test for #476: while a send is in flight for a recipient, a second
    // attempt on that SAME recipient (a fast double-click, or a drip-timer overlap) must be
    // refused outright, never reaching the network a second time.
    @Test func aSecondSendAttemptWhileTheFirstIsInFlightIsRefused() async throws {
        let ctx = ModelContext(try container())
        let p = approvedNamed(ctx, group: "Aurora", name: "Emma", email: "emma@act.example",
                              body: "Hello,\n\nHi", ingested: Date(timeIntervalSince1970: 1))
        let sender = GatedSender()

        let firstTask = Task { await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        await waitUntil("the first send to be parked mid-call") { sender.callCount > 0 }

        let secondResult = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 20), sender: sender)
        #expect(secondResult == false)
        #expect(sender.callCount == 1)   // the second attempt never reached the network at all

        sender.release()
        #expect(await firstTask.value == true)
        #expect(p.recipients.first?.sendState == .sent)
    }

    @Test func firstSendStoresTheMessageIDForThreading() async throws {
        // #74: the first send's Message-ID is kept so a later follow-up can reply to it.
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 2_000_000), sender: FakeSender())
        #expect(p.gmailMessageId == "<mid-1@x.org>")
    }

    @Test func followUpRepliesOnTheOriginalThread() async throws {
        // #74: the nudge goes out In-Reply-To the contact's Message-ID, on its thread, as a Re:.
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A", threadId: "th-9", msgId: "<orig@x.org>")

        let sender = CapturingSender()   // returns messageID "<m>"
        #expect(await SendService.sendFollowUp(r, of: p, now: Date(), sender: sender) == true)
        #expect(sender.last?.threadId == "th-9")
        #expect(sender.last?.inReplyTo == "<orig@x.org>")   // this nudge replies to the prior message
        #expect(sender.last?.subject == "Re: Photographs for A")
        // The contact's message-id advances to this nudge, so the NEXT nudge threads off it (#74).
        #expect(r.gmailMessageId == "<m>")
    }

    // MARK: - Fan-out (#394): one email per recipient over the shared body

    // An approved performance with two recipients (an act and a presenter) sharing one drafted body.
    private func twoRecipients(_ ctx: ModelContext, body: String, ingested: Date) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Lumen", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Lumen", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved, ingestedAt: ingested)
        p.draftSubject = "S"; p.draftBody = body
        ctx.insert(p)
        let act = Recipient(id: "emma@act.example", email: "emma@act.example", name: "Emma Robinson", provenance: .act)
        let presenter = Recipient(id: "noah@present.example", email: "noah@present.example",
                                  name: "Noah Lee", provenance: .presenter)
        p.setRecipients([act, presenter])
        try? ctx.save()
        return p
    }

    // #2545 RENAMED this from "...WithItsOwnGreeting". The fan-out is unchanged and is what this still
    // pins: one click per contact, each to their own address, and a third click that does nothing.
    //
    // What went is the per-recipient greeting. One show has one body, and the greeting now lives inside
    // it, so both contacts read the same words. That is Dan's rule (2026-08-12): a show with two contacts
    // opens "Hello," with no name, precisely because one letter cannot address two people by name.
    @Test func sendOneFansOutToEachRecipientInTurn() async throws {
        let ctx = ModelContext(try container())
        let body = "Hello,\n\nI document dance."
        let p = twoRecipients(ctx, body: body, ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        // First click -> the act contact.
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)
        #expect(sender.last?.to == ["emma@act.example"])
        #expect(sender.last?.body == body)
        // The show keeps a pending recipient, so it is NOT yet fully contacted and stays sendable.
        #expect(p.status == .approved)
        #expect(p.recipients.first { $0.email == "emma@act.example" }?.sendState == .sent)
        #expect(p.recipients.first { $0.email == "noah@present.example" }?.sendState == .pending)

        // Second click -> the presenter, who reads the SAME letter.
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 20), sender: sender) == true)
        #expect(sender.last?.to == ["noah@present.example"])
        #expect(sender.last?.body == body)
        // Every recipient sent -> now contacted.
        #expect(p.status == .contacted)

        // A third click is a no-op: nothing left to send (kills the duplicate-send risk).
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 30), sender: sender) == false)
    }

    @Test func firstRecipientSetsTheLeadRollupWriteOnce() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nI document dance.", ingested: Date(timeIntervalSince1970: 1))
        p.priorRelationship = "warm"
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 500)

        _ = await SendService.sendOne(p, now: t1, sender: FakeSender())
        #expect(p.sentAt == t1)
        #expect(p.gmailThreadId == "t-123")
        #expect(p.priorRelationshipAtSend == "warm")

        _ = await SendService.sendOne(p, now: t2, sender: FakeSender())
        // The lead rollup reflects the FIRST send only, never overwritten by the second recipient.
        #expect(p.sentAt == t1)
    }

    // #395: under fan-out, freezeSentCopy fires once per recipient, but the captured voice pair is
    // lead-level and one-per-shared-body, so only the first send writes it (over the bare body).
    @Test func fanOutFreezesExactlyOnePairOverTheBareBody() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nI document dance.", ingested: Date(timeIntervalSince1970: 1))

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: CapturingSender())
        let afterFirst = p.sentBody

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 20), sender: CapturingSender())
        // #2545: the frozen copy is the WHOLE body, greeting included. It used to be deliberately bare,
        // because the greeting was added on the way out and kept out of the voice-learning pair; there is
        // no bare version any more, so what was sent and what is stored are one string.
        #expect(p.sentBody == "Hello,\n\nI document dance.")
        #expect(p.sentBody == afterFirst)            // the second recipient did not re-freeze
    }

    // MARK: - #641 (#634 Phase C): a performer's overrideBody wins over the shared draft, everywhere

    // A performance where the ONLY recipient is a directly-addressed named performer, carrying their
    // own overrideBody distinct from the shared (third-person) draftBody.
    private func performerWithOverride(_ ctx: ModelContext, overrideBody: String,
                                       sharedBody: String, ingested: Date) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Midnight Quartet", performanceDate: "2026-08-15", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Midnight Quartet", discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-08-15", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved, ingestedAt: ingested)
        p.draftSubject = "S"; p.draftBody = sharedBody
        ctx.insert(p)
        let performer = Recipient(id: "maya@performer.example", email: "maya@performer.example",
                                  name: "Maya Chen", provenance: .performer)
        performer.overrideBody = overrideBody
        p.setRecipients([performer])
        try? ctx.save()
        return p
    }

    @Test func sendOneUsesThePerformersOverrideBodyInsteadOfTheSharedDraft() async throws {
        let ctx = ModelContext(try container())
        let p = performerWithOverride(ctx, overrideBody: "Hi Maya,\n\nI saw you're self-presenting Midnight Quartet.",
                                      sharedBody: "Hello,\n\nI saw Midnight Quartet is self-presenting.",
                                      ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.last?.body == "Hi Maya,\n\nI saw you're self-presenting Midnight Quartet.")
    }

    // The bug the red-team caught: the voice-learning snapshot (#119) must freeze what was ACTUALLY
    // sent, not the shared draft the override replaced, or a later run learns from text nobody read.
    @Test func sendOneFreezesTheOverrideBodyForVoiceLearningNotTheSharedDraft() async throws {
        let ctx = ModelContext(try container())
        let p = performerWithOverride(ctx, overrideBody: "Hi Maya,\n\nI saw you're self-presenting Midnight Quartet.",
                                      sharedBody: "Hello,\n\nI saw Midnight Quartet is self-presenting.",
                                      ingested: Date(timeIntervalSince1970: 1))

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: CapturingSender())

        #expect(p.sentBody == "Hi Maya,\n\nI saw you're self-presenting Midnight Quartet.")
    }

    // Defense in depth: even a .performer recipient with NO overrideBody set falls back to the
    // shared draft, exactly like an act/presenter recipient always has.
    @Test func aPerformerWithNoOverrideBodyStillGetsTheSharedDraft() async throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Solo Act", performanceDate: "2026-08-15", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Solo Act", discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-08-15", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved,
                         ingestedAt: Date(timeIntervalSince1970: 1))
        p.draftSubject = "S"; p.draftBody = "Hello,\n\nThe shared third-person body."
        ctx.insert(p)
        let performer = Recipient(id: "solo@performer.example", email: "solo@performer.example",
                                  name: "Solo Performer", provenance: .performer)
        p.setRecipients([performer])
        try? ctx.save()

        let sender = CapturingSender()
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.last?.body == "Hello,\n\nThe shared third-person body.")
        #expect(p.sentBody == "Hello,\n\nThe shared third-person body.")
    }

    // MARK: - #421 recipient-scoped reply send + copy-out

    @Test func sendReplyDraftSendsOnTheContactThreadAndConsumesTheDraft() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nshared body", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first { $0.email == "emma@act.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.sendState = .sent; r.replied = true
        r.replyDraftSubject = "Re: Photographing you"; r.replyDraftBody = "Glad to help — July works."
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)
        #expect(sender.last?.to == ["emma@act.example"])
        #expect(sender.last?.threadId == "rt")               // the CONTACT's thread, not the lead rollup
        #expect(sender.last?.inReplyTo == "<rm>")
        #expect(sender.last?.subject == "Re: Photographing you")
        #expect(sender.last?.body == "Glad to help — July works.")
        #expect(r.replyDraftBody == nil)                     // draft consumed (can't double-send)
        #expect(r.lastFollowUpAt == Date(timeIntervalSince1970: 10))   // clock re-anchored
    }

    // #463 — sending a reply freezes the committed body as the "sent" side of the voice pair, before
    // the draft is consumed, so a later re-draft can't rewrite the lesson.
    @Test func sendReplyDraftFreezesTheSentReplyForVoiceLearning() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nshared body", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first { $0.email == "emma@act.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.sendState = .sent; r.replied = true
        r.replyDraftBody = "Glad to help — July works for me."

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10), sender: CapturingSender()) == true)
        #expect(r.sentReplyBody == "Glad to help — July works for me.")
        #expect(r.replySentAt == Date(timeIntervalSince1970: 10))
        #expect(r.replyDraftBody == nil)   // still consumed
    }

    @Test func sendReplyDraftRefusesWithoutADraft() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nx", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first!
        r.gmailThreadId = "rt"; r.sendState = .sent          // no replyDraftBody
        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(), sender: CapturingSender()) == false)
    }

    // MARK: - #468 (SUP-005) secondary-send claim guards

    @Test func aSecondReplyDraftSendAttemptWhileTheFirstIsInFlightIsRefused() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nshared body", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first { $0.email == "emma@act.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.sendState = .sent; r.replied = true
        r.replyDraftSubject = "Re: Photographing you"; r.replyDraftBody = "Glad to help, July works."
        let sender = GatedSender()

        let firstTask = Task { await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        await waitUntil("the first send to be parked mid-call") { sender.callCount > 0 }

        let secondResult = await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 20), sender: sender)
        #expect(secondResult == false)
        #expect(sender.callCount == 1)   // the second attempt never reached the network at all

        sender.release()
        #expect(await firstTask.value == true)
        #expect(r.replyDraftBody == nil)
    }

    @Test func aFailedReplyDraftSendReleasesTheClaimSoARetryCanGoThrough() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "Hello,\n\nshared body", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first { $0.email == "emma@act.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.sendState = .sent; r.replied = true
        r.replyDraftBody = "Glad to help."

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(), sender: AlwaysFailSender()) == false)
        #expect(r.replySendClaimedAt == nil)   // retryable, never stuck claimed

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(), sender: CapturingSender()) == true)
    }

    @Test func aSecondFollowUpSendAttemptWhileTheFirstIsInFlightIsRefused() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")
        let sender = GatedSender()

        let firstTask = Task { await SendService.sendFollowUp(r, of: p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        await waitUntil("the send to reach the sender") { sender.callCount > 0 }

        let secondResult = await SendService.sendFollowUp(r, of: p, now: Date(timeIntervalSince1970: 20), sender: sender)
        #expect(secondResult == false)
        #expect(sender.callCount == 1)

        sender.release()
        #expect(await firstTask.value == true)
        #expect(r.followUpCount == 1)
    }

    @Test func aFailedFollowUpSendReleasesTheClaimSoARetryCanGoThrough() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")

        #expect(await SendService.sendFollowUp(r, of: p, now: Date(), sender: AlwaysFailSender()) == false)
        #expect(r.nudgeSendClaimedAt == nil)

        #expect(await SendService.sendFollowUp(r, of: p, now: Date(), sender: FakeSender()) == true)
    }

    @Test func aSecondConversationNudgeSendAttemptWhileTheFirstIsInFlightIsRefused() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")
        let sender = GatedSender()

        let firstTask = Task {
            await SendService.sendClosingNote(r, of: p,
                                                     now: Date(timeIntervalSince1970: 10), sender: sender)
        }
        await waitUntil("the send to reach the sender") { sender.callCount > 0 }

        let secondResult = await SendService.sendClosingNote(r, of: p,
                                                                    now: Date(timeIntervalSince1970: 20), sender: sender)
        #expect(secondResult == false)
        #expect(sender.callCount == 1)

        sender.release()
        #expect(await firstTask.value == true)
    }

    @Test func aFailedConversationNudgeSendReleasesTheClaimSoARetryCanGoThrough() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")

        #expect(await SendService.sendClosingNote(r, of: p,
                                                         now: Date(), sender: AlwaysFailSender()) == false)
        #expect(r.nudgeSendClaimedAt == nil)

        #expect(await SendService.sendClosingNote(r, of: p,
                                                         now: Date(), sender: FakeSender()) == true)
    }

    // sendFollowUp and sendConversationNudge share ONE claim field (they're mutually exclusive by
    // domain state: setConversationState always pairs with outcomeSourceRaw = .manual, which
    // isAwaitingFollowUp requires be unset). A reply-draft send is kept on its OWN field instead,
    // because a replied recipient CAN legitimately be due for a conversation nudge at the same
    // time (two different open surfaces), so sharing there would cause spurious refusals.
    @Test func aReplyDraftSendInFlightDoesNotBlockAConversationNudgeSendOnTheSameRecipient() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")
        r.replied = true
        r.replyDraftBody = "Glad to help."
        let replySender = GatedSender()

        let replyTask = Task { await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10), sender: replySender) }
        await waitUntil("the reply to reach the sender") { replySender.callCount > 0 }

        let nudgeResult = await SendService.sendClosingNote(r, of: p,
                                                                   now: Date(timeIntervalSince1970: 20), sender: CapturingSender())
        #expect(nudgeResult == true)

        replySender.release()
        #expect(await replyTask.value == true)
    }

    // Copy-out path: Dan sent the reply from Gmail himself; consume the draft + re-anchor, no send.
    @Test func recordAnswerSentConsumesTheDraftWithoutSending() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replyDraftSubject = "Re"; r.replyDraftBody = "a draft"
        r.recordAnswerSent(now: Date(timeIntervalSince1970: 7))
        #expect(r.replyDraftBody == nil)
        #expect(r.replyDraftSubject == nil)
        #expect(r.lastFollowUpAt == Date(timeIntervalSince1970: 7))
    }
}
