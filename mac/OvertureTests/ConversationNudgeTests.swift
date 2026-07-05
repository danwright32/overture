import Testing
import Foundation
import SwiftData
@testable import Overture

// The conversation-nudge copy (#111): a pre-written, reviewable note per active state plus the
// post-event closing note, all in Dan's level voice (no performative enthusiasm, no em dashes).
@Suite("Conversation nudge copy")
struct ConversationNudgeCopyTests {
    private func isLevelVoice(_ body: String) -> Bool {
        let lower = body.lowercased()
        let banned = ["love to", "thrilled", "excited", "can't wait", "delighted", "—", "!"]
        return banned.allSatisfy { !lower.contains($0) }
    }

    @Test func eachActiveStateHasItsOwnLevelNudge() {
        let bodies = ConversationState.allCases.filter(\.isActive).map {
            ConversationReminder.nudgeBody(for: $0, contactName: "Emma Robinson", groupName: "Aurora Strings", venue: "Carnegie Hall")
        }
        for b in bodies {
            #expect(b.contains("Aurora Strings"))
            #expect(b.contains("Emma"))
            #expect(isLevelVoice(b))
        }
        #expect(Set(bodies).count == bodies.count)   // distinct copy per state
    }

    @Test func theClosingNoteIsGraciousAndLevel() {
        let body = ConversationReminder.closingNudgeBody(contactName: "Emma Robinson", groupName: "Aurora Strings", venue: "Carnegie Hall")
        #expect(body.contains("Aurora Strings"))
        #expect(isLevelVoice(body))
    }

    @Test func aMissingContactNameFallsBackGracefully() {
        let body = ConversationReminder.nudgeBody(for: .wantsToBook, contactName: nil, groupName: "Aurora Strings", venue: nil)
        #expect(!body.isEmpty)
        #expect(isLevelVoice(body))
    }
}

@MainActor
@Suite("Send conversation nudge")
struct SendConversationNudgeTests {
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

    private func sentLead(_ ctx: ModelContext, state: ConversationState, outcome: Outcome = .replied) -> Prospect {
        let p = Prospect(naturalKey: "k-\(state.rawValue)", groupName: "Aurora Strings", discipline: "music",
                         venue: "Carnegie Hall", performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.contactEmail = "to@org.org"
        p.draftSubject = "Photographing Aurora Strings at Carnegie Hall."
        p.sentAt = Date(timeIntervalSince1970: 1)
        p.gmailThreadId = "th-9"
        p.gmailMessageId = "<orig@x.org>"
        p.conversationState = state
        p.outcome = outcome
        ctx.insert(p); try? ctx.save()
        return p
    }

    @Test func activeNudgeThreadsReanchorsAndLeavesFollowUpCapAlone() async throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .wantsToBook)
        let sender = CapturingSender()
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(await SendService.sendConversationNudge(p, kind: .active(.wantsToBook), now: now, sender: sender) == true)
        #expect(sender.last?.threadId == "th-9")          // threads onto the original conversation
        #expect(sender.last?.inReplyTo == "<orig@x.org>")
        #expect(p.conversationRemindedAt == now)          // re-anchor
        #expect(p.followUpCount == 0)                      // separate track, untouched
        #expect(p.outcome == .replied)                    // active nudge does not resolve
    }

    @Test func closingNudgeResolvesToLostSoftManual() async throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .wantsToBook)
        let now = Date(timeIntervalSince1970: 20_000)

        #expect(await SendService.sendConversationNudge(p, kind: .closing, now: now, sender: CapturingSender()) == true)
        #expect(p.outcome == .lostSoft)
        #expect(p.conversationStateSourceRaw == nil)      // not the conversation source...
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)   // ...the OUTCOME is manual
        #expect(p.conversationRemindedAt == now)
    }

    @Test func closingNudgeWritesThroughToEngagedContactsAndSuppressesTheUntriedOne() async throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .wantsToBook)
        let engaged = Recipient(id: "to@org.org", email: "to@org.org", provenance: .act)
        engaged.sendState = .sent
        let untried = Recipient(id: "pres@org.org", email: "pres@org.org", provenance: .presenter)
        untried.sendState = .pending
        p.setRecipients([engaged, untried])
        try? ctx.save()

        #expect(await SendService.sendConversationNudge(p, kind: .closing, now: Date(), sender: CapturingSender()) == true)
        #expect(p.outcome == .lostSoft)
        #expect(engaged.resolution == .declinedSoft)   // engaged contact resolved on the closing note
        #expect(untried.resolution == nil)             // never emailed -> stays accurate
        #expect(untried.sendState == .suppressed)      // #542: taken out of future sends too
        #expect(untried.suppressionReason == .declined)
    }

    @Test func needsStateIsNotSendable() async throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .interested)
        #expect(await SendService.sendConversationNudge(p, kind: .needsState, now: Date(), sender: CapturingSender()) == false)
    }

    @Test func aSuggestionIsNotSendable() async throws {
        // A suggestion is confirmed/corrected, not emailed; sending one must no-op.
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .wantsToBook)
        #expect(await SendService.sendConversationNudge(p, kind: .suggested(.wantsToBook), now: Date(), sender: CapturingSender()) == false)
    }

    @Test func aLeadNeverEmailedCannotBeNudged() async throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .wantsToBook)
        p.sentAt = nil   // offline reply, no thread to reply on
        #expect(await SendService.sendConversationNudge(p, kind: .active(.wantsToBook), now: Date(), sender: CapturingSender()) == false)
    }

    @Test func aFailedSendRecordsTheErrorAndDoesNotResolve() async throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, state: .wantsToBook)
        #expect(await SendService.sendConversationNudge(p, kind: .closing, now: Date(), sender: FailSender()) == false)
        #expect(p.sendError != nil)
        #expect(p.outcome == .replied)   // a failed closing send must not resolve the lead
    }
}
