import Testing
import Foundation

private func item(groupName: String = "Aurora Strings", venue: String? = "Weill Recital Hall",
                  contacts: [RecipientSnapshot] = []) -> QueueItem {
    var q = QueueItem(
        id: "k", groupName: groupName, discipline: "music", venue: venue,
        performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
    )
    q.contacts = contacts
    return q
}

private func contact(name: String? = nil, email: String? = nil) -> RecipientSnapshot {
    RecipientSnapshot(id: email ?? name ?? "c", name: name, email: email, role: nil,
                      provenance: .act, sendState: .sent, replied: false, lastReplyText: nil,
                      resolution: nil, bounced: false, outcomeSource: nil)
}

@Suite("ShowSearch")
struct ShowSearchTests {
    @Test func matchesOrgNameCaseInsensitively() {
        #expect(ShowSearch.matches(item(groupName: "Aurora Strings"), query: "aurora"))
        #expect(ShowSearch.matches(item(groupName: "Aurora Strings"), query: "AURORA STRINGS"))
        #expect(!ShowSearch.matches(item(groupName: "Aurora Strings"), query: "Lumen"))
    }

    @Test func matchesVenue() {
        #expect(ShowSearch.matches(item(venue: "Weill Recital Hall"), query: "weill"))
        #expect(!ShowSearch.matches(item(venue: nil), query: "weill"))
    }

    @Test func matchesContactNameOrEmail() {
        let withContact = item(contacts: [contact(name: "Emma Roth", email: "emma@aurorastrings.example")])
        #expect(ShowSearch.matches(withContact, query: "emma"))
        #expect(ShowSearch.matches(withContact, query: "aurorastrings.example"))
        #expect(!ShowSearch.matches(withContact, query: "nobody"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(ShowSearch.matches(item(), query: ""))
        #expect(ShowSearch.matches(item(), query: "   "))
    }
}
