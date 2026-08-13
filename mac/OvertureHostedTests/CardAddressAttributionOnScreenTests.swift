import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #2623: carrying the name through to `DisplayedAddress` is half the change. The other half is that the
// card actually DRAWS it, which no model test can see (L3: built is not wired). Rendered through the
// ViewInspector harness, so a name that never reaches the screen fails here rather than shipping as an
// invisible feature.
@MainActor
@Suite("The card draws whose address it is printing (#2623)")
struct CardAddressAttributionOnScreenTests {
    private func item(name: String?, role: String?) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Pier Lamia Porter", discipline: "music",
                          venue: "The Green Room 42", performanceDate: "2026-08-17",
                          sourceListingURL: "https://thegreenroom42.venuetix.com/x", websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.presenter = "Pier Lamia Porter"
        i.reachabilityProbedAt = Date(timeIntervalSince1970: 1_780_000_000)
        i.reachabilityResult = .emailFound
        i.hasPendingRecipient = true
        i.contacts = [RecipientSnapshot(id: "jasonwetzelmusic@gmail.com", name: name,
                                        email: "jasonwetzelmusic@gmail.com", role: role,
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
        let t = try texts(item(name: "Jason Wetzel", role: "Musical Director"))
        #expect(t.contains("jasonwetzelmusic@gmail.com"))
        #expect(t.contains("Jason Wetzel, Musical Director"))
    }

    // The nameless case is six of the 29 measured shows, so it is a layout the card really renders: the
    // address alone, with no empty line and no placeholder standing in for a name nobody found.
    @Test func anamelessAddressDrawsTheAddressAlone() throws {
        let t = try texts(item(name: nil, role: nil))
        #expect(t.contains("jasonwetzelmusic@gmail.com"))
        // No empty line and no stray comma standing in for a name nobody found, and exactly one line
        // fewer than the same card with a name on it.
        #expect(!t.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(!t.contains { $0.trimmingCharacters(in: .whitespaces) == "," })
        #expect(t.count == (try texts(item(name: "Jason Wetzel", role: "Musical Director")).count - 1))
    }
}
