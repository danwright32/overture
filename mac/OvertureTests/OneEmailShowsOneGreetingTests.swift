import Testing
import Foundation
import SwiftData

// #2049: the card said "One email to everyone" three lines above one greeting per contact.
//
// Dan, reading the live card minutes after #2034 shipped: "is this saying that it's going to greet them
// by their emails? like 'Hello, chelsea@everyvoicechoirs.org' is literally what it's going to write?"
//
// It was not. The greeting was "Hello," and the faint text beside it was the per-contact label, which
// falls back to the address when a contact has no name. But he could not tell, and the reason he could
// not tell is a real contradiction: the SWITCH is offered whenever a show has two addressed contacts,
// while the single shared greeting only appeared once the show was APPROVED. So on a drafted show, which
// is every show while he is reviewing it, the control said one email and the greetings said two.
//
// The approval gate is right for "who is the next press of Send going to reach" (#2015: a show that
// cannot send names nobody). It is wrong for previewing the greeting, which is about what the email will
// look like when it does go.
@MainActor
@Suite("One email shows one greeting, approved or not (#2049)")
struct OneEmailShowsOneGreetingTests {
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
        p.draftBody = "I photograph performing arts in New York."
        p.sendsTogetherOverride = together
        ctx.insert(p)
        p.setRecipients(contacts.map { email, name in
            Recipient(id: email, email: email, name: name, provenance: .presenter)
        })
        try? ctx.save()
        return p
    }

    // The whole rule as one assertion: whenever the card OFFERS the together switch and it is set to
    // together, the card shows exactly one opening. Stated against the two fields the view actually
    // branches on, so it cannot pass while the screen still contradicts itself.
    @Test func aCardOfferingOneEmailNeverShowsAGreetingPerContact() throws {
        let ctx = ModelContext(try container())
        let item = QueueItem(show(ctx, status: .drafted))

        #expect(item.offersSendModeChoice, "two addressed contacts, so the switch is on the card")
        #expect(item.sendsTogether)
        #expect(item.jointOpening != nil,
                "the card offers one email, so it must show the one greeting that email carries")
    }

    // The state Dan was actually looking at. A drafted show is where he spends his review time, and it
    // was the only state the shared greeting never appeared in.
    @Test func aDraftedShowShowsTheSharedGreeting() throws {
        let ctx = ModelContext(try container())
        let item = QueueItem(show(ctx, status: .drafted))

        #expect(item.jointOpening == "Hello,")
    }

    @Test func anApprovedShowStillShowsIt() throws {
        let ctx = ModelContext(try container())
        let item = QueueItem(show(ctx, status: .approved))

        #expect(item.jointOpening == "Hello,")
    }

    // Sending separately genuinely is one email each, so one greeting each is right and the shared line
    // must NOT appear. The per-contact labels belong here too: these are distinct messages.
    @Test func sendingSeparatelyStillShowsAGreetingPerContact() throws {
        let ctx = ModelContext(try container())
        let item = QueueItem(show(ctx, status: .drafted, together: false))

        #expect(item.jointOpening == nil)
        #expect(item.contacts.count == 2)
    }

    // One contact is one email whatever the mode, so there is no shared greeting to show and no switch
    // offered beside it.
    @Test func oneContactHasNoSharedGreeting() throws {
        let ctx = ModelContext(try container())
        let item = QueueItem(show(ctx, contacts: [("chelsea@everyvoicechoirs.org", nil)]))

        #expect(item.offersSendModeChoice == false)
        #expect(item.jointOpening == nil)
    }

    // What the card promises about the greeting and what the SEND will do have to agree, so the preview
    // is the same composition the send path uses, not a second one written for the screen.
    @Test func thePreviewedGreetingIsTheOneTheSendWouldUse() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .approved)
        let item = QueueItem(p)

        #expect(item.jointOpening == JointOpening.text(for: SendGroup.pendingGroup(of: p), of: p))
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
