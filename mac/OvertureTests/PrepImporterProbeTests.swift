import Testing
import Foundation
import SwiftData

// #1308 Layer 2 Phase 1: a reachability probe reuses the prep runner to research contacts ONLY. The
// safety of this does NOT rest on the model behaving; it rests on a CODE gate here: when the results
// come from a probe run, ingest must NEVER apply a draft (even if the run emitted one), and must mark the
// show probed whether or not an email was found (so the badge always resolves off the heuristic). These
// pin the two critical failures the #1308 red-team found.
@MainActor
@Suite("Prep results import: reachability probe (#1308)")
struct PrepImporterProbeTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A Review-stage candidate: kept nothing yet, no draft.
    private func newProspect(_ ctx: ModelContext, group: String = "Aurora Strings",
                             date: String = "2026-09-12", venue: String = "Weill Recital Hall") -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    // The critical one: a probe result that (wrongly) also carries a draft must NOT stamp that draft on a
    // Review-stage show Dan never kept, and must not flip it to .drafted. It DOES store the found contact
    // and mark the show probed.
    @Test func aProbeNeverAppliesADraftEvenIfTheRunEmitsOne() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: "Jane Doe", role: "Manager", email: "jane@aurora.org",
                                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                                              provenance: "act")],
                       draft: PrepDraft(subject: "Should never land", body: "Hi Jane,\n...", variant: "A"))
        ])

        _ = PrepImporter.ingest(results, into: ctx, now: now, isProbe: true)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.draftBody == nil)               // the code gate dropped the draft
        #expect(p?.hasDraft == false)
        #expect(p?.status == .new)                 // never flipped to .drafted
        #expect(p?.recipients.first?.email == "jane@aurora.org")  // the found contact IS stored
        #expect(p?.reachabilityProbedAt == now)    // marked probed
    }

    // The stuck-badge failure: a probe that finds NO email must still mark the show probed, so the badge
    // can say "no email found" firmly instead of falling back to the heuristic forever.
    @Test func aProbeThatFindsNoEmailStillMarksTheShowProbed() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, draft: nil)
        ])

        _ = PrepImporter.ingest(results, into: ctx, now: now, isProbe: true)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.reachabilityProbedAt == now)    // probed, even with nothing found
        #expect(p?.recipients.isEmpty == true)
        #expect(p?.status == .new)
    }

    // A normal (non-probe) run is unchanged: it still drafts and marks .drafted.
    @Test func aNonProbeRunStillDraftsAsBefore() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil,
                       draft: PrepDraft(subject: "s", body: "b", variant: "A"))
        ])
        // isProbe defaults false.
        _ = PrepImporter.ingest(results, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.hasDraft == true)
        #expect(p?.status == .drafted)
        #expect(p?.reachabilityProbedAt == nil)    // a normal run never stamps the probe timestamp
    }
}
