import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #2623: carrying the name through to `DisplayedAddress` is half the change. The other half is that the
// card actually DRAWS it, which no model test can see (L3: built is not wired). Rendered through the
// ViewInspector harness, so a name that never reaches the screen fails here rather than shipping as an
// invisible feature.
@Suite("The card draws whose address it is printing (#2623)")
struct CardAddressAttributionOnScreenTests {
    private func item(name: String?, role: String?) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Rosalind Verrier", discipline: "music",
                          venue: "The Green Room 42", performanceDate: "2026-08-17",
                          sourceListingURL: "https://thegreenroom42.venuetix.com/x",
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.presenter = "Rosalind Verrier"
        // #3169: against the LIVE clock, the same as its two siblings. This file was green through
        // the crossing only because it asserts on the address list, which renders whatever the badge
        // says, so it was the same rot with a later fuse rather than a different case.
        i.reachabilityProbedAt = LiveClockProbe.fresh
        i.reachabilityResult = .emailFound
        i.hasPendingRecipient = true
        i.contacts = [RecipientSnapshot(id: "marionalcottmusic@example.com", name: name,
                                        email: "marionalcottmusic@example.com", role: role,
                                        provenance: .performer, sendState: .pending, replied: false,
                                        lastReplyText: nil, resolution: nil, bounced: false,
                                        outcomeSource: nil)]
        return i
    }

    private func texts(_ item: QueueItem) throws -> [String] {
        let view = ProspectRowView(item: item, today: "2026-08-13", onKeep: {}, onDismiss: { _ in })
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func thenameAndRoleAppearOnTheCardBesideTheAddress() throws {
        let t = try texts(item(name: "Marion Alcott", role: "Musical Director"))
        #expect(t.contains("marionalcottmusic@example.com"))
        #expect(t.contains("Marion Alcott, Musical Director"))
    }

    // The nameless case is six of the 29 measured shows, so it is a layout the card really renders: the
    // address alone, with no empty line and no placeholder standing in for a name nobody found.
    @Test func anamelessAddressDrawsTheAddressAlone() throws {
        let t = try texts(item(name: nil, role: nil))
        #expect(t.contains("marionalcottmusic@example.com"))
        // No empty line and no stray comma standing in for a name nobody found, and exactly one line
        // fewer than the same card with a name on it.
        #expect(!t.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(!t.contains { $0.trimmingCharacters(in: .whitespaces) == "," })
        #expect(t.count == (try texts(item(name: "Marion Alcott", role: "Musical Director")).count - 1))
    }
}
