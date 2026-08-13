import Testing
import Foundation
import SwiftData

// #2624: one contact in the live store carries one person's name against a different person's email
// address, with no page cited. The greeting is composed from the contact's `name`, so a pitch to it would
// open by addressing the artist and land in a third person's inbox at an agency (L75).
//
// The pairs below are SHAPES measured from a snapshot of the live store on 2026-08-13, with the names
// changed: the finding does not depend on the exact strings, and an issue or a test file is not the place
// to publish people's addresses. What is preserved from the real data is which SHAPE each row is, because
// that is the whole of what this guard turns on.
@Suite("An address nobody on the row accounts for (#2624)")
struct UnaccountedAddressGuardTests {

    private func fires(email: String, name: String?, sourceURL: String? = nil,
                       groupName: String? = nil, presenter: String? = nil) -> Bool {
        UnaccountedAddressGuard.looksLikeAnotherPersons(email: email, name: name, sourceURL: sourceURL,
                                                        groupName: groupName, presenter: presenter)
    }

    // THE row. An artist's name against an agency address whose local part is a third person, no page.
    @Test func anagencyAddressInAThirdPersonsNameIsCaught() {
        #expect(fires(email: "tommy@groundcontroltouring.com", name: "Jordan Smart",
                      groupName: "Jordan Smart / Jay Skaggs"))
    }

    // MARK: what it must PRESERVE (L104)

    // The 5 measured rows at a shared inbox. A person named as the contact at their organisation's general
    // address is the ordinary case, not a mismatch, and holding those back would be the guard doing more
    // damage than the defect.
    @Test func asharedInboxIsNotSomebodyElsesName() {
        #expect(!fires(email: "admin@redhookrecords.com", name: "Sun Chung"))
        #expect(!fires(email: "info@nynf.org", name: "Sean Tecson"))
        #expect(!fires(email: "office@frigid.nyc", name: "Conor Mullen"))
        #expect(!fires(email: "hello@fomentproductions.com", name: "Sarah Jones"))
        #expect(!fires(email: "bookings@example.org", name: "Sarah Jones"))
    }

    // The measured show inbox: a local part that is the SHOW's name rather than a person's.
    @Test func anaddressInTheShowsOwnNameIsAccountedFor() {
        #expect(!fires(email: "BwaySessions@gmail.com", name: "Ben Cameron",
                       groupName: "Broadway Sessions"))
    }

    @Test func anaddressInThePresentingOrganisationsNameIsAccountedFor() {
        #expect(!fires(email: "vivace@gmail.com", name: "Mara Lin", groupName: "Song & Word",
                       presenter: "Vivace Arts Collective"))
    }

    // A cited page is the evidence the runbook asks for, and #2382 deliberately allows a representative
    // named on the target's OWN page. Four of the six representative contacts in the store are that, and
    // every one of them must stay untouched.
    @Test func acitedPageAccountsForTheAddress() {
        #expect(!fires(email: "jed@rosegroupny.com", name: "Tatianna Cordoba",
                       sourceURL: "https://tatiannacordoba.com/contact"))
        // Whitespace is not a citation, so a blank string cannot buy an exemption.
        #expect(fires(email: "jed@rosegroupny.com", name: "Tatianna Cordoba", sourceURL: "   "))
    }

    // The ordinary personal address, in every shape the store holds it: the name itself, an initial plus
    // surname, and a first name alone.
    @Test func thecontactsOwnAddressIsNeverFlagged() {
        #expect(!fires(email: "jordan.smart@example.com", name: "Jordan Smart"))
        #expect(!fires(email: "jsmart@example.com", name: "Jordan Smart"))
        #expect(!fires(email: "jordan@example.com", name: "Jordan Smart"))
        #expect(!fires(email: "smartjordan99@example.com", name: "Jordan Smart"))
        // A plus tag is addressing, not identity.
        #expect(!fires(email: "jordan+shows@example.com", name: "Jordan Smart"))
    }

    // Failure paths. A row with no name makes no claim to contradict (19 of the 89 measured addresses),
    // and a row with no address has nothing to judge. Neither is this guard's business.
    @Test func arowWithNothingToContradictIsNeverFlagged() {
        #expect(!fires(email: "tommy@groundcontroltouring.com", name: nil))
        #expect(!fires(email: "tommy@groundcontroltouring.com", name: "   "))
        #expect(!fires(email: "", name: "Jordan Smart"))
        #expect(!fires(email: "not-an-address", name: "Jordan Smart"))
    }

    // A two-letter word must not account for an address by accident: "de" inside "dexter@" would otherwise
    // clear a stranger's address for anybody with a particle in their name.
    @Test func ashortParticleCannotAccountForAnAddress() {
        #expect(fires(email: "dexter@agency.example", name: "Raphaele de Boisblanc"))
    }
}

