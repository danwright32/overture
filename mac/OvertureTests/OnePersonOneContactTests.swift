import Testing
import Foundation
import SwiftData

// #2422, Dan on the live build 2026-08-10 looking at a prepped card: "and I've got two of the same
// person." He had "Devin Marlowe, No email yet" and "Devin Marlowe, devin@devinmarlowe.example" as
// two rows on one show, and the draft composed a greeting for each.
//
// The importer matched an incoming contact to an existing recipient by id, which is the email or
// `form:<url>`, so one person found two ways gets two ids by construction; and by provenance, which is
// switched off on any batch carrying more than one contact of that provenance (#408). Every multi
// performer show trips that guard, so on the shows this app exists to pitch the append branch was the
// only live branch and a re-run always duplicated rather than corrected.
@MainActor
@Suite("One person is one contact (#2422)")
struct OnePersonOneContactTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Cabaret for the Chronically Dramatic",
                                          performanceDate: "2026-08-11", venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Cabaret for the Chronically Dramatic",
                         discipline: "music", venue: "54 Below", performanceDate: "2026-08-11",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func contact(_ name: String, email: String? = nil, formUrl: String? = nil,
                         role: String? = nil, provenance: String = "performer",
                         sourceUrl: String? = nil) -> PrepContact {
        PrepContact(name: name, role: role, email: email,
                    method: email == nil ? "form_or_dm" : "direct_email",
                    confidence: "low", formUrl: formUrl, provenance: provenance, sourceUrl: sourceUrl)
    }

    private func ingest(_ contacts: [PrepContact], key: String, into ctx: ModelContext) {
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: contacts,
                       draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ]), into: ctx)
    }

    private func prospect(_ ctx: ModelContext, _ key: String) throws -> Prospect {
        try #require(try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first)
    }

    // The case Dan is looking at, with the batch that makes the old provenance guard useless: several
    // performers on one show, so every one of them used to fall through to the append branch.
    @Test func aSecondHandleForTheSamePersonUpdatesTheRowRatherThanAddingOne() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        ingest([contact("Devin Marlowe", formUrl: "https://www.instagram.com/example-performer-act/"),
                contact("Juno Faraday", formUrl: "https://www.instagram.com/example-performer-duo/")],
               key: key, into: ctx)
        ingest([contact("Devin Marlowe", email: "devin@devinmarlowe.example"),
                contact("Juno Faraday", email: "junofaradaymusic@example.test")],
               key: key, into: ctx)

        let p = try prospect(ctx, key)
        #expect(p.recipients.count == 2, "the show has two people on it, not four")
        let ryan = try #require(p.recipients.first { $0.name == "Devin Marlowe" })
        #expect(ryan.email == "devin@devinmarlowe.example", "the address is the better way in")
        #expect(ryan.id == "devin@devinmarlowe.example", "and the row is keyed on it")
    }

    // The other order, which is the one that used to end up strictly worse: a performer with a booking
    // page on her own site gains an Instagram, and the two sat on the card as two people.
    @Test func aSocialProfileNeverReplacesAUsableForm() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        ingest([contact("Sabine Orrell-Vance", formUrl: "https://www.sabinemcg.example/booking"),
                contact("Nessa Halloway", formUrl: "https://www.nessahalloway.example/contact")],
               key: key, into: ctx)
        ingest([contact("Sabine Orrell-Vance", formUrl: "https://www.instagram.com/sabineeov/"),
                contact("Nessa Halloway", formUrl: "https://www.instagram.com/nessaehalloway/")],
               key: key, into: ctx)

        let p = try prospect(ctx, key)
        #expect(p.recipients.count == 2)
        let sabine = try #require(p.recipients.first { $0.name == "Sabine Orrell-Vance" })
        #expect(sabine.contactFormURL == "https://www.sabinemcg.example/booking",
                "her own booking page is the route Dan can use; the Instagram is a dead end (#1626)")
    }

    // And an address arriving onto a form-only row still wins, so the rule above is about SOCIAL being
    // worse rather than about refusing to update anything.
    @Test func anAddressStillBeatsAFormItArrivesAfter() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        ingest([contact("Bethany Griffin", formUrl: "https://www.bethanygriffin.example/contact"),
                contact("Marek Solano", formUrl: "https://www.instagram.com/mareksolano/")],
               key: key, into: ctx)
        ingest([contact("Bethany Griffin", email: "gbethany831@example.test"),
                contact("Marek Solano", email: "mareksolano9@example.test")],
               key: key, into: ctx)

        let p = try prospect(ctx, key)
        #expect(p.recipients.count == 2)
        let bethany = try #require(p.recipients.first { $0.name == "Bethany Griffin" })
        #expect(bethany.email == "gbethany831@example.test")
        #expect(bethany.contactFormURL == "https://www.bethanygriffin.example/contact",
                "the form she publishes is still hers; it is simply no longer the best way in")
    }

    // The store's worst pair: the two rows disagreed about what the person even IS, one `act` and one
    // `performer`. Still one person, so provenance is deliberately not part of the match.
    @Test func twoRowsThatDisagreeAboutProvenanceAreStillOnePerson() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        ingest([contact("Ilan Rooke", formUrl: "https://www.instagram.com/bwaysessions/", provenance: "act")],
               key: key, into: ctx)
        ingest([contact("Ilan Rooke", email: "bwaysessions@example.test",
                        role: "Creator & Host, Broadway Sessions", provenance: "performer")],
               key: key, into: ctx)

        let p = try prospect(ctx, key)
        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.role == "Creator & Host, Broadway Sessions")
    }

    // The guard that must not be reintroduced (#408). Two DIFFERENT people, and one of them arriving with
    // no name at all, must never collapse onto one row.
    @Test func twoNamelessContactsNeverMatchEachOther() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        ingest([PrepContact(name: nil, role: nil, email: nil, method: "form_or_dm", confidence: "low",
                            formUrl: "https://one.example/contact", provenance: "performer", sourceUrl: nil)],
               key: key, into: ctx)
        ingest([PrepContact(name: nil, role: nil, email: nil, method: "form_or_dm", confidence: "low",
                            formUrl: "https://two.example/contact", provenance: "performer", sourceUrl: nil)],
               key: key, into: ctx)

        #expect(try prospect(ctx, key).recipients.count == 2)
    }

    // Two people with the SAME name in one batch is the case where the name stops being evidence, and
    // the importer refuses rather than picking one.
    @Test func aBatchCarryingOneNameTwiceIsRefusedRatherThanGuessed() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        ingest([contact("Noa Petrov", formUrl: "https://noapetrov.example/contact")], key: key, into: ctx)
        ingest([contact("Noa Petrov", email: "alex@one.example"),
                contact("Noa Petrov", email: "alex@two.example")], key: key, into: ctx)

        let p = try prospect(ctx, key)
        #expect(p.recipients.count == 3, "two people share a name, so nothing may be merged onto one row")
    }

    // An already-sent recipient's address is locked (#408). A second handle for that person must not
    // rewrite the row an email actually went to.
    @Test func anAlreadySentContactIsNeverRewritten() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)
        ingest([contact("Devin Marlowe", email: "devin@devinmarlowe.example")], key: key, into: ctx)
        let p = try prospect(ctx, key)
        p.recipients.first?.sendState = .sent
        p.recipients.first?.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        try ctx.save()

        ingest([contact("Devin Marlowe", email: "different@example.test")], key: key, into: ctx)

        let sent = try #require(try prospect(ctx, key).recipients.first { $0.sendState == .sent })
        #expect(sent.email == "devin@devinmarlowe.example", "the address it went to is locked")
    }

    // Dan's own contact is not the importer's to rewrite (#388).
    @Test func aManualContactIsNeverMatched() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)
        let p = try prospect(ctx, key)
        let mine = Recipient(id: "dan@typed.example", email: "dan@typed.example", name: "Devin Marlowe",
                             provenance: .manual)
        p.addRecipient(mine)
        try ctx.save()

        ingest([contact("Devin Marlowe", email: "found@example.test")], key: key, into: ctx)

        let after = try prospect(ctx, key)
        #expect(after.recipients.count == 2)
        #expect(after.recipients.contains { $0.provenance == .manual && $0.email == "dan@typed.example" })
    }
}

