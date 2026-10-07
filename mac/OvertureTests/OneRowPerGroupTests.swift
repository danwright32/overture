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

    private func show(_ ctx: ModelContext, _ group: String = "Shared Send",
                      event: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: event, sourceListingURL: nil,
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
        let p = show(ctx, "Shared Send", event: "2020-01-01")
        for address in ["aaa@org.example", "zzz@org.example"] {
            let r = contact(p, address, sentAt: daysAgo(6))
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        let due = PostEventPrompt.dueRecipients(from: [p], now: now)
        #expect(due.count == 1)
        #expect(due.first?.recipient.id == "aaa@org.example")
    }

    // And the count Dan reads on the sheet says one thing to do, not two.
    @Test func theDueCountCountsTheConversationOnce() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Shared Send", event: "2020-01-01")
        for address in ["aaa@org.example", "zzz@org.example"] {
            let r = contact(p, address, sentAt: daysAgo(6))
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        // #3890: while those replies are unanswered the show owes ONE thing, the answer, and the
        // post-event prompt yields to it. Still one row for the shared email, which is this test's subject.
        let waiting = DueWork.counts(prospects: [p], inquiries: [], now: now, replyRunAlive: false)
        #expect(waiting.repliesToAnswer == 1)
        #expect(waiting.total == 1)

        // Answered, the prompt comes back, and it is still one prompt for the show rather than one per
        // contact on the shared email.
        for r in p.recipients { r.recordAnswerSent(now: now) }
        #expect(DueWork.counts(prospects: [p], inquiries: [], now: now, replyRunAlive: false).afterTheShow == 1)
    }

    // MARK: the work a naive collapse would delete

    // #2126's rule, on the track that remains: the collapse to one row per email must happen AFTER the due
    // test, never by lowest id alone. Filtering first would drop the whole group whenever the
    // alphabetically first contact was the one not due, and the work would be gone from Due and from
    // Follow-ups with nothing to bring it back.
    //
    // #2397: proved with a contact the first one cannot speak for. `aaa` has bounced, so it earns nothing;
    // `zzz` is live on a show whose date has passed, so it earns the post-event prompt.
    @Test func thecollapseHappensAfterTheDueTestNotByLowestIdAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Shared Send", event: "2020-01-01")
        let aaa = contact(p, "aaa@org.example", sentAt: daysAgo(30))
        aaa.bounced = true
        _ = contact(p, "zzz@org.example", sentAt: daysAgo(30))

        let due = PostEventPrompt.dueRecipients(from: [p], now: now)
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

    // Two SEPARATE emails on one show are two conversations to CHASE, which is why the nudge track still
    // sees two. #2396 changed what Dan is shown about them: the Reached out stage is one row per SHOW now,
    // because he judges events rather than contacts, so two conversations about one event are one decision
    // and one row. The two counts below are deliberately different quantities, not a contradiction.
    @Test func twoSeparateSendsAreTwoConversationsAndOneRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Shared Send", event: "2020-01-01")
        for (address, group) in [("aaa@org.example", "g1"), ("zzz@org.example", "g2")] {
            let r = contact(p, address, sentAt: daysAgo(6), group: group)
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        #expect(PostEventPrompt.dueRecipients(from: [p], now: now).count == 2)
        #expect(ReachedOutQueue.activeWithDates(from: [p], now: now).count == 1)
    }

    // A contact on no send group at all is its own conversation, the shape nearly every row in the store
    // has, and must not be folded in with anybody.
    @Test func contactsWithNoSendGroupAreEachTheirOwnRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Shared Send", event: "2020-01-01")
        for address in ["aaa@org.example", "zzz@org.example"] {
            let r = contact(p, address, sentAt: daysAgo(6), group: nil)
            r.replied = true
            r.repliedAt = daysAgo(1)
        }
        #expect(PostEventPrompt.dueRecipients(from: [p], now: now).count == 2)
    }
}

