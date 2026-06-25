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

@MainActor
@Suite("Send service")
struct SendServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
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
        p.contactEmail = email
        p.draftSubject = "S"; p.draftBody = draft
        ctx.insert(p)
        try? ctx.save()
    }

    @Test func pendingExcludesUnsendable() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        approved(ctx, group: "No Email", email: nil, ingested: Date(timeIntervalSince1970: 2))
        approved(ctx, group: "No Draft", draft: nil, ingested: Date(timeIntervalSince1970: 3))
        #expect(SendService.pending(in: ctx).map(\.groupName) == ["Ready"])
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
        p.contactEmail = "to@org.org"; p.draftSubject = "S"; p.draftBody = "Hi"
        ctx.insert(p)

        let sent = await SendService.sendOne(p, now: Date(), sender: FakeSender())
        #expect(sent)
        #expect(p.priorRelationshipAtSend == "booked")
    }

    @Test func sendsOneAndRecordsReceipt() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let now = Date(timeIntervalSince1970: 2_000_000)

        let outcome = await SendService.releaseDueSends(in: ctx, now: now, sender: FakeSender())
        #expect(outcome.sent == 1)

        let p = SendService.pending(in: ctx).first
        #expect(p == nil) // no longer pending (it has sentAt)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.first?.sentAt == now)
        #expect(all.first?.gmailThreadId == "t-123")
    }

    @Test func dripsOneAtATimeAndThrottlesTheRest() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        approved(ctx, group: "B", ingested: Date(timeIntervalSince1970: 2))
        let now = Date(timeIntervalSince1970: 2_000_000)

        let first = await SendService.releaseDueSends(in: ctx, now: now, sender: FakeSender())
        #expect(first.sent == 1)
        #expect(first.throttled == true) // B still waiting

        // Immediately after, the min-gap holds B back.
        let second = await SendService.releaseDueSends(in: ctx, now: now.addingTimeInterval(10), sender: FakeSender())
        #expect(second.sent == 0)
        #expect(second.throttled == true)

        // After the gap, B sends.
        let third = await SendService.releaseDueSends(in: ctx, now: now.addingTimeInterval(200), sender: FakeSender())
        #expect(third.sent == 1)
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

    @Test func sendFollowUpRecordsTheNudgeAndCapsAtTheMax() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        a.sentAt = Date(timeIntervalSince1970: 100)   // already sent
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(await SendService.sendFollowUp(a, now: now, sender: FakeSender()) == true)
        #expect(a.followUpCount == 1)
        #expect(a.lastFollowUpAt == now)
        #expect(a.sentAt == Date(timeIntervalSince1970: 100))   // original send untouched

        #expect(await SendService.sendFollowUp(a, now: now, sender: FakeSender()) == true)
        #expect(a.followUpCount == 2)
        // Capped at 2: a third nudge is refused.
        #expect(await SendService.sendFollowUp(a, now: now, sender: FakeSender()) == false)
        #expect(a.followUpCount == 2)
    }

    @Test func sendFollowUpStopsOnceReplied() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        a.sentAt = Date(); a.outcome = .replied
        #expect(await SendService.sendFollowUp(a, now: Date(), sender: FakeSender()) == false)
        #expect(a.followUpCount == 0)
    }

    @Test func sendOneRecordsErrorOnFailure() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        #expect(await SendService.sendOne(a, now: Date(), sender: AlwaysFailSender()) == false)
        #expect(a.sentAt == nil)
        #expect(a.sendError != nil)
    }

    @Test func recordsSendErrorAndKeepsItPending() async throws {
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        let outcome = await SendService.releaseDueSends(in: ctx, now: Date(timeIntervalSince1970: 2_000_000), sender: AlwaysFailSender())
        #expect(outcome.failed == 1)
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(p?.sentAt == nil)            // not marked sent
        #expect(p?.sendError != nil)         // failure recorded for retry
    }

    @Test func firstSendStoresTheMessageIDForThreading() async throws {
        // #74: the first send's Message-ID is kept so a later follow-up can reply to it.
        let ctx = ModelContext(try container())
        approved(ctx, group: "Ready", ingested: Date(timeIntervalSince1970: 1))
        _ = await SendService.releaseDueSends(in: ctx, now: Date(timeIntervalSince1970: 2_000_000), sender: FakeSender())
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(p?.gmailMessageId == "<mid-1@x.org>")
    }

    @Test func followUpRepliesOnTheOriginalThread() async throws {
        // #74: the nudge goes out In-Reply-To the original Message-ID, on the same thread, as a Re:.
        let ctx = ModelContext(try container())
        approved(ctx, group: "A", ingested: Date(timeIntervalSince1970: 1))
        let a = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        a.sentAt = Date(); a.gmailThreadId = "th-9"; a.gmailMessageId = "<orig@x.org>"
        a.draftSubject = "Photographs for A"

        let sender = CapturingSender()
        #expect(await SendService.sendFollowUp(a, now: Date(), sender: sender) == true)
        #expect(sender.last?.threadId == "th-9")
        #expect(sender.last?.inReplyTo == "<orig@x.org>")
        #expect(sender.last?.subject == "Re: Photographs for A")
    }
}
