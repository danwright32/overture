import Testing
import Foundation
import SwiftData

// #2015. Dan's rule, extended from the TEXT of an email (#2010) to WHO it goes to:
//
//   "this is a p0 and follows the same rule we were working on. Nothing should override what I see on
//    the screen. It should show me every email it's going to send to and I should be able to add/remove
//    emails as needed"  (2026-08-03)
//
// A show can carry several contacts at once, found by a Prep run, found by a paid check, or added by Dan
// himself. Pressing Send picks one of them by a rank Dan cannot see, and a contact he added by hand ranks
// LAST, behind anything the app found. So he can add the person he actually knows and watch the email go
// to a general inbox instead, with the screen reporting "Sent".
//
// The order itself is a real judgment and stays (#366/#368: pitch the act, the presenter only after).
// What changes is that it stops being invisible.
@MainActor
@Suite("Every address a show will email is visible (#2015)")
struct EveryAddressIsVisibleTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func approvedProspect(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k|2026-09-12|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.draftSubject = "Photographing Aurora Strings"
        p.draftBody = "Hello,\n\nI photograph performing arts in New York."
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func add(_ ctx: ModelContext, to p: Prospect, email: String, name: String?,
                     provenance: RecipientProvenance) -> Recipient {
        let r = Recipient(id: email, email: email, name: name, provenance: provenance)
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    // The failure Dan hit, as a test. He adds the person he knows to a show that already carries a found
    // address, and the next send does NOT go to his contact.
    @Test func thecontactDanAddedIsNotTheOneTheNextSendTargets() throws {
        let ctx = try context()
        let p = approvedProspect(ctx)
        add(ctx, to: p, email: "info@thevenue.example", name: nil, provenance: .act)
        add(ctx, to: p, email: "sarah@company.example", name: "Sarah Chen", provenance: .manual)

        let next = SendService.nextPendingRecipient(for: p)

        #expect(next?.email == "info@thevenue.example",
                "the found address still wins the order, which is exactly why it has to be visible")
    }

    // So the card must SAY which one is next. Resolved from the real send path, never re-derived, so the
    // marker and the send can never disagree about who is about to be emailed.
    // #2033: a show sends its contacts TOGETHER by default, so "the contact the next Send goes to" is now
    // every contact it reaches. The promise #2015 made is unchanged and stronger: the card names who is
    // about to be emailed, and now it cannot name only the first of two.
    @Test func thecardNamesTheContactTheNextSendWillGoTo() throws {
        let ctx = try context()
        let p = approvedProspect(ctx)
        add(ctx, to: p, email: "info@thevenue.example", name: nil, provenance: .act)
        add(ctx, to: p, email: "sarah@company.example", name: "Sarah Chen", provenance: .manual)

        let item = QueueItem(p)

        #expect(item.nextRecipientIds == SendGroup.pendingGroup(of: p).map(\.id))
        #expect(item.nextRecipientIds.contains("info@thevenue.example"))
        #expect(item.nextRecipientIds.contains("sarah@company.example"),
                "both are on the one email this show would send")
    }

    // A show nobody can send yet names nobody, rather than pointing at a contact that will not receive
    // anything. An unapproved draft is the ordinary case here.
    @Test func ashowThatCannotSendYetNamesNoNextContact() throws {
        let ctx = try context()
        let p = approvedProspect(ctx)
        p.status = .drafted
        add(ctx, to: p, email: "info@thevenue.example", name: nil, provenance: .act)

        #expect(QueueItem(p).nextRecipientIds.isEmpty)
    }

    // "Every email it's going to send to" has to be honest about the ones it will NOT: a contact held by a
    // guard is on the show but is not going to be emailed, and saying so is the whole point.
    @Test func acontactHeldByAGuardIsMarkedAsNotSending() throws {
        let ctx = try context()
        let p = approvedProspect(ctx)
        let held = add(ctx, to: p, email: "press@thevenue.example", name: "Press Office",
                       provenance: .presenter)
        held.looksLikePressContact = true

        let item = QueueItem(p)
        let snapshot = try #require(item.contacts.first { $0.id == "press@thevenue.example" })

        #expect(snapshot.isHeldFromSending, "a held contact must not read as one that will be emailed")
        #expect(!item.nextRecipientIds.contains("press@thevenue.example"))
    }

    // And an ordinary contact is not marked as held, or the marker means nothing.
    @Test func anordinaryContactIsNotMarkedAsHeld() throws {
        let ctx = try context()
        let p = approvedProspect(ctx)
        add(ctx, to: p, email: "sarah@company.example", name: "Sarah Chen", provenance: .act)

        let snapshot = try #require(QueueItem(p).contacts.first)

        #expect(!snapshot.isHeldFromSending)
    }

    // A contact already written to is neither next nor held: it is done. Three different facts, and the
    // card has to be able to tell them apart.
    @Test func acontactAlreadyWrittenToIsNeitherNextNorHeld() throws {
        let ctx = try context()
        let p = approvedProspect(ctx)
        let sent = add(ctx, to: p, email: "sarah@company.example", name: "Sarah Chen", provenance: .act)
        sent.sendState = .sent
        sent.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        add(ctx, to: p, email: "info@thevenue.example", name: nil, provenance: .presenter)

        let item = QueueItem(p)
        let done = try #require(item.contacts.first { $0.id == "sarah@company.example" })

        #expect(!done.isHeldFromSending)
        #expect(item.nextRecipientIds == ["info@thevenue.example"],
                "the contact already written to is not on the next email; the unsent one is")
    }
}
