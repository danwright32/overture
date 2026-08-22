import Testing
import Foundation
import SwiftData

// #1961, Dan walking the live Release build on 2026-08-01: "it says 2 contacts and then it says no
// email found and it has a link to a contact form. that's confusing".
//
// The card for Battle of the Siblings (The Green Room 42, Aug 6) said three things at once that could
// not all be true: a "2 contacts" pill, a rust "No email found" badge, and a green link to
// tobiaslund.example. Two independent defects, one card.
//
// This suite covers the first: the badge was written by the 2026-07-29 reachability PROBE, and the two
// performers arrived days later from an ordinary Prep run. Only the probe path ever wrote
// `reachabilityResult` (PrepImporter's two writers both sat inside `if isProbe`), so a Prep run that
// landed contacts left the older verdict standing over them.
@MainActor
@Suite("A Prep run that lands contacts corrects the standing verdict (#1961)")
struct PrepIngestReachabilityTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let probedAt = Date(timeIntervalSince1970: 1_785_000_000)

    // The live row, verbatim: probed on Jul 29, stamped "nothing published", still un-drafted.
    @discardableResult
    private func battleOfTheSiblings(_ ctx: ModelContext, checked: Bool = true) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Battle of the Siblings",
                                          performanceDate: "2026-08-06", venue: "The Green Room 42")
        let p = Prospect(naturalKey: key, groupName: "Battle of the Siblings", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-08-06", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        if checked {
            p.reachabilityProbedAt = probedAt
            p.reachabilityResult = .noEmailFound
            p.reachabilityEmptyReason = .nothingPublished
        }
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    // The two performers the Prep run found: no address between them, one Instagram (a dead end Dan
    // will not use) and one form on the performer's own site (one he will).
    private func theTwoPerformers() -> [PrepContact] {
        [PrepContact(name: "Sarah Matsushima", role: "Performer", email: nil, method: "form_or_dm",
                     confidence: "medium", formUrl: "https://instagram.com/delia.marchetti",
                     provenance: "performer"),
         PrepContact(name: "Tobias Lund", role: "Performer", email: nil, method: "form_or_dm",
                     confidence: "medium", formUrl: "https://tobiaslund.example/appointments",
                     provenance: "performer")]
    }

    private func fetch(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    // The defect itself. An ordinary (non-probe) Prep run lands the two performers, and the card must
    // stop saying nothing was found while linking a form it found.
    @Test func contactsLandedByANormalPrepRunReDeriveTheVerdict() throws {
        let ctx = ModelContext(try container())
        let key = battleOfTheSiblings(ctx)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: theTwoPerformers(),
                       draft: PrepDraft(subject: "s", body: "b", variant: "A"))
        ])
        _ = PrepImporter.ingest(results, into: ctx, now: Date())

        let p = try fetch(ctx, key)
        #expect(p?.reachabilityResult == .contactFormOnly)
        // #1722: the earlier refusal sentence is false the moment a contact lands, so it goes with the
        // verdict rather than being printed over a live form.
        #expect(p?.reachabilityEmptyReason == nil)
        // The paid check's own date is untouched: a Prep run is not a reachability check.
        #expect(p?.reachabilityProbedAt == probedAt)
    }

    // The honesty limit (L11). A show no check has ever looked at must not come out of a Prep run
    // wearing a verdict, because every badge sentence says "A reachability check found...".
    @Test func aPrepRunNeverMintsAVerdictNoCheckReached() throws {
        let ctx = ModelContext(try container())
        let key = battleOfTheSiblings(ctx, checked: false)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: theTwoPerformers(), draft: nil)
        ])
        _ = PrepImporter.ingest(results, into: ctx, now: Date())

        let p = try fetch(ctx, key)
        #expect(p?.reachabilityResult == nil)
        #expect(p?.reachabilityProbedAt == nil)
        // #2612: BOTH land again. Sarah Matsushima's only handle is an Instagram, which #2421 made a
        // non-contact and Dan reversed on 2026-08-13 ("I'm going to DM them on instagram"), so what this
        // asserts is unchanged in point: a run that mints no verdict still stores every contact it found
        // a route to.
        #expect(p?.recipients.count == 2)
        #expect(Set(p?.recipients.compactMap(\.name) ?? []) == ["Sarah Matsushima", "Tobias Lund"])
    }

    // The failure path: the run answered this show with nothing. There is no new evidence, so the
    // standing verdict and its reason both survive untouched rather than being blanked by a run that
    // found nothing.
    @Test func aPrepRunThatLandsNoContactsLeavesTheVerdictAlone() throws {
        let ctx = ModelContext(try container())
        let key = battleOfTheSiblings(ctx)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, draft: PrepDraft(subject: "s", body: "b", variant: "A"))
        ])
        _ = PrepImporter.ingest(results, into: ctx, now: Date())

        let p = try fetch(ctx, key)
        #expect(p?.reachabilityResult == .noEmailFound)
        #expect(p?.reachabilityEmptyReason == .nothingPublished)
    }

    // Dan curated this row's recipients by hand, so ingest refuses the run's contacts entirely
    // (#1596 Phase 3). Nothing changed on the row, so nothing may change about its verdict either.
    @Test func aRowDanCuratedKeepsBothItsRecipientsAndItsVerdict() throws {
        let ctx = ModelContext(try container())
        let key = battleOfTheSiblings(ctx)
        let p = try fetch(ctx, key)
        p?.recipientsEditedByDan = true

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: theTwoPerformers(), draft: nil)
        ])
        let outcome = PrepImporter.ingest(results, into: ctx, now: Date())

        #expect(outcome.skippedRecipientEdits == 1)
        #expect(p?.recipients.isEmpty == true)
        #expect(p?.reachabilityResult == .noEmailFound)
    }
}

