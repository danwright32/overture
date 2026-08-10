import Testing
import Foundation
import SwiftData

// #2421, Dan on the live build 2026-08-10 looking at a prepped card carrying seven contacts and one
// address: "I removed all but one email and it's still showing me the 7 or so that it found." The run had
// researched, drafted to, counted and listed six people it has no way to reach.
//
// Four of the six were Instagram only, which the app had ALREADY ruled out: #1626 refuses to offer an
// Instagram as a link on the card, in those words, because it is "a dead end Dan will not use". The same
// rule one step earlier is this. Dan's call, 2026-08-10, shown the measured split: drop the social-only
// ones (45 on his store), keep the real forms (21, and the only route into 15 shows).
@Suite("A contact with no way in is not created (#2421)")
struct DeadEndContactTests {

    @Test func aSocialProfileAloneIsNoWayIn() {
        #expect(DeadEndContact.hasNoUsableRoute(email: nil,
                                                formURL: "https://www.instagram.com/ryanjamesmonroe/"))
        #expect(DeadEndContact.hasNoUsableRoute(email: "", formURL: "https://www.facebook.com/someone"))
    }

    // The 21 that are kept, and the reason they are: the review panel has a working path for these
    // (copy the draft, open their form, mark it sent), and 15 shows have no other route at all.
    @Test func aFormOnTheActsOwnSiteIsARealWayIn() {
        #expect(!DeadEndContact.hasNoUsableRoute(email: nil,
                                                 formURL: "https://www.eliahbjohnson.example/contact"))
        #expect(!DeadEndContact.hasNoUsableRoute(email: nil,
                                                 formURL: "https://zachmcintyrehorn.example/?page_id=18"))
    }

    // An address is a way in whatever else the contact carries, so somebody's Instagram never costs them
    // their row.
    @Test func anAddressIsAlwaysAWayIn() {
        #expect(!DeadEndContact.hasNoUsableRoute(email: "ryan@example.test",
                                                 formURL: "https://www.instagram.com/ryanjamesmonroe/"))
    }

    // Nothing at all is the clearest dead end of the lot.
    @Test func nothingAtAllIsADeadEnd() {
        #expect(DeadEndContact.hasNoUsableRoute(email: nil, formURL: nil))
        #expect(DeadEndContact.hasNoUsableRoute(email: "  ", formURL: "  "))
    }
}

@MainActor
@Suite("The importer never creates a dead-end contact (#2421)")
struct DeadEndContactIngestTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Ryan James Monroe", performanceDate: "2026-08-11",
                                          venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Ryan James Monroe", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-08-11", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func contact(_ name: String, email: String? = nil, formUrl: String? = nil) -> PrepContact {
        PrepContact(name: name, role: nil, email: email,
                    method: email == nil ? "form_or_dm" : "direct_email", confidence: "low",
                    formUrl: formUrl, provenance: "performer", sourceUrl: nil)
    }

    // The exact payload from the card Dan was looking at.
    @Test func thePreppedCardKeepsOnlyTheContactsHeCanActOn() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                contact("Ryan James Monroe", email: "ryan@ryanjamesmonroe.example"),
                contact("Eliah B. Johnson", formUrl: "https://www.eliahbjohnson.example/contact"),
                contact("Zachary McIntyre", formUrl: "https://zachmcintyrehorn.example/?page_id=18"),
                contact("Sunny Sheu", formUrl: "https://www.instagram.com/sunny.sheu/"),
                contact("Mark Klett", formUrl: "https://www.instagram.com/markklett/"),
                contact("Sarah Overton", formUrl: "https://www.instagram.com/celloverton/"),
            ], draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ]), into: ctx)

        let p = try #require(try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first)
        #expect(p.recipients.count == 3, "one address and two real forms; the three Instagrams are not contacts")
        #expect(Set(p.recipients.compactMap(\.name))
                == ["Ryan James Monroe", "Eliah B. Johnson", "Zachary McIntyre"])
    }

    // A later run that reports the same dead end must not create it either, which is why the rule sits
    // above every branch rather than only on the append one.
    @Test func aReRunDoesNotBringItBack() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)
        let payload = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [contact("Mark Klett", formUrl: "https://www.instagram.com/markklett/")],
                       draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ])

        _ = PrepImporter.ingest(payload, into: ctx)
        _ = PrepImporter.ingest(payload, into: ctx)

        let p = try #require(try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first)
        #expect(p.recipients.isEmpty)
    }
}