// The rules themselves, away from the store, so what counts as "the same person" and "the better handle"
// is testable on its own and shared by the importer and the one-time reconcile.
@Suite("Who a contact is, and which way in is better (#2422)")
struct ContactIdentityTests {

    @Test func caseSpacingAndPunctuationDoNotMakeTwoPeople() {
        #expect(ContactIdentity.isSamePerson("Devin Marlowe", "devin marlowe"))
        #expect(ContactIdentity.isSamePerson("Sabine Orrell-Vance", "Sabine Orrell Vance"))
        #expect(ContactIdentity.isSamePerson("Nessa  Halloway ", "Nessa Halloway"))
    }

    // #774/#755's reason, applied to a person: the strip removes everything outside a-z, so an accent
    // would otherwise shred a name into tokens that cannot match the same name typed without it.
    @Test func anAccentDoesNotMakeTwoPeople() {
        #expect(ContactIdentity.isSamePerson("Sinéad O'Connor", "Sinead O'Connor"))
        #expect(ContactIdentity.isSamePerson("José Ramírez", "Jose Ramirez"))
    }

    // Punctuation folds to a SPACE, not to nothing, which is what makes a hyphenated surname match the
    // same name typed with a space. The consequence, stated so it is a decision rather than a surprise:
    // dropping an apostrophe entirely does NOT match, because "oconnor" and "o connor" are different
    // words. Left that way deliberately: the two payload entries this rule compares come from one run
    // and carry the name as the same page printed it, so the case does not arise, and folding harder
    // would start merging names that merely resemble each other.
    @Test func droppingAnApostropheEntirelyIsNotTheSameName() {
        #expect(!ContactIdentity.isSamePerson("Sinéad O'Connor", "Sinead OConnor"))
    }

