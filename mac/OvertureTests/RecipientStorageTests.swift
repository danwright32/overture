import Testing
import Foundation
import SwiftData

// #409: recipients are their own SwiftData rows, a cascade-deleted relationship on Prospect, with
// mutating helpers (setRecipients/addRecipient/removeRecipient/updateRecipient). These cover the
// relationship-mutation layer; the blob->rows migration is covered separately.
@MainActor
@Suite("Recipient storage")
struct RecipientStorageTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func makeProspect(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil,
                         priorRelationship: "warm", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func recipient(_ email: String, name: String? = nil,
                           provenance: RecipientProvenance = .act) -> Recipient {
        Recipient(id: email, email: email, name: name, provenance: provenance)
    }

    @Test func anewProspectHasNoRecipients() throws {
        let p = makeProspect(try context())
        #expect(p.recipients.isEmpty)
    }

    @Test func setRecipientsPersistsThroughTheStore() throws {
        let ctx = try context()
        let p = makeProspect(ctx)

        p.setRecipients([recipient("a@example.com", name: "Ann"),
                         recipient("b@example.com", name: "Bo", provenance: .presenter)])
        try ctx.save()

        let back = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(Set(back?.recipients.map(\.id) ?? []) == ["a@example.com", "b@example.com"])
    }

    @Test func addRecipientAppends() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com")])

        p.addRecipient(recipient("b@example.com"))

        #expect(Set(p.recipients.map(\.id)) == ["a@example.com", "b@example.com"])
    }

    @Test func removeRecipientDropsById() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com"), recipient("b@example.com")])

        p.removeRecipient(id: "a@example.com")

        #expect(p.recipients.map(\.id) == ["b@example.com"])
    }

    @Test func removeOrSuppressRecipientDeletesAPendingOne() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com"), recipient("b@example.com")])

        p.removeOrSuppressRecipient(id: "a@example.com")

        #expect(p.recipients.map(\.id) == ["b@example.com"])
    }

    @Test func removeOrSuppressRecipientSuppressesAnAlreadySentOne() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        let sent = recipient("a@example.com")
        sent.sendState = .sent
        sent.sentAt = Date()
        p.setRecipients([sent])

        p.removeOrSuppressRecipient(id: "a@example.com")

        #expect(p.recipients.map(\.id) == ["a@example.com"])
        #expect(sent.sendState == .suppressed)
        #expect(sent.suppressionReason == .removedByDan)
        #expect(sent.resolution == nil)
        #expect(sent.outcomeSource == nil)
    }

    @Test func removeOrSuppressRecipientIgnoresAnUnknownId() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com")])

        p.removeOrSuppressRecipient(id: "nope@example.com")

        #expect(p.recipients.map(\.id) == ["a@example.com"])
    }

    @Test func updateRecipientMutatesOneRow() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com"), recipient("b@example.com")])

        p.updateRecipient(id: "b@example.com") { $0.sendState = .sent }

        #expect(p.recipients.first { $0.id == "a@example.com" }?.sendState == .pending)
        #expect(p.recipients.first { $0.id == "b@example.com" }?.sendState == .sent)
    }

    @Test func updateRecipientIgnoresUnknownId() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com")])

        p.updateRecipient(id: "missing@example.com") { $0.bounced = true }

        #expect(p.recipients.map(\.id) == ["a@example.com"])
        #expect(p.recipients.first?.bounced == false)
    }
}
