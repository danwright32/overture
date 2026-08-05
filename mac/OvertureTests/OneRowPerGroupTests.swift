import Testing
import Foundation
import SwiftData

// #2126: one row per EMAIL, chosen from the contacts that actually QUALIFY for the list asking.
//
// `SendGroup.isRepresentative` picks the lowest sorted id of the whole group and knows nothing about
// whether that contact belongs in the list. Every surface then ANDs it with its own eligibility test, and
// the two compose wrongly: when the alphabetically first contact is the one that stopped qualifying, the
// WHOLE conversation disappears, because the list is standing on somebody it has already excluded.
//
// `peers(of:in:)` filters on sendGroupId alone with no resolution filter, so a booked or declined contact
// stays the representative permanently and its verdict speaks for colleagues who are still live.
//
// Filter first, then collapse. The row then always stands on somebody the list actually wants.
@MainActor
@Suite("One row per email, chosen from the contacts that qualify")
struct OneRowPerGroupTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func show(_ ctx: ModelContext, _ group: String = "Shared Send") -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    // "aaa@" sorts first, so it is always the anchor the old rule picks.
    @discardableResult
    private func contact(_ p: Prospect, _ address: String, sentAt: Date, group: String? = "g") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sendGroupId = group
        r.sentAt = sentAt
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = "t"
        p.setRecipients(p.recipients + [r])
        return r
    }

    // MARK: the duplicate Dan saw

    // Dan, 2026-08-05, on the Due sheet: "why does it seem like there are two email threads?" One email,
    // one thread, two people, so one conversation to categorise.
    @Test func oneSharedEmailRaisesOneConversation() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        for address in ["aaa@org.example", "zzz@org.example"] {
            let r = contact(p, address, sentAt: daysAgo(6))
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        let due = ConversationReminder.dueRecipients(from: [p], now: now)
        #expect(due.count == 1)
        #expect(due.first?.recipient.id == "aaa@org.example")
    }

    // And the count Dan reads on the sheet says one thing to do, not two.
    @Test func theDueCountCountsTheConversationOnce() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        for address in ["aaa@org.example", "zzz@org.example"] {
            let r = contact(p, address, sentAt: daysAgo(6))
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        #expect(DueWork.counts(prospects: [p], now: now, reminder: .init()).conversations == 1)
    }

    // MARK: the work a naive collapse would delete

    // A state recorded on the SECOND contact is a real decision Dan made. Collapsing to the lowest id
    // alone would leave that reminder belonging to a row nothing reads: gone from Due and from Follow-ups
    // with nothing to bring it back.
    @Test func aStateSetOnTheSecondContactStillRaisesItsReminder() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "aaa@org.example", sentAt: daysAgo(30))          // no reply, no state, nothing due
        let zzz = contact(p, "zzz@org.example", sentAt: daysAgo(30))
        zzz.replied = true
        zzz.repliedAt = daysAgo(20)
        zzz.setConversationState(.hasQuestion, now: daysAgo(20))     // due again after 2 days

        let due = ConversationReminder.dueRecipients(from: [p], now: now)
        #expect(due.count == 1)
        #expect(due.first?.recipient.id == "zzz@org.example", "the row must stand on the contact that is due")
    }

    // MARK: the bug already shipped in the other lists

    // A contact who declined stays the lowest id forever, so it stays the anchor forever. Its own "this
    // one is closed" verdict must not speak for a colleague on the same email who is still live.
    @Test func aResolvedAnchorDoesNotSilenceALiveColleague() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let aaa = contact(p, "aaa@org.example", sentAt: daysAgo(6))
        aaa.resolution = .declinedHard
        contact(p, "zzz@org.example", sentAt: daysAgo(6))            // still in play, nudge due

        let rows = ReachedOutQueue.activeWithDates(from: [p], now: now)
        #expect(rows.count == 1)
        #expect(rows.first?.recipient.id == "zzz@org.example")
    }

    // Same shape on the nudge track: the anchor has already been nudged to its cap, the colleague has not.
    @Test func aNudgeDueOnTheSecondContactIsNotHiddenByTheFirst() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let aaa = contact(p, "aaa@org.example", sentAt: daysAgo(30))
        aaa.resolution = .declinedHard                                // this one is done
        contact(p, "zzz@org.example", sentAt: daysAgo(30))            // this one is overdue a nudge

        let due = FollowUp.dueRecipients(from: [p], now: now)
        #expect(due.count == 1)
        #expect(due.first?.recipient.id == "zzz@org.example")
    }

    // MARK: the ordinary cases stay ordinary

    // Two SEPARATE emails on one show are two conversations, not one, and must not be collapsed.
    @Test func twoSeparateSendsStayTwoRows() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        for (address, group) in [("aaa@org.example", "g1"), ("zzz@org.example", "g2")] {
            let r = contact(p, address, sentAt: daysAgo(6), group: group)
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        #expect(ConversationReminder.dueRecipients(from: [p], now: now).count == 2)
        #expect(ReachedOutQueue.activeWithDates(from: [p], now: now).count == 2)
    }

    // A contact on no send group at all is its own conversation, the shape nearly every row in the store
    // has, and must not be folded in with anybody.
    @Test func contactsWithNoSendGroupAreEachTheirOwnRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        for address in ["aaa@org.example", "zzz@org.example"] {
            let r = contact(p, address, sentAt: daysAgo(6), group: nil)
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        #expect(ConversationReminder.dueRecipients(from: [p], now: now).count == 2)
    }
}
