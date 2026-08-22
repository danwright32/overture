import Testing
import Foundation
import SwiftData

// #2421 created this rule: a contact whose only handle is a social profile is not a contact. #2612
// REVERSED the half of it about social profiles, and both calls are Dan's.
//
// His words, 2026-08-13, on the Song & Word card: "I changed my mind and I actually do want to know when
// it's instagram only with no contact form. This actually feels like a perfect fit for me but they don't
// have a website so I'm going to DM them on instagram."
//
// What survives from #2421 is the part that was never about Instagram: a contact carrying no route at all
// is still not a contact. The run emits those (two performers named with neither an address nor a form,
// #2259), and creating a row for one gives Dan a person he cannot reach and a count that overstates the
// ways in.
@Suite("A contact with no way in at all is not created (#2421, narrowed by #2612)")
struct DeadEndContactTests {

    // #2612: the reversal, at the predicate. A social profile is a route Dan works by hand.
    @Test func asocialProfileIsARouteAgain() {
        #expect(!DeadEndContact.hasNoUsableRoute(email: nil,
                                                 formURL: "https://www.instagram.com/example-performer-act/"))
        #expect(!DeadEndContact.hasNoUsableRoute(email: "", formURL: "https://www.facebook.com/someone"))
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
                                                 formURL: "https://www.instagram.com/example-performer-act/"))
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
        let key = Prospect.makeNaturalKey(groupName: "Devin Marlowe", performanceDate: "2026-08-11",
                                          venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Devin Marlowe", discipline: "music",
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

    // The exact payload from the card Dan was looking at in #2421, read again under #2612's rule: the
    // three Instagrams are contacts now, because he will DM every one of them.
    @Test func thePreppedCardKeepsEveryContactCarryingARoute() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                contact("Devin Marlowe", email: "devin@devinmarlowe.example"),
                contact("Eliah B. Johnson", formUrl: "https://www.eliahbjohnson.example/contact"),
                contact("Zachary McIntyre", formUrl: "https://zachmcintyrehorn.example/?page_id=18"),
                contact("Sunny Sheu", formUrl: "https://www.instagram.com/sunny.sheu/"),
                contact("Mark Klett", formUrl: "https://www.instagram.com/markklett/"),
                contact("Sarah Overton", formUrl: "https://www.instagram.com/celloverton/"),
            ], draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ]), into: ctx)

        let p = try #require(try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first)
        #expect(p.recipients.count == 6, "one address, two forms and three Instagrams, all routes")
        #expect(Set(p.recipients.compactMap(\.name))
                == ["Devin Marlowe", "Eliah B. Johnson", "Zachary McIntyre",
                    "Sunny Sheu", "Mark Klett", "Sarah Overton"])
    }

    // A later run that reports a contact with no route at all must not create it either, which is why the
    // rule sits above every branch rather than only on the append one.
    @Test func areRunDoesNotCreateARoutelessContact() throws {
        let ctx = ModelContext(try container())
        let key = show(ctx)
        let payload = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [contact("Isabella Borte")],
                       draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ])

        _ = PrepImporter.ingest(payload, into: ctx)
        _ = PrepImporter.ingest(payload, into: ctx)

        let p = try #require(try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first)
        #expect(p.recipients.isEmpty)
    }
}

// #2612 DELETED `DeadEndContactSweep` and the two suites that lived here. It hard-deleted every stored
// contact whose only route was a social profile, which is now the exact opposite of what the ingest
// keeps: left in place it would undo this issue's fix on every launch. L116 is the rule it broke, and it
// is worth stating where the code used to be, because the cost was real: 45 contacts across 33 shows were
// deleted on 2026-08-10 and the handles are gone from the store, so only a fresh check can recover them.
