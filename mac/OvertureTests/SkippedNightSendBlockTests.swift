import Testing
import Foundation
import SwiftData

private final class CountingSender: MailSender, @unchecked Sendable {
    var sent: [OutgoingMail] = []
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent.append(mail)
        return SentReceipt(threadId: "t", messageID: "<m@x>")
    }
}

// #3326, plan 2.8: a pitch naming a night Dan skipped never leaves, whatever the screen allowed, and a
// pitch that does leave stamps what it promised (#3959).
@MainActor
@Suite("A pitch naming a skipped night does not send (#3326)")
struct SkippedNightSendBlockTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21, before every night below
    private static let nights = ["2026-10-06", "2026-10-13", "2026-10-20"]

    private func show(_ ctx: ModelContext, body: String) throws -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Skip Revue", performanceDate: Self.nights[0],
                                                             venue: "Room"),
                         groupName: "Skip Revue", discipline: "theater", venue: "Room",
                         performanceDate: Self.nights[0], sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.runNights = Self.nights
        p.runEndDate = Self.nights.last
        p.draftSubject = "Photographing your run"
        p.draftBody = body
        ctx.insert(p)
        let r = Recipient(id: "r-skip", email: "to@act.example", provenance: .act)
        p.setRecipients([r])
        try p.recordNightDecisions(pitched: [NightDecision(night: Self.nights[0], at: now, origin: .chosen),
                                             NightDecision(night: Self.nights[2], at: now, origin: .chosen)],
                                   skipped: [NightDecision(night: Self.nights[1], at: now, origin: .chosen)])
        try ctx.save()
        return p
    }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @Test func theServiceRefusesAPitchNamingASkippedNightAndClaimsNothing() async throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6, October 13 and October 20.")
        let sender = CountingSender()
        let sent = await SendService.sendOne(p, now: now, sender: sender)
        #expect(sent == false)
        #expect(sender.sent.isEmpty, "a pitch naming a skipped night reached the network")
        #expect(p.recipients.first?.sendState == .pending, "the refusal left the contact claimed")
    }

    // The positive control in the SAME fixture (L159): drop the skipped night from the words and it goes,
    // and the promise it froze is the nights it named.
    @Test func thePitchWithoutTheSkippedNightSendsAndFreezesItsPromise() async throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6 and October 20.")
        let sender = CountingSender()
        let sent = await SendService.sendOne(p, now: now, sender: sender)
        #expect(sent == true)
        #expect(sender.sent.count == 1)
        guard case .stamped(let promise)? = p.recipients.first?.promisedNights else {
            Issue.record("the send froze no promise"); return
        }
        #expect(promise.nights == ["2026-10-06", "2026-10-20"])
    }

    // The second way out: pitch the night after all, and the same draft now sends.
    @Test func pitchingTheNightAfterAllReleasesTheDraft() throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6, October 13 and October 20.")
        let today = EasternDate.dayString(from: now)
        #expect(KeptNights.skippedNightNamed(subject: p.draftSubject, body: p.draftBody ?? "", on: p,
                                             today: today) == "2026-10-13")
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-10-13", at: now, origin: .chosen)],
                                   skipped: [])
        #expect(KeptNights.skippedNightNamed(subject: p.draftSubject, body: p.draftBody ?? "", on: p,
                                             today: today) == nil)
    }
}