// #1961's second defect: the pill counted contact RECORDS. Both of Battle of the Siblings' performers
// have no address at all, and one of the two publishes only an Instagram, which is a route the product
// itself refuses to use. So "2 contacts" promised two ways in on a card that had one.
//
// Dan's choice, 2026-08-02, shown the three renderings: say both numbers, so nothing found is dropped
// and nothing unreachable is counted as a way in.
@MainActor
@Suite("The contact pill counts what it promises (#1961)")
struct ContactCountPromiseTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k-battle", groupName: "Battle of the Siblings", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-08-06", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func performer(_ name: String, email: String? = nil, form: String? = nil) -> Recipient {
        let r = Recipient(id: email ?? form ?? name, email: email, name: name, provenance: .performer)
        r.contactFormURL = form
        r.contactMethodRaw = email == nil ? "form_or_dm" : "named_decision_maker"
        return r
    }

    // The live row: two performers, one reachable. #2612 changed WHICH route is unusable: a social
    // profile is a way in now, so the contact with no way in here is one holding the ROOM's own booking
    // page, which #1629 has always refused and which this issue deliberately did not re-open.
    @Test func aFoundContactWithNoUsableRouteIsCountedAsFoundNotAsReachable() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", form: "https://www.thegreenroom42.com/contact"),
                         performer("Tobias Lund", form: "https://tobiaslund.example/appointments")])

        let item = QueueItem(p)
        #expect(item.contactCountLabel == "2 found, 1 reachable")
        // L16: the number and the rows it promises come from one predicate, so the card offers exactly
        // as many ways in as the pill claims.
        #expect(item.displayedContactForms.count == 1)
    }

    // Neither performer publishes anything Dan can use. The pill says so rather than counting two.
    @Test func noneReachableSaysNoneRatherThanZero() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", form: "https://www.thegreenroom42.com/contact"),
                         performer("Ana Ruiz", form: "https://www.thegreenroom42.com/book")])

        #expect(QueueItem(p).contactCountLabel == "2 found, none reachable")
    }

    // The common healthy case is untouched (#596): every contact found is one he can write to, so the
    // pill stays the short form rather than restating the same number twice.
    @Test func everyContactReachableStillReadsAsTheShortCount() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", email: "sarah@example.com"),
                         performer("Tobias Lund", email: "tobias@example.com")])

        #expect(QueueItem(p).contactCountLabel == "2 contacts")
    }

    // #2421 REVERSES what this used to assert, which was that a form is hidden, and therefore not
    // counted, whenever any address is printed on the show (#1626/#1961). That was right while a
    // form-only contact was a leftover to be tolerated. It is wrong now that a real form is a route Dan
    // deliberately keeps (his call, 2026-08-10, measured: 15 shows have no other way in), because on a
    // MIXED show it left those people reading "No email yet" with no way to act, which is the state he
    // was looking at when he filed this. A decision is only true as of its date (L61).
    //
    // What is unchanged, and is the part with teeth: a form counts only where the card would offer it,
    // so the number can still never promise a way in the card does not show.
    @Test func aFormBesideAnAddressIsOfferedAndCounted() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", email: "sarah@example.com"),
                         performer("Tobias Lund", form: "https://tobiaslund.example/appointments")])

        let item = QueueItem(p)
        #expect(item.displayedContactForms.map(\.absoluteString) == ["https://tobiaslund.example/appointments"])
        #expect(item.contactCountLabel == "2 contacts", "two people, two ways in")
    }

    // The contact who HAS an address is never also offered a form: her address is the way in, and a form
    // beside it would be a second control for the same person.
    @Test func aContactWithAnAddressIsNotAlsoOfferedAForm() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", email: "sarah@example.com",
                                   form: "https://sarahmatsushima.example/contact")])

        #expect(QueueItem(p).displayedContactForms.isEmpty)
    }

    // #2612 reversed this one. A social profile IS a way in (Dan DMs it by hand), so the contact holding
    // one is reachable and the card offers the link. The promise itself is unchanged: the number and the
    // rows it promises still come from one predicate.
    @Test func asocialFormIsAWayInNow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", email: "sarah@example.com"),
                         performer("Tobias Lund", form: "https://instagram.com/example-performer-solo")])

        let item = QueueItem(p)
        #expect(item.displayedContactForms.map(\.absoluteString) == ["https://instagram.com/example-performer-solo"])
        #expect(item.contactCountLabel == "2 contacts")
    }

    // Unchanged: one contact never earns a pill at all, reachable or not.
    @Test func oneContactStillEarnsNoPill() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([performer("Sarah Matsushima", form: "https://instagram.com/delia.marchetti")])

        #expect(QueueItem(p).contactCountLabel == nil)
    }
}