// #2624, the wiring. A rule that nothing writes and nothing reads is not a guard (L3, L46), and the
// consequence this issue asks for is specifically that such a contact "should not be sendable as a named
// decision maker", which is a claim about the SEND path rather than about the predicate.
@MainActor
@Suite("An unaccounted address is written by the run and blocks the send (#2624)")
struct UnaccountedAddressWiringTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Jordan Smart / Jay Skaggs",
                                          performanceDate: "2026-10-03", venue: "Jalopy Theatre")
        let p = Prospect(naturalKey: key, groupName: "Jordan Smart / Jay Skaggs", discipline: "music",
                         venue: "Jalopy Theatre", performanceDate: "2026-10-03", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 4, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func results(_ key: String, email: String, name: String?, sourceUrl: String? = nil) -> PrepResults {
        PrepResults(version: 9, generatedAt: "2026-08-13T00:00:00Z",
                    results: [PrepResult(naturalKey: key,
                                         contacts: [PrepContact(name: name, role: "Booking (Ground Control Touring)",
                                                                email: email, method: "named_decision_maker",
                                                                confidence: "low", provenance: "act",
                                                                sourceUrl: sourceUrl)],
                                         draft: nil)])
    }

    // THE test: the address goes in, the hold comes out, and the contact cannot be written to.
    @Test func anaddressInAnotherNameIsHeldBackAtIngest() throws {
        let ctx = try context()
        let p = show(ctx)

        _ = PrepImporter.ingest(results(p.naturalKey, email: "tommy@groundcontroltouring.com",
                                        name: "Jordan Smart"), into: ctx)

        let r = try #require(p.recipients.first)
        #expect(r.isLooksLikeAnotherPersons)
        #expect(r.isHeldByAGuard)
        #expect(r.holdReason == .unaccountedAddress)
        #expect(!r.isSendablePending)
        // And it is visible as somebody still waiting rather than a show that reads as finished (#792).
        #expect(r.isBlockedAwaitingReview)
    }

    // The ordinary contact this guard must not touch, through the same path.
    @Test func anordinaryContactIsUntouched() throws {
        let ctx = try context()
        let p = show(ctx)

        _ = PrepImporter.ingest(results(p.naturalKey, email: "jordan@groundcontroltouring.com",
                                        name: "Jordan Smart"), into: ctx)

        let r = try #require(p.recipients.first)
        #expect(!r.isLooksLikeAnotherPersons)
        #expect(r.isSendablePending)
    }

    // Dan's overrule. He can look at an address and judge it, so the hold is answerable, exactly like the
    // four guards beside it.
    @Test func dansOverruleReleasesTheSend() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, email: "tommy@groundcontroltouring.com",
                                        name: "Jordan Smart"), into: ctx)
        let r = try #require(p.recipients.first)

        r.looksLikeAnotherPersonsDismissed = true

        #expect(!r.isLooksLikeAnotherPersons)
        #expect(r.isSendablePending)
        #expect(r.holdReason == nil)
    }

    // Re-derived on every ingest rather than latched: a later run that finally cites a page clears the
    // hold, the same convention the other four guards follow.
    @Test func alaterRunThatCitesAPageClearsTheHold() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, email: "tommy@groundcontroltouring.com",
                                        name: "Jordan Smart"), into: ctx)
        #expect(try #require(p.recipients.first).isLooksLikeAnotherPersons)

        _ = PrepImporter.ingest(results(p.naturalKey, email: "tommy@groundcontroltouring.com",
                                        name: "Jordan Smart",
                                        sourceUrl: "https://jordansmartmusic.com/contact"), into: ctx)

        #expect(!(try #require(p.recipients.first).isLooksLikeAnotherPersons))
    }

    // Failure path: a contact Dan typed in himself, which this run does not report, is left alone
    // entirely. Note the narrow claim, checked rather than assumed: the importer matches by id, and
    // `apply` overwrites provenance from the incoming contact BEFORE the guards run, so a manual row the
    // run DOES report is judged like any other. That is how the four guards beside this one already
    // behave, and this guard deliberately does not invent a different rule for itself.
    @Test func amanualContactTheRunNeverNamesIsLeftAlone() throws {
        let ctx = try context()
        let p = show(ctx)
        let manual = Recipient(id: "tommy@groundcontroltouring.com", email: "tommy@groundcontroltouring.com",
                               name: "Jordan Smart", provenance: .manual)
        p.addRecipient(manual)
        try? ctx.save()

        _ = PrepImporter.ingest(results(p.naturalKey, email: "jordan@groundcontroltouring.com",
                                        name: "Jordan Smart"), into: ctx)

        let untouched = try #require(p.recipients.first { $0.provenance == .manual })
        #expect(!untouched.isLooksLikeAnotherPersons)
        #expect(untouched.isSendablePending)
    }
}
