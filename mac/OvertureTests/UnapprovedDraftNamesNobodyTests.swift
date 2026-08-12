import Testing
import Foundation
import SwiftData

// #2545 retired most of this file. It existed because the card said "One email to everyone" three lines
// above one greeting per contact: the together/separately switch appeared whenever a show had two
// addressed contacts, while the single shared greeting only appeared once the show was APPROVED, so on a
// drafted show the control said one email and the greetings said two.
//
// There is no app-composed greeting to preview any more. The greeting is written into the body by
// whoever writes the body, so a card shows one draft and one greeting by construction, and the tests
// that pinned the preview's approval gate had nothing left to pin.
//
// What survives is #2015's own gate, which was never about greetings: naming WHO the next press of Send
// reaches is a claim about SENDING, and an unapproved draft sends to nobody.
@MainActor
@Suite("An unapproved draft names nobody as its next recipient (#2015)")
struct UnapprovedDraftNamesNobodyTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, status: ReviewStatus = .drafted, together: Bool = true,
                      contacts: [(String, String?)] = [("chelsea@everyvoicechoirs.org", nil),
                                                       ("marcus@everyvoicechoirs.org", "Marcus Hale")])
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
        p.setRecipients(contacts.map { email, name in
            Recipient(id: email, email: email, name: name, provenance: .presenter)
        })
        try? ctx.save()
        return p
    }

    // #2015's gate is untouched: naming WHO the next press of Send reaches is a claim about sending, and
    // an unapproved draft sends to nobody. Only the greeting preview lost the approval gate.
    @Test func anUnapprovedDraftStillNamesNobodyAsTheNextRecipient() throws {
        let ctx = ModelContext(try container())
        let drafted = QueueItem(show(ctx, status: .drafted))

        #expect(drafted.nextRecipientIds.isEmpty)
        #expect(drafted.hasPendingRecipient, "the contacts are ready; the show is what is not")
    }
}
