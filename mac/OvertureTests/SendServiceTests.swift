import Testing
import Foundation
import SwiftData
@testable import Overture

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
                          draft: String? = "Hi", ingested: Date) {
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
    private func seedRecipient(_ p: Prospect, email: String?, name: String?) -> Recipient? {
        guard let id = Recipient.makeId(email: email, formURL: nil) else { return nil }
        let r = Recipient(id: id, email: email, name: name, provenance: .act)
        p.setRecipients([r])
        return r
    }

    private func approvedNamed(_ ctx: ModelContext, group: String, name: String?, email: String,
                               body: String, ingested: Date) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved, ingestedAt: ingested)
        p.draftSubject = "S"; p.draftBody = body
        ctx.insert(p)
        seedRecipient(p, email: email, name: name)
        try? ctx.save()
        return p
    }

    // Phase 2.5 (#393): the body is salutation-free; the app composes the greeting at send. The frozen
    // sent copy stays the BARE body so the voice pair learns the shared template, not the greeting.
    @Test func sendOneComposesTheGreetingOverTheBareBody() async throws {
        let ctx = ModelContext(try container())
        let p = approvedNamed(ctx, group: "Aurora", name: "Emma Robinson", email: "emma@act.example",
                              body: "I photograph performing arts in New York.",
                              ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(sender.last?.body == "Hi Emma,\n\nI photograph performing arts in New York.")
        #expect(p.sentBody == "I photograph performing arts in New York.")
    }

    @Test func sendOneGreetsThereWhenNoName() async throws {
        let ctx = ModelContext(try container())
        let p = approvedNamed(ctx, group: "Aurora", name: nil, email: "info@act.example",
                              body: "I document dance unobtrusively.",
                              ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(sender.last?.body == "Hi there,\n\nI document dance unobtrusively.")
    }

    @Test func sendingSnapshotsTheRelationshipAtContact() async throws {
        // #66: capture what the relationship was the moment Dan pitched, so a later Downbeat
        // match can tell a genuine new booking from a pre-existing client.
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Repeat Client", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "booked", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
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
        p.draftSubject = "Photographs for \(group)"; p.draftBody = "Hi"; p.sentAt = Date(timeIntervalSince1970: 100)
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
            fetch: { req in
                hit.url = req.url
                return (Data(#"{"threadId":"t-194","id":"m1"}"#.utf8),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })

        #expect(await SendService.sendOne(p, now: now, sender: sender) == true)
        #expect(p.sentAt == now)
        #expect(p.gmailThreadId == "t-194")
        #expect(p.gmailMessageId?.hasSuffix("@danwrightphotography.com>") == true)
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

    // MARK: - #475/#476 send-path claim (crash safety + concurrency guard)

    @Test func deliverClaimsSendingAndPersistsItBeforeTheNetworkCallResolves() async throws {
        let modelContainer = try container()
        let ctx = ModelContext(modelContainer)
        let p = approvedNamed(ctx, group: "Aurora", name: "Emma", email: "emma@act.example",
                              body: "Hi", ingested: Date(timeIntervalSince1970: 1))
        let recipient = p.recipients.first!
        let sender = GatedSender()

        let task = Task { await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        while sender.callCount == 0 { await Task.yield() }

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
                              body: "Hi", ingested: Date(timeIntervalSince1970: 1))
        let sender = GatedSender()

        let firstTask = Task { await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        while sender.callCount == 0 { await Task.yield() }   // the first call is now parked mid-send

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

    @Test func sendOneFansOutToEachRecipientWithItsOwnGreeting() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "I document dance.", ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        // First click -> the act contact, greeted by her own name.
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)
        #expect(sender.last?.to == "emma@act.example")
        #expect(sender.last?.body == "Hi Emma,\n\nI document dance.")
        // The show keeps a pending recipient, so it is NOT yet fully contacted and stays sendable.
        #expect(p.status == .approved)
        #expect(p.recipients.first { $0.email == "emma@act.example" }?.sendState == .sent)
        #expect(p.recipients.first { $0.email == "noah@present.example" }?.sendState == .pending)

        // Second click -> the presenter, greeted by his own name.
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 20), sender: sender) == true)
        #expect(sender.last?.to == "noah@present.example")
        #expect(sender.last?.body == "Hi Noah,\n\nI document dance.")
        // Every recipient sent -> now contacted.
        #expect(p.status == .contacted)

        // A third click is a no-op: nothing left to send (kills the duplicate-send risk).
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 30), sender: sender) == false)
    }

    @Test func firstRecipientSetsTheLeadRollupWriteOnce() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "I document dance.", ingested: Date(timeIntervalSince1970: 1))
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
        let p = twoRecipients(ctx, body: "I document dance.", ingested: Date(timeIntervalSince1970: 1))

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: CapturingSender())
        let afterFirst = p.sentBody

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 20), sender: CapturingSender())
        #expect(p.sentBody == "I document dance.")   // the BARE body, no greeting baked in
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
        let p = performerWithOverride(ctx, overrideBody: "I saw you're self-presenting Midnight Quartet.",
                                      sharedBody: "I saw Midnight Quartet is self-presenting.",
                                      ingested: Date(timeIntervalSince1970: 1))
        let sender = CapturingSender()

        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.last?.body == "Hi Maya,\n\nI saw you're self-presenting Midnight Quartet.")
    }

    // The bug the red-team caught: the voice-learning snapshot (#119) must freeze what was ACTUALLY
    // sent, not the shared draft the override replaced, or a later run learns from text nobody read.
    @Test func sendOneFreezesTheOverrideBodyForVoiceLearningNotTheSharedDraft() async throws {
        let ctx = ModelContext(try container())
        let p = performerWithOverride(ctx, overrideBody: "I saw you're self-presenting Midnight Quartet.",
                                      sharedBody: "I saw Midnight Quartet is self-presenting.",
                                      ingested: Date(timeIntervalSince1970: 1))

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: CapturingSender())

        #expect(p.sentBody == "I saw you're self-presenting Midnight Quartet.")
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
        p.draftSubject = "S"; p.draftBody = "The shared third-person body."
        ctx.insert(p)
        let performer = Recipient(id: "solo@performer.example", email: "solo@performer.example",
                                  name: "Solo Performer", provenance: .performer)
        p.setRecipients([performer])
        try? ctx.save()

        let sender = CapturingSender()
        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.last?.body == "Hi Solo,\n\nThe shared third-person body.")
        #expect(p.sentBody == "The shared third-person body.")
    }

    // MARK: - #421 recipient-scoped reply send + copy-out

    @Test func sendReplyDraftSendsOnTheContactThreadAndConsumesTheDraft() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "shared body", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first { $0.email == "emma@act.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.sendState = .sent; r.replied = true
        r.replyDraftSubject = "Re: Photographing you"; r.replyDraftBody = "Glad to help — July works."
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)
        #expect(sender.last?.to == "emma@act.example")
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
        let p = twoRecipients(ctx, body: "shared body", ingested: Date(timeIntervalSince1970: 1))
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
        let p = twoRecipients(ctx, body: "x", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first!
        r.gmailThreadId = "rt"; r.sendState = .sent          // no replyDraftBody
        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(), sender: CapturingSender()) == false)
    }

    // MARK: - #468 (SUP-005) secondary-send claim guards

    @Test func aSecondReplyDraftSendAttemptWhileTheFirstIsInFlightIsRefused() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "shared body", ingested: Date(timeIntervalSince1970: 1))
        let r = p.recipients.first { $0.email == "emma@act.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.sendState = .sent; r.replied = true
        r.replyDraftSubject = "Re: Photographing you"; r.replyDraftBody = "Glad to help — July works."
        let sender = GatedSender()

        let firstTask = Task { await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10), sender: sender) }
        while sender.callCount == 0 { await Task.yield() }   // the first call is now parked mid-send

        let secondResult = await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 20), sender: sender)
        #expect(secondResult == false)
        #expect(sender.callCount == 1)   // the second attempt never reached the network at all

        sender.release()
        #expect(await firstTask.value == true)
        #expect(r.replyDraftBody == nil)
    }

    @Test func aFailedReplyDraftSendReleasesTheClaimSoARetryCanGoThrough() async throws {
        let ctx = ModelContext(try container())
        let p = twoRecipients(ctx, body: "shared body", ingested: Date(timeIntervalSince1970: 1))
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
        while sender.callCount == 0 { await Task.yield() }

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
            await SendService.sendConversationNudge(r, of: p, kind: .active(.wantsToBook),
                                                     now: Date(timeIntervalSince1970: 10), sender: sender)
        }
        while sender.callCount == 0 { await Task.yield() }

        let secondResult = await SendService.sendConversationNudge(r, of: p, kind: .active(.wantsToBook),
                                                                    now: Date(timeIntervalSince1970: 20), sender: sender)
        #expect(secondResult == false)
        #expect(sender.callCount == 1)

        sender.release()
        #expect(await firstTask.value == true)
    }

    @Test func aFailedConversationNudgeSendReleasesTheClaimSoARetryCanGoThrough() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = sentContact(ctx, group: "A")

        #expect(await SendService.sendConversationNudge(r, of: p, kind: .active(.wantsToBook),
                                                         now: Date(), sender: AlwaysFailSender()) == false)
        #expect(r.nudgeSendClaimedAt == nil)

        #expect(await SendService.sendConversationNudge(r, of: p, kind: .active(.wantsToBook),
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
        while replySender.callCount == 0 { await Task.yield() }

        let nudgeResult = await SendService.sendConversationNudge(r, of: p, kind: .active(.wantsToBook),
                                                                   now: Date(timeIntervalSince1970: 20), sender: CapturingSender())
        #expect(nudgeResult == true)

        replySender.release()
        #expect(await replyTask.value == true)
    }

    // Copy-out path: Dan sent the reply from Gmail himself; consume the draft + re-anchor, no send.
    @Test func recordRepliedInGmailConsumesTheDraftWithoutSending() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replyDraftSubject = "Re"; r.replyDraftBody = "a draft"
        r.recordRepliedInGmail(now: Date(timeIntervalSince1970: 7))
        #expect(r.replyDraftBody == nil)
        #expect(r.replyDraftSubject == nil)
        #expect(r.lastFollowUpAt == Date(timeIntervalSince1970: 7))
    }
}
