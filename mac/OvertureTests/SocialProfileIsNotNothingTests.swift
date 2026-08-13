import Testing
import Foundation
import SwiftData

// #2265: a check that reached a social profile and stopped there is NOT a check that found nothing.
//
// Measured on the 2026-08-07 run, on 2 of its 3 shows. For Ryan James Monroe the run spent nine web
// calls, fetched instagram.com/ryanjamesmonroe/ successfully, and emitted a contact whose only route
// was that profile. A social DM is a dead end by Dan's standing rule, so the ingest refused it and the
// card rendered a plain "No email found", with no reason. Verified the same day: a plain fetch of
// ryanjamesmonroe.com/contact-8-1 publishes ryan@ryanjamesmonroe.com and lindsay@ryanjamesmonroe.com.
//
// So "No email found" with no reason was a claim the run had not earned. `nothingPublished` is the one
// verdict whose wording is documented as always true ("this show's people genuinely publish no address
// anywhere"), and collapsing this case into it makes that documentation false and hides the one state
// where a re-check is most likely to succeed.
//
// The runbook now tells the run to follow the profile's links and to try the canonical domain. This is
// the deterministic half: a rule that lives only in a prompt is a hope (L27), and this one is checkable
// from what the run emitted without trusting a word of what it said it did.
@MainActor
@Suite("A social profile is not nothing published (#2265)")
struct SocialProfileIsNotNothingTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Ryan James Monroe",
                                          performanceDate: "2026-08-11", venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Ryan James Monroe", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-08-11", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func fetch(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    /// The exact contact the 2026-08-07 run emitted for this show.
    private func socialOnlyContact() -> PrepContact {
        PrepContact(name: "Ryan James Monroe", role: "Performer", email: nil,
                    method: "form_or_dm", confidence: "low",
                    formUrl: "https://www.instagram.com/ryanjamesmonroe/", provenance: "performer")
    }

    @Test func aRunThatOnlyReachedASocialProfileSaysSo() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key,
                                                                 contacts: [socialOnlyContact()],
                                                                 draft: nil)]),
                                into: ctx, now: now, isProbe: true)

        let p = try fetch(ctx, key)
        // #2612 turned this from a refusal into a verdict. #2265's point stands and is what the verdict
        // now carries: a run that reached a doorway has NOT established that nothing is published, and
        // this row must never read as the bare "No email found" it did before that issue.
        #expect(p?.reachabilityResult == .socialOnly,
                "a social DM is a route Dan works by hand (#2612), not the absence of one")
        #expect(p?.reachabilityResult != .noEmailFound)
    }

    // The verdict this must NOT be confused with. A run that genuinely came back with nothing keeps the
    // reason it was given, and a run that found a REAL route is untouched, or the new state would spread
    // over cases it is not true of.
    @Test func aRunThatFoundAnAddressIsUnaffected() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let real = PrepContact(name: "Ryan James Monroe", role: "Performer",
                               email: "ryan@ryanjamesmonroe.com", method: "named_decision_maker",
                               confidence: "high", formUrl: nil, provenance: "performer")
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key, contacts: [real],
                                                                 draft: nil)]),
                                into: ctx, now: now, isProbe: true)

        let p = try fetch(ctx, key)
        #expect(p?.reachabilityResult == .emailFound)
        #expect(p?.reachabilityEmptyReason == nil)
    }

    // A form on the target's OWN site is a route Dan uses, and must never be labelled a social dead end.
    @Test func aFormOnTheActsOwnSiteIsNotASocialDeadEnd() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let ownForm = PrepContact(name: "Ryan James Monroe", role: "Performer", email: nil,
                                  method: "form_or_dm", confidence: "medium",
                                  formUrl: "https://www.ryanjamesmonroe.com/contact-8-1",
                                  provenance: "performer")
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key, contacts: [ownForm],
                                                                 draft: nil)]),
                                into: ctx, now: now, isProbe: true)

        #expect(try fetch(ctx, key)?.reachabilityEmptyReason != .onlySocialProfile)
    }
}