// #4567: a send group in ONE order, whatever order the show's contacts arrive in.
//
// A contact's `id` is its address, and one show can hold two contacts on one address inside one send
// group. `SendGroup.peers` sorted by `id` alone, so those two kept the order the relationship handed them
// over in, which SwiftData does not hold stable (L343, L419). `ReplyIdentity.answering` takes the first
// peer on the writer's address, so which contact a reply row names could move between launches on
// unchanged data, and `SendGroup.isRepresentative` compared `id`s, so BOTH twins stood for the group.
// `Recipient.inSendOrder` ended on the same tie, and the send sheet and a separately sent show's first
// email read it.
//
// WHAT THIS RUNS. One show, one email to four contacts, two of them on one address, read through 20
// seeded permutations of the contacts and compared by the store's identifier. The seed is fixed, so a
// red run reproduces exactly (L339). Every name and address is invented (L155, L222).
@MainActor
@Suite("A send group holds one order whatever order its contacts arrive in (#4567)")
struct SendGroupTotalOrderTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let seed: UInt64 = 4567
    private let permutationCount = 20
    private let twin = "ann@org.example"

    init() throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        context = container.mainContext
    }

    // The twins are planted in the middle, so neither end of the planted order is already the sorted one,
    // and their address sorts lowest, so they are the two the group's representative is chosen between.
    private func planted() throws -> (show: Prospect, contacts: [Recipient]) {
        let p = Prospect(naturalKey: "twin show", groupName: "Quarry Singers", discipline: "choral",
                         venue: "Quarry Hall", performanceDate: "2027-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        context.insert(p)
        let people = [("zed@org.example", "Zed"), (twin, "Tess"), (twin, "Toby"), ("kim@org.example", "Kim")]
        p.setRecipients(people.map { address, name in
            let r = Recipient(id: address, email: address, name: name, provenance: .act)
            r.sendGroupId = "g"
            r.sendState = .sent
            r.gmailThreadId = "t"
            // The twin address wrote back, recorded on every peer as detection does (#2113).
            r.replied = true
            r.replyFromAddress = twin
            return r
        })
        // Saved, so every identifier the order falls back to is a permanent one.
        try context.save()
        return (p, p.recipients)
    }

    private func permutations(of contacts: [Recipient]) -> [[Recipient]] {
        var generator = SeededGenerator(seed: seed)
        return (0..<permutationCount).map { _ in contacts.shuffled(using: &generator) }
    }

    // The positive control: the group holds the tie this exists to break, and the shuffle moves it, so a
    // green below is about the tie rather than about a group with none (L159).
    @Test func theGroupHoldsTwoContactsOnOneAddressAndTheShuffleMovesThem() throws {
        let (_, contacts) = try planted()
        let twins = contacts.filter { $0.id == twin }
        #expect(twins.count == 2)
        #expect(Set(twins.map(\.persistentModelID)).count == 2)
        let twinOrders = Set(permutations(of: contacts).map { order in
            order.filter { $0.id == twin }.map(\.persistentModelID)
        })
        #expect(twinOrders.count == 2, "the shuffle never swapped the twins, so nothing below is tested")
    }

    @Test func peersAreInOneOrderWhateverOrderTheContactsArriveIn() throws {
        let (_, contacts) = try planted()
        let anchor = try #require(contacts.first { $0.id == "kim@org.example" })
        let orders = Set(permutations(of: contacts).map { order in
            SendGroup.peers(of: anchor, among: order).map(\.persistentModelID)
        })
        #expect(orders.count == 1,
                "peers came back in \(orders.count) orders over \(permutationCount) permutations of seed \(seed)")
    }

    @Test func theReplyRowNamesOneContactWhateverOrderTheContactsArriveIn() throws {
        let (_, contacts) = try planted()
        let anchor = try #require(contacts.first { $0.id == "kim@org.example" })
        let named = Set(permutations(of: contacts).map { order in
            ReplyIdentity.answering(for: anchor, among: order).persistentModelID
        })
        #expect(named.count == 1,
                "the reply row named \(named.count) contacts over \(permutationCount) permutations of seed \(seed)")
        #expect(contacts.first { $0.persistentModelID == named.first }?.id == twin)
    }

    @Test func exactlyOneContactStandsForTheGroup() throws {
        let (show, contacts) = try planted()
        let standing = contacts.filter { SendGroup.isRepresentative($0, in: show) }
        #expect(standing.count == 1, "\(standing.count) contacts stand for one email")
    }

    @Test func theSendOrderIsOneOrderWhateverOrderTheContactsArriveIn() throws {
        let (_, contacts) = try planted()
        let orders = Set(permutations(of: contacts).map { order in
            Recipient.inSendOrder(order).map(\.persistentModelID)
        })
        #expect(orders.count == 1,
                "the send order came back in \(orders.count) orders over \(permutationCount) permutations of seed \(seed)")
    }
}