    @Test func twoDifferentPeopleAreNotOne() {
        #expect(!ContactIdentity.isSamePerson("Juno Faraday", "Bethany Griffin"))
    }

    // Nothing to compare must never match anything, including another nothing.
    @Test func anEmptyOrTinyNameIsNotAnIdentity() {
        #expect(ContactIdentity.personKey(nil) == nil)
        #expect(ContactIdentity.personKey("") == nil)
        #expect(ContactIdentity.personKey("   ") == nil)
        #expect(ContactIdentity.personKey("J") == nil, "one initial is not somebody's identity")
        #expect(!ContactIdentity.isSamePerson(nil, nil))
        #expect(!ContactIdentity.isSamePerson("", ""))
    }

    @Test func aUsableFormIsNeverReplacedByASocialOne() {
        #expect(ContactIdentity.preferredFormURL(existing: "https://her.example/booking",
                                                 incoming: "https://www.instagram.com/her/")
                == "https://her.example/booking")
    }

    @Test func aSocialFormIsReplacedByAUsableOne() {
        #expect(ContactIdentity.preferredFormURL(existing: "https://www.instagram.com/her/",
                                                 incoming: "https://her.example/booking")
                == "https://her.example/booking")
    }

    @Test func nothingIsNotBetterThanSomething() {
        #expect(ContactIdentity.preferredFormURL(existing: "https://her.example/booking", incoming: nil)
                == "https://her.example/booking")
        #expect(ContactIdentity.preferredFormURL(existing: nil, incoming: "https://www.instagram.com/her/")
                == "https://www.instagram.com/her/")
        #expect(ContactIdentity.preferredFormURL(existing: nil, incoming: nil) == nil)
    }

    // Two equally good forms leave the row alone, so a re-run cannot churn it back and forth.
    @Test func twoEquallyGoodFormsKeepTheOneAlreadyThere() {
        #expect(ContactIdentity.preferredFormURL(existing: "https://her.example/booking",
                                                 incoming: "https://her.example/contact")
                == "https://her.example/booking")
    }
}
