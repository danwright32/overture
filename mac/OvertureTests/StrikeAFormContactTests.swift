import Testing
import Foundation
import SwiftData

// #2438: striking a contact whose only handle is a form was not remembered. `removeRecipientManually`
// recorded a refusal only when the recipient had an address, so a form-only one fell straight through to
// the hard delete, and a deleted pending row is indistinguishable from one never found: the next prep run
// put it back. Dan struck six of them by hand on 2026-08-10 and not one was remembered.
//
// This is L92, and it is where that lesson came from: a removal made durable by recording it against an
// identifier leaves behind every item that does not carry that identifier.
@MainActor
@Suite("Striking a contact whose only handle is a form (#2438)")
struct StrikeAFormContactTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "A Cabaret", performanceDate: "2026-09-12",
                                          venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "A Cabaret", discipline: "music", venue: "54 Below",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @discardableResult
    private func add(_ p: Prospect, name: String, email: String? = nil, formURL: String? = nil) -> Recipient {
        let r = Recipient(id: Recipient.makeId(email: email, formURL: formURL) ?? name, email: email,
                          name: name, provenance: .performer, contactFormURL: formURL)
        p.addRecipient(r)
        return r
    }

    // The defect: struck, and the next run puts it straight back.
    @Test func strikingAFormContactIsRemembered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let struck = add(p, name: "Eliah B. Johnson", formURL: "https://eliahbjohnson.example/contact")
        try ctx.save()

        ProspectMutations.removeRecipientManually(QueueItem(p), struck.id, struck.name,
                                                  prospects: [p], context: ctx,
                                                  feedback: ActionFeedback())

        let ledger = ContactRefusal.ledger(in: ctx)
        #expect(ledger.isRefused(email: nil, formURL: "https://eliahbjohnson.example/contact",
                                 showKey: p.naturalKey, orgKey: nil),
                "the strike left no record, so the next run rebuilds the contact")
    }

    // And the run that follows does not rebuild it, which is the whole point of remembering.
    @Test func theNextRunDoesNotBringItBack() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let struck = add(p, name: "Eliah B. Johnson", formURL: "https://eliahbjohnson.example/contact")
        try ctx.save()
        ProspectMutations.removeRecipientManually(QueueItem(p), struck.id, struck.name,
                                                  prospects: [p], context: ctx, feedback: ActionFeedback())

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey, contacts: [
                PrepContact(name: "Eliah B. Johnson", role: nil, email: nil, method: "form_or_dm",
                            confidence: "low", formUrl: "https://eliahbjohnson.example/contact",
                            provenance: "performer", sourceUrl: nil),
            ], draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ]), into: ctx)

        #expect(p.recipients.isEmpty, "the struck contact came back on the very next run")
    }

    // Striking one form contact must not strike another, which a rule keyed on anything coarser would do.
    @Test func strikingOneFormDoesNotStrikeAnother() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let struck = add(p, name: "Eliah B. Johnson", formURL: "https://eliahbjohnson.example/contact")
        add(p, name: "Zachary McIntyre", formURL: "https://zachmcintyre.example/booking")
        try ctx.save()

        ProspectMutations.removeRecipientManually(QueueItem(p), struck.id, struck.name,
                                                  prospects: [p], context: ctx, feedback: ActionFeedback())

        let ledger = ContactRefusal.ledger(in: ctx)
        #expect(!ledger.isRefused(email: nil, formURL: "https://zachmcintyre.example/booking",
                                  showKey: p.naturalKey, orgKey: nil))
        #expect(p.recipients.count == 1)
    }

    // An address strike is unchanged, so widening the key did not move the case #2392 already covered.
    @Test func strikingAnAddressStillWorksAsItDid() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let struck = add(p, name: "Someone", email: "someone@example.test")
        try ctx.save()

        ProspectMutations.removeRecipientManually(QueueItem(p), struck.id, struck.name,
                                                  prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(ContactRefusal.ledger(in: ctx).isRefused(email: "someone@example.test",
                                                          showKey: p.naturalKey, orgKey: nil))
    }

    // The run's work-list carries ADDRESSES only, because `refusedEmails` in the queue file is documented
    // as addresses. A struck form is refused on the way back in but not announced in advance, which is
    // the half of this issue that is deliberately not done here.
    @Test func aStruckFormIsNotPutIntoTheAddressWorkList() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let form = add(p, name: "Eliah B. Johnson", formURL: "https://eliahbjohnson.example/contact")
        let address = add(p, name: "Someone", email: "someone@example.test")
        try ctx.save()
        for r in [form, address] {
            ProspectMutations.removeRecipientManually(QueueItem(p), r.id, r.name,
                                                      prospects: [p], context: ctx, feedback: ActionFeedback())
        }

        let struck = ContactRefusal.ledger(in: ctx).struckAddresses(showKey: p.naturalKey, orgKey: nil)

        #expect(struck == ["someone@example.test"],
                "a form handle in refusedEmails would be a value the run reads as an email address")
    }
}
