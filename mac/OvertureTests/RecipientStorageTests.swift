import Testing
import Foundation
@testable import Overture

// Phase 1 (#391): recipients are stored as a JSON blob on Prospect (recipientsRaw) with a computed
// [Recipient] accessor and mutating helpers, mirroring the rejectedBookingIdsRaw raw-string idiom.
// These cover the storage layer only; the backfill that seeds recipients[0] is covered separately.
@Suite("Recipient storage")
struct RecipientStorageTests {
    private func makeProspect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "warm", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    private func recipient(_ email: String, name: String? = nil,
                           provenance: RecipientProvenance = .act) -> Recipient {
        Recipient(id: email, email: email, name: name, provenance: provenance)
    }

    @Test func emptyRawDecodesToNoRecipients() {
        let p = makeProspect()
        #expect(p.recipientsRaw == "")
        #expect(p.recipients.isEmpty)
    }

    @Test func setRecipientsRoundTrips() {
        let p = makeProspect()
        let a = recipient("a@example.com", name: "Ann")
        let b = recipient("b@example.com", name: "Bo", provenance: .presenter)

        p.setRecipients([a, b])

        #expect(p.recipients == [a, b])
        // Persisted as JSON, not empty, so a re-read after a store reload still decodes.
        #expect(!p.recipientsRaw.isEmpty)
    }

    @Test func addRecipientAppends() {
        let p = makeProspect()
        p.setRecipients([recipient("a@example.com")])

        p.addRecipient(recipient("b@example.com"))

        #expect(p.recipients.map(\.id) == ["a@example.com", "b@example.com"])
    }

    @Test func removeRecipientDropsById() {
        let p = makeProspect()
        p.setRecipients([recipient("a@example.com"), recipient("b@example.com")])

        p.removeRecipient(id: "a@example.com")

        #expect(p.recipients.map(\.id) == ["b@example.com"])
    }

    @Test func updateRecipientMutatesOneElement() {
        let p = makeProspect()
        p.setRecipients([recipient("a@example.com"), recipient("b@example.com")])

        p.updateRecipient(id: "b@example.com") { $0.sendState = .sent }

        #expect(p.recipients[0].sendState == .pending)
        #expect(p.recipients[1].sendState == .sent)
    }

    @Test func updateRecipientIgnoresUnknownId() {
        let p = makeProspect()
        p.setRecipients([recipient("a@example.com")])

        p.updateRecipient(id: "missing@example.com") { $0.bounced = true }

        #expect(p.recipients == [recipient("a@example.com")])
    }
}
