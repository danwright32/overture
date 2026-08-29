import Testing
import Foundation
import SwiftData

// #2033. Once two contacts have received the SAME email (#2031), everything downstream of the send has
// to know it. Eleven surfaces were written when one contact meant one email, and each of them is wrong
// in its own way about a shared thread: two "send nudge" buttons for one conversation, two OmniFocus
// tasks in an app Dan reads away from his desk, and a follow-up cap of two that a pair of contacts can
// spend four times over by clicking a different row each time.
//
// One definition of "the contacts that received this email" (`SendGroup`), read by all of them, rather
// than each surface working it out and drifting.
@MainActor
@Suite("A group is one email everywhere downstream (#2033)")
struct GroupIsOneEmailDownstreamTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show whose two contacts went out on ONE email: same group, same thread, same moment.
    @discardableResult
    private func jointlySent(_ ctx: ModelContext, sentAt: Date = Date(timeIntervalSince1970: 100),
                             group: String? = "grp-1") -> (Prospect, Recipient, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora", discipline: "music", venue: "V",
                         performanceDate: "2026-12-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.draftSubject = "S"; p.draftBody = "B"
        p.sentAt = sentAt
        ctx.insert(p)
        let a = Recipient(id: "emma@org.example", email: "emma@org.example", name: "Emma", provenance: .presenter)
        let b = Recipient(id: "noah@org.example", email: "noah@org.example", name: "Noah", provenance: .presenter)
        for r in [a, b] {
            r.sendState = .sent
            r.sentAt = sentAt
            r.gmailThreadId = "thread-1"
            r.gmailMessageId = "<m-1>"
            r.sendGroupId = group
            ctx.insert(r)
        }
        p.setRecipients([a, b])
        try? ctx.save()
        return (p, a, b)
    }

    // MARK: - the definition itself

    @Test func thecontactsOnOneEmailAreItsGroup() throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = jointlySent(ctx)

        #expect(SendGroup.peers(of: a, in: p).map(\.id) == [a.id, b.id])
        #expect(SendGroup.peers(of: b, in: p).map(\.id) == [a.id, b.id])
    }

    // A contact who got their own email is a group of one, so every caller can read one definition
    // without asking whether a group exists.
    @Test func acontactWhoGotTheirOwnEmailIsAGroupOfOne() throws {
        let ctx = ModelContext(try container())
        let (p, a, _) = jointlySent(ctx, group: nil)

        #expect(SendGroup.peers(of: a, in: p).map(\.id) == [a.id])
    }

    // MARK: - the lists show one entry per email

    @Test func thefollowUpsDueListShowsOneRowPerEmail() throws {
        let ctx = ModelContext(try container())
        let (p, _, _) = jointlySent(ctx, sentAt: Date(timeIntervalSince1970: 0))
        let later = Date(timeIntervalSince1970: 100 * 86_400)

        let due = FollowUp.dueRecipients(from: [p], now: later)

        #expect(due.count == 1, "one email is one thing to chase, not two")
    }

    @Test func thereachedOutQueueShowsOneRowPerEmail() throws {
        let ctx = ModelContext(try container())
        let (p, _, _) = jointlySent(ctx, sentAt: Date(timeIntervalSince1970: 0))

        let rows = ReachedOutQueue.activeWithDates(from: [p], now: Date(timeIntervalSince1970: 86_400))

        #expect(rows.count == 1)
    }

    @Test func omniFocusFilesOneTaskPerEmail() throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = jointlySent(ctx, sentAt: Date(timeIntervalSince1970: 0))
        // Both contacts carry an untriaged reply, which is the state that emits a triage task each.
        for r in [a, b] {
            r.replied = true
            r.repliedAt = Date(timeIntervalSince1970: 86_400)
        }

        let tasks = OmniFocusSync.desired(from: [p], now: Date(timeIntervalSince1970: 2 * 86_400), horizonDays: 14)

        #expect(tasks.count == 1, "two tasks for one conversation is two of them to tidy up on his phone")
    }

    // MARK: - the cap is spent once

    @Test func anudgeOnASharedThreadReachesEveryoneAndCountsOnce() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = jointlySent(ctx, sentAt: Date(timeIntervalSince1970: 0))
        let sender = GroupCapturingSender()

        #expect(await SendService.sendFollowUp(a, of: p, now: Date(timeIntervalSince1970: 100 * 86_400),
                                               sender: sender) == true)

        #expect(sender.last?.to == ["emma@org.example", "noah@org.example"],
                "the nudge lands on a thread they are both reading, so it must be addressed to both")
        #expect(a.followUpCount == 1 && b.followUpCount == 1)
    }

    // The failure this protects: the cap is per contact, so clicking a DIFFERENT member of the same group
    // would buy another nudge on a conversation that has already had its two.
    @Test func thenudgeCapCannotBeSpentTwiceByClickingTheOtherContact() async throws {
        let ctx = ModelContext(try container())
        let (p, a, b) = jointlySent(ctx, sentAt: Date(timeIntervalSince1970: 0))
        let sender = GroupCapturingSender()
        let config = FollowUpConfig()
        var clock = Date(timeIntervalSince1970: 100 * 86_400)

        var sends = 0
        for _ in 0..<(config.maxFollowUps + 2) {
            for r in [a, b] {
                if await SendService.sendFollowUp(r, of: p, now: clock, sender: sender, config: config) {
                    sends += 1
                }
                clock = clock.addingTimeInterval(60 * 86_400)
            }
        }

        #expect(sends == config.maxFollowUps, "the conversation has one cap, not one each")
    }
}

// Records every mail it is handed, so a test can assert who a group nudge was addressed to.
private final class GroupCapturingSender: MailSender, @unchecked Sendable {
    var all: [OutgoingMail] = []
    var last: OutgoingMail? { all.last }
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        all.append(mail)
        return SentReceipt(threadId: "thread-1", messageID: "<m-2>")
    }
}
