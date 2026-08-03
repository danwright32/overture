import Testing
import Foundation
import SwiftData

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

// #651/#652: the recipient-scoped nudge send, so a multi-recipient show's active conversation
// threads on the RIGHT contact (not whichever recipient sent first) and a closing note resolves
// only that one contact, never a sibling or the whole show.
@MainActor
@Suite("Send recipient conversation nudge")
struct SendRecipientConversationNudgeTests {
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
    private func showWithTwoRecipients(_ ctx: ModelContext, state: ConversationState) -> (Prospect, Recipient, Recipient) {
        let p = Prospect(naturalKey: "k-\(state.rawValue)", groupName: "Aurora Strings", discipline: "music",
                         venue: "Carnegie Hall", performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.draftSubject = "Photographing Aurora Strings at Carnegie Hall."
        let a = Recipient(id: "a@org.org", email: "a@org.org", name: "Emma Robinson", provenance: .act)
        a.sendState = .sent; a.sentAt = Date(timeIntervalSince1970: 1)
        a.gmailThreadId = "th-a"; a.gmailMessageId = "<a@x.org>"
        a.conversationState = state
        let b = Recipient(id: "b@org.org", email: "b@org.org", name: "Presenter Contact", provenance: .presenter)
        b.sendState = .sent; b.sentAt = Date(timeIntervalSince1970: 1)
        b.gmailThreadId = "th-b"; b.gmailMessageId = "<b@x.org>"
        b.conversationState = state
        p.setRecipients([a, b])
        ctx.insert(p); try? ctx.save()
        return (p, a, b)
    }

    @Test func activeNudgeThreadsOnThisRecipientsOwnThreadAndReanchorsOnlyThisOne() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoRecipients(ctx, state: .wantsToBook)
        let sender = CapturingSender()
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(await SendService.sendConversationNudge(a, of: p, kind: .active(.wantsToBook), now: now, sender: sender) == true)
        #expect(sender.last?.threadId == "th-a")           // THIS contact's thread, not the lead rollup
        #expect(sender.last?.inReplyTo == "<a@x.org>")
        #expect(a.conversationRemindedAt == now)           // re-anchored
        #expect(b.conversationRemindedAt == nil)           // sibling untouched
        #expect(a.resolution == nil)                       // active nudge does not resolve
    }

    @Test func closingNudgeResolvesOnlyThisRecipientNeverTheSiblingOrTheShow() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = showWithTwoRecipients(ctx, state: .wantsToBook)
        let now = Date(timeIntervalSince1970: 20_000)

        #expect(await SendService.sendConversationNudge(a, of: p, kind: .closing, now: now, sender: CapturingSender()) == true)
        #expect(a.resolution == .declinedSoft)
        #expect(a.outcomeSource == .manual)
        #expect(a.conversationRemindedAt == now)
        #expect(b.resolution == nil)                       // sibling never cascaded (Dan's 2026-07-08 decision)
        #expect(b.sendState == .sent)                       // sibling not suppressed either
        #expect(p.outcome == .noResponse)                   // the WHOLE SHOW is never resolved by a per-recipient close
    }

    @Test func needsStateAndSuggestedAreNotSendable() async throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = showWithTwoRecipients(ctx, state: .interested)
        #expect(await SendService.sendConversationNudge(a, of: p, kind: .needsState, now: Date(), sender: CapturingSender()) == false)
        #expect(await SendService.sendConversationNudge(a, of: p, kind: .suggested(.interested), now: Date(), sender: CapturingSender()) == false)
    }

    @Test func aRecipientNeverEmailedCannotBeNudged() async throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = showWithTwoRecipients(ctx, state: .wantsToBook)
        a.sentAt = nil
        #expect(await SendService.sendConversationNudge(a, of: p, kind: .active(.wantsToBook), now: Date(), sender: CapturingSender()) == false)
    }

    @Test func aFailedSendRecordsTheRecipientsErrorAndDoesNotResolve() async throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = showWithTwoRecipients(ctx, state: .wantsToBook)
        #expect(await SendService.sendConversationNudge(a, of: p, kind: .closing, now: Date(), sender: FailSender()) == false)
        #expect(a.sendError != nil)
        #expect(a.resolution == nil)   // a failed closing send must not resolve the recipient
    }
}
