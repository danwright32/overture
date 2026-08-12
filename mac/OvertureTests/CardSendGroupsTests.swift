import Testing
import Foundation
import SwiftData

// #2046: a queue card works out who its email reaches ONCE.
//
// Three of the card's fields are answers to the same question (does anything on this show send, who does
// the next press of Send reach, and what greeting does one shared email carry), and each of them was
// asking it again from scratch. Every ask filters the show's recipients through the sendable predicate,
// which runs the draft lint over each contact's whole outgoing letter, and this happens while a card is
// merely being built for a scroll. An idle surface must pay nothing (#1923).
//
// The fix is structural rather than a cached number: the groups are worked out once and HANDED to the
// card, so a field cannot quietly go back to deriving its own. The first test below is what holds that,
// and it is the only kind of proof that stays true as fields are added.
@MainActor
@Suite("A queue card is handed its send groups instead of working them out three times (#2046)")
struct CardSendGroupsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, status: ReviewStatus = .approved, together: Bool = true,
                      contacts: [String] = ["chelsea@everyvoicechoirs.org", "marcus@everyvoicechoirs.org"])
    -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Every Voice Choirs", performanceDate: "2026-09-01",
                                          venue: "Merkin Hall")
        let p = Prospect(naturalKey: key, groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-09-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status, ingestedAt: Date())
        p.draftSubject = "Photographs of your September concert"
        p.draftBody = "Hello,\n\nI photograph performing arts in New York."
        p.sendsTogetherOverride = together
        ctx.insert(p)
        p.setRecipients(contacts.map { Recipient(id: $0, email: $0, name: nil, provenance: .presenter) })
        try? ctx.save()
        return p
    }

    // The cost claim, made structurally so it cannot rot. The show really does have two sendable
    // contacts; the card is handed groups that say otherwise. Every field that still went and asked the
    // show for itself contradicts what it was handed, and fails here.
    @Test func aCardReadsTheGroupsItIsHandedAndNeverAsksTheShowAgain() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        #expect(SendGroup.previewGroup(of: p).count == 2, "the show itself really does send to two")

        let item = QueueItem(p, sendGroups: SendGroup.CardGroups(preview: [], pending: []))

        #expect(item.hasPendingRecipient == false)
        #expect(item.nextRecipientIds.isEmpty)
    }

    // And the groups themselves keep the distinction the card depends on (#2049): what the email will
    // look like is a fact about the draft, while who the next press of Send reaches is a claim about
    // sending and keeps its approval gate.
    @Test func anUnapprovedShowPreviewsItsGroupButSendsToNobody() throws {
        let ctx = ModelContext(try container())
        let groups = SendGroup.CardGroups(of: show(ctx, status: .drafted))

        #expect(groups.preview.count == 2)
        #expect(groups.pending.isEmpty)
        #expect(groups.hasPending, "the show has contacts waiting; only sending is gated on approval")
    }

    @Test func anApprovedShowSendsToTheGroupItPreviews() throws {
        let ctx = ModelContext(try container())
        let groups = SendGroup.CardGroups(of: show(ctx, status: .approved))

        #expect(groups.pending.map(\.id) == groups.preview.map(\.id))
    }

    // A show with nothing waiting says so, which is what the card's "no contact to send to" surfaces read.
    @Test func aShowWithNoAddressedContactHasNothingPending() throws {
        let ctx = ModelContext(try container())
        let groups = SendGroup.CardGroups(of: show(ctx, contacts: []))

        #expect(groups.hasPending == false)
        #expect(groups.preview.isEmpty)
        #expect(groups.pending.isEmpty)
    }

    // The card's own fields still say what they said before, built the ordinary way. Without this the
    // test above would pass on a card that reads its handed groups and gets them wrong.
    @Test func anOrdinaryCardStillNamesEveryoneTheNextSendReaches() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        let item = QueueItem(p)

        #expect(item.hasPendingRecipient)
        #expect(item.nextRecipientIds.sorted()
                == ["chelsea@everyvoicechoirs.org", "marcus@everyvoicechoirs.org"])
    }
}
