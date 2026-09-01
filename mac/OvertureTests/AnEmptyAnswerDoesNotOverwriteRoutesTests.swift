import Testing
import Foundation
import SwiftData

// #3388. `PrepImporter`'s "the run answered and had nothing to give" branch wrote
// `reachabilityEmptyReason` without first asking whether the row already holds routes. So a row with
// stored addresses could be stamped with a sentence saying it has none.
//
// That sentence is the one on the card explaining why Dan cannot write to somebody, so on such a row it
// asserts the exact opposite of what the row holds, and it overwrites the evidence of an earlier run
// that DID find routes (L5: never destroy good state).
//
// LIVE-STORE-CLAIM verified=2026-08-31 measure="prospects carrying a reachabilityEmptyReason while holding addresses no research guard is holding, and whether a send stage fact explains it"
// Measured 2026-08-31 against a WAL inclusive copy: prospect Z_PK 1002 carries `named_but_no_route`
// beside 4 unguarded addresses that are all still pending, with no calendar conflict and no missing
// subject, so #3387's cause does not account for it. It is the only row in that exact state.
//
// The rule: EVERY EmptyReason is a claim that no route was found. `Reachability.EmptyReason` has no case
// meaning anything else (checked against all of them), so on a row that holds a route every one of them
// is false, and the honest write is none at all.
@MainActor
@Suite("An empty answer does not overwrite a row that holds routes (#3388)")
struct AnEmptyAnswerDoesNotOverwriteRoutesTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func showHoldingAnAddress(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        let r = Recipient(id: "a", email: "booking@kestrelquartet.example", name: "Kestrel Quartet",
                          role: nil, provenance: .performer, contactMethodRaw: "generic_inbox",
                          contactConfidenceRaw: "medium", contactFormURL: nil, contactSourceURL: nil)
        p.addRecipient(r)
        try? ctx.save()
        return key
    }

    private func fetch(_ ctx: ModelContext, _ key: String) throws -> Prospect {
        try #require(try ctx.fetch(FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.naturalKey == key })).first)
    }

    // The defect exactly, in the shape the live store holds it.
    @Test func aBarrenReCheckLeavesNoReasonOnARowHoldingAnAddress() throws {
        let ctx = ModelContext(try container())
        let key = showHoldingAnAddress(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, emptyReason: "named_but_no_route"),
        ]), into: ctx, isProbe: true)

        let p = try fetch(ctx, key)
        #expect(p.hasAnyRoute, "the address is still there")
        #expect(p.reachabilityEmptyReason == nil,
                "every EmptyReason claims no route was found, which is false of a row holding one")
    }

    // A stale reason left by an earlier run is CLEARED rather than left standing, for the same reason it
    // is not written: it is a false claim about the row as it now stands. Its own test, because leaving
    // an existing one alone and refusing to write a new one are different behaviours and only one of
    // them fixes the row the live store actually holds.
    @Test func aStaleReasonIsClearedFromARowThatHoldsRoutes() throws {
        let ctx = ModelContext(try container())
        let key = showHoldingAnAddress(ctx)
        let before = try fetch(ctx, key)
        before.reachabilityEmptyReason = .nothingPublished
        try? ctx.save()

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, emptyReason: "named_but_no_route"),
        ]), into: ctx, isProbe: true)

        #expect(try fetch(ctx, key).reachabilityEmptyReason == nil)
    }

    // A form on the act's own site is a route too, so the same refusal applies. Its own case because
    // `hasAnyRoute` is derived from a five arm cascade and an address-only reading of it would pass the
    // test above while still stamping a false sentence on every form-only and social-only show.
    @Test func aFormOnlyRowIsAlsoARowThatHoldsARoute() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        let r = Recipient(id: "a", email: nil, name: "Kestrel Quartet", role: nil,
                          provenance: .performer, contactMethodRaw: "contact_form",
                          contactConfidenceRaw: "medium",
                          contactFormURL: "https://kestrelquartet.example/contact", contactSourceURL: nil)
        p.addRecipient(r)
        try? ctx.save()

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, emptyReason: "nothing_published"),
        ]), into: ctx, isProbe: true)

        let after = try fetch(ctx, key)
        #expect(after.reachabilityResultFromRecipients == .contactFormOnly)
        #expect(after.reachabilityEmptyReason == nil)
    }

    // The branch must keep WORKING for the rows it was written for (#1722): a row holding nothing at all
    // still gets the run's reason, or this fix would silence the honest failure machinery entirely.
    @Test func aRowHoldingNothingStillRecordsTheRunsReason() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, emptyReason: "only_venue_contact"),
        ]), into: ctx, isProbe: true)

        let after = try fetch(ctx, key)
        #expect(!after.hasAnyRoute)
        #expect(after.reachabilityEmptyReason == .onlyVenueContact)
    }

    // The premise the refusal rests on, asserted rather than assumed: there is no EmptyReason case that
    // means anything other than "no route was found", so refusing to write ANY of them on a routed row
    // is right for the whole vocabulary and not only for the cases that exist today. If a future case
    // means something else, this goes red and the refusal has to be reconsidered rather than inherited.
    @Test func everyEmptyReasonIsAClaimThatNoRouteWasFound() {
        for reason in Reachability.EmptyReason.allCases {
            #expect(ReachabilityCopy.emptyAnswerBadge(reason) != ReachabilityCopy.emailFoundBadge,
                    "\(reason.rawValue) would have to be reconsidered: it does not read as an absence")
        }
    }
}