@MainActor
@Suite("Sweeping the dead ends already in the store (#2421)")
struct DeadEndContactSweepTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Ryan James Monroe", performanceDate: "2026-08-11",
                                          venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Ryan James Monroe", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-08-11", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @discardableResult
    private func add(_ p: Prospect, name: String, email: String? = nil, formURL: String? = nil,
                     provenance: RecipientProvenance = .performer) -> Recipient {
        let r = Recipient(id: Recipient.makeId(email: email, formURL: formURL) ?? name, email: email,
                          name: name, provenance: provenance, contactFormURL: formURL)
        p.addRecipient(r)
        return r
    }

    @Test func theSocialOnlyRowsGoAndTheRestStay() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Ryan James Monroe", email: "ryan@ryanjamesmonroe.example")
        add(p, name: "Eliah B. Johnson", formURL: "https://www.eliahbjohnson.example/contact")
        add(p, name: "Sunny Sheu", formURL: "https://www.instagram.com/sunny.sheu/")
        add(p, name: "Mark Klett", formURL: "https://www.instagram.com/markklett/")
        try ctx.save()

        #expect(DeadEndContactSweep.sweep(p, in: ctx) == 2)
        #expect(Set(p.recipients.compactMap(\.name)) == ["Ryan James Monroe", "Eliah B. Johnson"])
    }

    // The refusal that makes the pass safe. Measured before shipping: 0 of the 45 on the live store
    // carried any record of outreach, so this costs nothing today and is what protects the day one does.
    @Test func aDeadEndSomebodyWasActuallyPitchedThroughIsKept() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let pitched = add(p, name: "Sunny Sheu", formURL: "https://www.instagram.com/sunny.sheu/")
        pitched.formOutreachRecordedAt = Date(timeIntervalSince1970: 1_780_000_000)
        pitched.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        pitched.sendState = .sent
        try ctx.save()

        #expect(!DeadEndContactSweep.isRemovable(pitched))
        #expect(DeadEndContactSweep.sweep(p, in: ctx) == 0)
        #expect(p.recipients.count == 1)
    }

    // Dan's own contact is not this pass's to delete (#388), whatever handle he typed.
    @Test func aManualDeadEndIsKept() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let mine = add(p, name: "Mark Klett", formURL: "https://www.instagram.com/markklett/",
                       provenance: .manual)
        try ctx.save()

        #expect(!DeadEndContactSweep.isRemovable(mine))
        #expect(DeadEndContactSweep.sweep(p, in: ctx) == 0)
    }

    @Test func itIsIdempotent() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Sunny Sheu", formURL: "https://www.instagram.com/sunny.sheu/")
        try ctx.save()

        #expect(DeadEndContactSweep.run(in: ctx) == 1)
        #expect(DeadEndContactSweep.run(in: ctx) == 0)
    }
}

// The sweep has to run at launch, and in the right order relative to the duplicate merge, or it would
// delete a row the merge needed to read.
@Suite("The dead-end sweep runs at launch, after the merge (#2421)")
struct DeadEndContactSweepWiringTests {
    private var source: String { SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift") }

    @Test func launchRunsIt() {
        #expect(!source.isEmpty)
        #expect(source.contains("DeadEndContactSweep.run(in: context)"))
    }

    // A person found through both an Instagram and an address is ONE contact first (#2422), so the merge
    // keeps the address and this pass then has nothing of theirs to remove. The other way round, the
    // Instagram row would be deleted before the merge could carry across what only that row knew.
    @Test func itRunsAfterTheDuplicateMerge() throws {
        let merge = try #require(source.range(of: "DuplicateContactMerge.run(in: context)"))
        let sweep = try #require(source.range(of: "DeadEndContactSweep.run(in: context)"))
        #expect(merge.lowerBound < sweep.lowerBound)
    }
}
