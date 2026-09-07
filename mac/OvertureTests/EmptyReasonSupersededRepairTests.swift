import Testing
import Foundation
import SwiftData

// #3598. A stored `reachabilityEmptyReason` is what a check CONCLUDED when it came home with nobody to
// write to. Nothing updates it afterwards, so a show that has since gained a route keeps a sentence
// saying it has none. Measured on the live store 2026-09-06: 37 rows carry `named_but_no_route` and 31
// of them hold a contact route.
//
// Nothing RENDERS those, because the sentence is drawn only under `ProspectRowView`'s `.noEmailFound`
// arm and that verdict recomputes from the row's own contacts (#3387). Costing nothing on screen is not
// the same as costing nothing: #3345 was filed at p1, and worked from for a week, on a count of exactly
// this column, taken to be a current measurement.
//
// WHAT IS AND IS NOT DESTROYED HERE (L277). The value cleared is the only copy in the STORE, and it is
// deliberately not the only copy anywhere: every check writes its results to
// `check-run-archives/<stamp>/`, which is where #3345's own evidence came from and where
// `DeadRunWriteOffRepair` reads. So the diagnosis this pass removes from the store can still be made
// from the archives, and what goes is a claim about the show that stopped being true.
@MainActor
@Suite("Clear an empty reason its own contacts contradict (#3598)")
struct EmptyReasonSupersededRepairTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ name: String,
                      reason: Reachability.EmptyReason?,
                      email: String? = nil, formURL: String? = nil,
                      sentAt: Date? = nil, booked: Bool = false) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Rowan Hall",
                         performanceDate: "2027-04-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        p.reachabilityEmptyReason = reason
        p.sentAt = sentAt
        if booked { p.outcome = .booked }
        if email != nil || formURL != nil {
            let r = Recipient(id: "r-\(name)", email: email, name: name, role: nil,
                              provenance: .performer, contactMethodRaw: "generic_inbox",
                              contactConfidenceRaw: "medium", contactFormURL: formURL,
                              contactSourceURL: nil)
            p.addRecipient(r)
        }
        try? ctx.save()
        return p
    }

    // The measured population: a reason saying the check found names and no way to reach any of them, on
    // a row that now holds a form.
    @Test func aNoRouteReasonGoesOnceTheRowHoldsARoute() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Named But No Route", reason: .namedButNoRoute,
                     formURL: "https://kestrelquartet.example/contact")
        let report = EmptyReasonSupersededRepair.run(in: ctx)
        #expect(p.reachabilityEmptyReason == nil)
        #expect(report.cleared == 1)
    }

    // The same reason on a row that really does hold nothing is untouched, which is the whole population
    // the sentence exists for. Without this the pass would clear the column rather than the contradiction.
    @Test func aNoRouteReasonStaysWhereTheRowHoldsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Genuinely Unreachable", reason: .namedButNoRoute)
        let report = EmptyReasonSupersededRepair.run(in: ctx)
        #expect(p.reachabilityEmptyReason == .namedButNoRoute)
        #expect(report.cleared == 0)
        // Counted, not silently passed over: a pass that reports 0 cleared out of 0 examined and one that
        // reports 0 out of 400 are the same number and different facts (L98).
        #expect(report.examined == 1)
    }

    // A reason claiming no ADDRESS is not contradicted by a FORM, and this is the half a single
    // "holds any route" predicate would get wrong. `nothingPublished` says this show's people publish no
    // address anywhere; a contact form on their own site is perfectly consistent with that, and clearing
    // it would destroy a truthful record of a finished search.
    @Test func anAddressClaimSurvivesAFormOnlyRoute() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Nothing Published", reason: .nothingPublished,
                     formURL: "https://kestrelquartet.example/contact")
        _ = EmptyReasonSupersededRepair.run(in: ctx)
        #expect(p.reachabilityEmptyReason == .nothingPublished)
    }

    @Test func anAddressClaimGoesOnceTheRowHoldsAnAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Nothing Published Now Reachable", reason: .nothingPublished,
                     email: "booking@kestrelquartet.example")
        _ = EmptyReasonSupersededRepair.run(in: ctx)
        #expect(p.reachabilityEmptyReason == nil)
    }

    // What was true when Dan wrote to them is history, not drift. The same rule the two repairs beside
    // this one follow, and `reachabilityResultAsHeld`'s own.
    @Test func aShowAlreadyWrittenToKeepsWhatItWentOutUnder() throws {
        let ctx = ModelContext(try container())
        let sent = show(ctx, "Already Sent", reason: .namedButNoRoute,
                        formURL: "https://kestrelquartet.example/contact",
                        sentAt: Date(timeIntervalSince1970: 1_756_000_000))
        let booked = show(ctx, "Already Booked", reason: .namedButNoRoute,
                          formURL: "https://kestrelquartet.example/contact", booked: true)
        let report = EmptyReasonSupersededRepair.run(in: ctx)
        #expect(sent.reachabilityEmptyReason == .namedButNoRoute)
        #expect(booked.reachabilityEmptyReason == .namedButNoRoute)
        #expect(report.skippedSentOrBooked == 2)
        #expect(report.cleared == 0)
    }

    // Idempotent, and it has to be: unlike the two one-time repairs beside it this runs on EVERY launch,
    // because the contradiction can be created again after it (a contact added by hand, a verdict
    // upgraded by ContactFormResultMigration), and a repair wired to one launch is blind to everything
    // written after it (L332). It is safe to run every launch precisely because it changes nothing any
    // surface renders: the sentence is drawn only under a verdict this row no longer has.
    @Test func asecondRunClearsNothingFurther() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Named But No Route", reason: .namedButNoRoute,
             formURL: "https://kestrelquartet.example/contact")
        #expect(EmptyReasonSupersededRepair.run(in: ctx).cleared == 1)
        #expect(EmptyReasonSupersededRepair.run(in: ctx).cleared == 0)
    }

    // Every reason in the vocabulary states what would contradict it, so a case added later has to answer
    // the question rather than inherit an answer (L113). This is the guard on that: it fails if a new case
    // is added and the switch is made non-exhaustive by a `default`.
    @Test func everyReasonSaysWhatContradictsIt() {
        // Reasons whose claim is that there is no way in AT ALL: any route contradicts them.
        let anyRoute: [Reachability.EmptyReason] = [.namedButNoRoute, .noOneIdentified,
                                                    .routeNamedButNotSupplied]
        // Reasons whose claim is about an ADDRESS: a form or a handle is consistent with them, so only an
        // address contradicts them.
        let addressOnly: [Reachability.EmptyReason] = [.nothingPublished, .onlyVenueContact,
                                                       .onlyPressContact, .onlySocialProfile,
                                                       .unconfirmedSocialProfile]
        #expect(Set(anyRoute + addressOnly) == Set(Reachability.EmptyReason.allCases),
                "a reason was added to the vocabulary without saying what contradicts it")
        for reason in anyRoute {
            #expect(reason.isContradicted(byAddress: false, byAnyRoute: true))
            #expect(reason.isContradicted(byAddress: true, byAnyRoute: true))
            #expect(!reason.isContradicted(byAddress: false, byAnyRoute: false))
        }
        for reason in addressOnly {
            #expect(!reason.isContradicted(byAddress: false, byAnyRoute: true))
            #expect(reason.isContradicted(byAddress: true, byAnyRoute: true))
        }
    }
}
