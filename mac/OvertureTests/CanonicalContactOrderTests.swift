import Testing
import Foundation
import SwiftData

// #4352, plan v7 Step T (the correction of 2026-09-27, #4106 comment 5858964900): every per-row reader of
// a show's contacts reads them in ONE canonical order, `Recipient.id` then the store's identifier.
//
// WHY. `Prospect.recipients` is a relationship, and SwiftData hands it back in whatever order it chooses:
// Step T0 measured it changing after a save and a refetch, and probe 0c.5 measured 86 to 124 entry
// comparisons per synthetic run where it moved under an UNCHANGED row. The row's `RecipientFacts`
// (standings, searchable contacts) and the card's first held reason and first misgreeted contact all
// followed it, so a retained row or card could differ from a rebuilt one with nothing about the show
// changed, which a verifier would report as a mismatch.
//
// Each test drives the relationship order itself. An UNSAVED relationship keeps the order it was
// assigned, which each one confirms with a `#require` before it asserts anything (L159), so the order is
// genuinely varied rather than assumed to be.
//
// Every address is invented, on example.org (L155, L222).
@MainActor
@Suite("Every per-row reader of a show's contacts reads one canonical order (#4352)")
final class CanonicalContactOrderTests {
    private let container: ModelContainer

    init() throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
    }

    // Deliberately NOT in id order as written, so the relationship's own order and the canonical one differ.
    private let addresses = ["rowan@example.org", "hazel@example.org", "yarrow@example.org"]

    @discardableResult
    private func show(_ order: [String], into ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "cco-show", groupName: "Juniper Choral Society", discipline: "choral",
                         venue: "Harbor Hall", performanceDate: "2027-03-10", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        ctx.insert(p)
        p.setRecipients(order.map { Recipient(id: $0, email: $0, name: "Name \($0.prefix(4))", provenance: .act) })
        return p
    }

    private func orders() -> [[String]] {
        CanonicalOracle.permutations(addresses, count: 12, seed: 4352_01)
    }

    // The accessor every per-row reader goes through (the row's facts and the card, which
    // `RecipientWalkCountTests` holds to it): the same order whatever order the relationship holds.
    @Test func countedRecipientsReadsOneOrderWhateverTheRelationshipHolds() throws {
        var seen: Set<[String]> = []
        var relationshipOrders: Set<[String]> = []
        for order in orders() {
            let p = show(order, into: ModelContext(container))
            try #require(p.recipients.map(\.id) == order,
                         "fixture: an unsaved relationship keeps the order it was assigned")
            relationshipOrders.insert(p.recipients.map(\.id))
            seen.insert(p.countedRecipients.map(\.id))
        }
        try #require(relationshipOrders.count > 1, "fixture: the relationship must be seen in several orders")
        #expect(seen == [addresses.sorted()], "orders seen: \(seen.map { $0.joined(separator: ",") }.sorted())")
    }

    // The row: its standings and its searchable contacts, as the pass builds them.
    @Test func theRowsContactFactsAreOneValueWhateverTheRelationshipHolds() throws {
        var facts: [RecipientFacts] = []
        for order in orders() {
            let p = show(order, into: ModelContext(container))
            try #require(p.recipients.map(\.id) == order)
            facts.append(RecipientFacts.of(p))
        }
        let first = try #require(facts.first)
        #expect(facts.allSatisfy { $0 == first }, "the row's contact facts follow the relationship order")
        #expect(first.searchableContacts.map(\.email) == addresses.sorted())
    }

    // One address on two contacts of one show: `id` ties, so the store's identifier decides, and it decides
    // the same way whichever of the two the relationship lists first.
    @Test func twoContactsSharingAnAddressKeepOneOrder() throws {
        let ctx = ModelContext(container)
        let p = show([], into: ctx)
        let a = Recipient(id: "shared@example.org", email: "shared@example.org", name: "First", provenance: .act)
        let b = Recipient(id: "shared@example.org", email: "shared@example.org", name: "Second", provenance: .act)
        var seen: Set<[String]> = []
        for pair in [[a, b], [b, a]] {
            p.setRecipients(pair)
            try #require(p.recipients.map(\.name) == pair.map(\.name))
            seen.insert(p.countedRecipients.compactMap(\.name))
        }
        #expect(seen.count == 1, "orders seen: \(seen.map { $0.joined(separator: ",") }.sorted())")
    }

    // What production actually meets: the relationship as the STORE hands it back after a save. Whatever
    // order comes back, the canonical one.
    @Test func afterAStoreRoundTripTheOrderIsStillTheCanonicalOne() throws {
        for order in [addresses, addresses.reversed()] {
            let store = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
            let writer = ModelContext(store)
            show(order, into: writer)
            try writer.save()
            let fetched = try #require(try ModelContext(store).fetch(FetchDescriptor<Prospect>()).first)
            #expect(fetched.countedRecipients.map(\.id) == addresses.sorted())
        }
    }

    // The two readers outside the pass that pick ONE contact by position (siblings of the per-row class):
    // the report's booking attribution and the lesson distiller's outcome contact.
    @Test func thePicksOfOneContactReadTheCanonicalOrder() throws {
        var sources: Set<String> = []
        var outcomeContacts: Set<String> = []
        for order in orders() {
            let p = show(order, into: ModelContext(container))
            try #require(p.recipients.map(\.id) == order)
            for r in p.recipients {
                r.resolution = .booked
                r.outcomeSource = r.id == "hazel@example.org" ? .manual : .auto
            }
            sources.insert(p.bookingSource.map { "\($0)" } ?? "nil")
            outcomeContacts.insert(VoiceFeedbackBuilder.outcomeRecipient(p) ?? "nil")
        }
        #expect(sources == ["\(OutcomeSource.manual)"], "sources seen: \(sources.sorted())")
        #expect(outcomeContacts == ["hazel@example.org"], "contacts seen: \(outcomeContacts.sorted())")
    }

    // The lesson export's reply pairs: two contacts whose rewritten replies tie on outcome and on the moment
    // they were sent come out in one order whatever order the relationship holds (review of #4352).
    @Test func tiedReplyPairsExportInTheCanonicalOrder() throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        var seen: Set<[String]> = []
        for order in orders() {
            let p = show(order, into: ModelContext(container))
            try #require(p.recipients.map(\.id) == order)
            for r in p.recipients {
                r.originalReplyDraftBody = "Thanks for writing back, happy to talk dates for the spring concert."
                r.sentReplyBody = "Thank you for the note. I would love to talk about spring dates; when suits you?"
                r.replySentAt = sentAt
            }
            let pairs = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2027-01-01T00:00:00Z").pairs
            seen.insert(pairs.compactMap(\.outcomeRecipientId))
        }
        try #require(seen.first?.count == 3, "fixture: every contact's rewrite must count as a lesson")
        #expect(seen == [addresses.sorted()], "orders seen: \(seen.map { $0.joined(separator: ",") }.sorted())")
    }
}
