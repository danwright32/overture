import Testing
import Foundation
import SwiftData

// #2397: the post-event closing note, which is the only email the conversation track has left. The
// pre-written note per active state went with the states that chose its wording.
@Suite("The closing note's copy")
struct ClosingNoteCopyTests {
    private func isLevelVoice(_ body: String) -> Bool {
        let lower = body.lowercased()
        let banned = ["love to", "thrilled", "excited", "can't wait", "delighted", "\u{2014}", "!"]
        return banned.allSatisfy { !lower.contains($0) }
    }

    @Test func theClosingNoteIsGraciousAndLevel() {
        let body = PostEventPrompt.closingNudgeBody(contactName: "Emma Robinson",
                                                    groupName: "Aurora Strings", venue: "Carnegie Hall")
        #expect(body.contains("Aurora Strings"))
        #expect(isLevelVoice(body))
    }

    @Test func amissingContactNameFallsBackGracefully() {
        let body = PostEventPrompt.closingNudgeBody(contactName: nil, groupName: "Aurora Strings", venue: nil)
        #expect(!body.isEmpty)
        #expect(isLevelVoice(body))
    }
}

// #651/#652: the recipient-scoped send, so a multi-contact show's note threads on the RIGHT contact
// rather than whichever one sent first. #2397: and what it RECORDS changed, which is the defect this
// carries the fix for.
@MainActor
@Suite("Sending the closing note (#2397)")
struct SendClosingNoteTests {
    private final class CapturingSender: MailSender, @unchecked Sendable {
        var last: OutgoingMail?
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            last = mail
            return SentReceipt(threadId: "t", messageID: "<m>")
        }
    }
    private struct FailSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show with two sent recipients, so cross-contamination between them is directly checkable.
    private func showWithTwoRecipients(_ ctx: ModelContext) -> (Prospect, Recipient, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Carnegie Hall", performanceDate: "2026-07-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.draftSubject = "Photographing Aurora Strings at Carnegie Hall."
        let a = Recipient(id: "a@org.org", email: "a@org.org", name: "Emma Robinson", provenance: .act)
        a.sendState = .sent; a.sentAt = Date(timeIntervalSince1970: 1)
        a.gmailThreadId = "th-a"; a.gmailMessageId = "<a@x.org>"
        let b = Recipient(id: "b@org.org", email: "b@org.org", name: "Presenter Contact", provenance: .presenter)
        b.sendState = .sent; b.sentAt = Date(timeIntervalSince1970: 1)
        b.gmailThreadId = "th-b"; b.gmailMessageId = "<b@x.org>"
        p.setRecipients([a, b])
        ctx.insert(p); try? ctx.save()
        return (p, a, b)
    }

    @Test func itThreadsOnThisContactsOwnThreadAndReanchorsOnlyThisOne() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoRecipients(ctx)
        let sender = CapturingSender()
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(await SendService.sendClosingNote(a, of: p, now: now, sender: sender) == true)
        #expect(sender.last?.threadId == "th-a")   // THIS contact's thread, not the lead rollup
        #expect(sender.last?.inReplyTo == "<a@x.org>")
        #expect(a.conversationRemindedAt == now)   // re-anchored, so it steps forward rather than nagging
        #expect(b.conversationRemindedAt == nil)   // sibling untouched
    }

    // THE fix. This path resolved the lead to a soft decline in every case, which claimed somebody had
    // turned Dan down when nobody had written back at all. The note's whole meaning is "never heard back",
    // and now that is what it records, at the SHOW, where an ending lives (#2394).
    @Test func sendingItRecordsTheShowAsNeverHeardBack() async throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = showWithTwoRecipients(ctx)

        #expect(await SendService.sendClosingNote(a, of: p, now: Date(timeIntervalSince1970: 20_000),
                                                 sender: CapturingSender()) == true)

        #expect(p.showOutcome == .neverHeardBack)
        #expect(p.showOutcome != .theySaidNotNow, "nobody turned Dan down; nobody answered at all")
    }

    // The contacts keep only routing facts, so no per-person judgement is written by a note about the show.
    // The old cascade guard (Dan's 2026-07-08 decision) is preserved by there being nothing to cascade.
    @Test func itWritesNothingOntoAnyContact() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoRecipients(ctx)

        _ = await SendService.sendClosingNote(a, of: p, now: Date(timeIntervalSince1970: 20_000),
                                             sender: CapturingSender())

        #expect(a.resolution == nil)
        #expect(b.resolution == nil)
        #expect(b.sendState == .sent, "the sibling is not suppressed either")
    }

    @Test func acontactNeverEmailedCannotBeSentOne() async throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = showWithTwoRecipients(ctx)
        a.sentAt = nil

        #expect(await SendService.sendClosingNote(a, of: p, now: Date(), sender: CapturingSender()) == false)
    }

    // A failed send records the error and records NO ending, so the show never reads as closed on the
    // strength of a message that did not leave (L12).
    @Test func afailedSendRecordsTheErrorAndNoEnding() async throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = showWithTwoRecipients(ctx)

        #expect(await SendService.sendClosingNote(a, of: p, now: Date(), sender: FailSender()) == false)

        #expect(a.sendError != nil)
        #expect(p.showOutcome == nil)
    }
}
