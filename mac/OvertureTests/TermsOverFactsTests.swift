import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3, oracle part two on fixtures): each ported term answers the same over live models
// as over the same rows extracted to `RowFacts`. The live store and 4x corpus arm is
// `TermsOverFactsLiveStoreTests`; the per-term behaviour stays in each term's own suite, which also calls
// `TermsOverFacts.findings` on its own fixtures.
//
// The fixture is built so EVERY arm of the three terms is exercised, with a positive control for each
// (L159): a comparison that can never see a difference would pass a fixture where every term answers
// nothing, so the test first asserts each term DID answer something here.
@MainActor
@Suite("Every ported queue term answers the same over facts as over models (#4357)")
struct TermsOverFactsTests {
    private let asOf = "2026-09-20"

    private func context() throws -> ModelContext {
        ModelContext(try TestModelContainer.inMemory([Prospect.self, Recipient.self]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String?, opens: String?,
                     runEnd: String? = nil, missed: Int = 0, listing: String? = nil,
                     scoutTitle: String? = nil, nights: [String]? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: listing, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: nights ?? opens.map { [$0] } ?? [])
        p.missedScoutCount = missed
        p.scoutGroupName = scoutTitle
        ctx.insert(p)
        return p
    }

    // Invented names throughout (L155, L222).
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        // T3: a source-wide break of three flagged rows on one count, one of them with a live twin (T2).
        let hall = "Harrowgate Hall"
        row(ctx, key: "lantern|2026-10-03", title: "Lantern Parade", venue: hall, opens: "2026-10-03", missed: 4)
        row(ctx, key: "ninefold|2026-10-10", title: "Ninefold Quartet", venue: hall, opens: "2026-10-10", missed: 4)
        row(ctx, key: "copper|2026-10-17", title: "Copper Moth Revue", venue: hall, opens: "2026-10-17", missed: 4)
        row(ctx, key: "lantern live|2026-10-02", title: "Lantern Parade", venue: hall, opens: "2026-10-02",
            runEnd: "2026-10-06")
        // T2: a venueless flagged row and a venueless live twin, the `""` room both sides.
        row(ctx, key: "drift|2026-11-01", title: "Driftwood Choir", venue: nil, opens: "2026-11-01", missed: 3)
        row(ctx, key: "drift live|2026-11-01", title: "Driftwood Choir", venue: nil, opens: "2026-11-01")
        // T1: three rows of one show at one room, one renamed on its display title but not its scout one,
        // joined through overlapping nights; one stopped being listed, so the collapse fronts the others.
        row(ctx, key: "saltmarsh a", title: "Saltmarsh Suite", venue: "Quillon Room", opens: "2026-12-04",
            runEnd: "2026-12-06", nights: ["2026-12-04", "2026-12-05", "2026-12-06"])
        row(ctx, key: "saltmarsh b", title: "Saltmarsh Suite, Renamed By Hand", venue: "Quillon Room",
            opens: "2026-12-05", scoutTitle: "Saltmarsh Suite")
        row(ctx, key: "saltmarsh c", title: "Saltmarsh Suite", venue: "Quillon Room", opens: "2026-12-06",
            missed: 1)
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    @Test func eachTermAnswersTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        // Positive controls: every term answered something in this fixture.
        #expect(!ShowLink.group(all.map(ShowLink.Row.init)).isEmpty, "the fixture forms no ShowLink group")
        #expect(!ShowLink.collapse(all.map(ShowLink.Row.init), drawn: ["saltmarsh a", "saltmarsh b"]).hidden.isEmpty,
                "the fixture hides no row in the collapse")
        #expect(ContradictedCancellation.contradictedKeys(among: all).count == 2,
                "the fixture should contradict exactly the twinned hall row and the venueless one")
        #expect(FeedBreakEvent.events(among: all, asOf: asOf).first?.coveredByAnotherCard == 1,
                "the fixture's feed break should count one member covered by another card")

        let findings = TermsOverFacts.findings(all, asOf: asOf, drawn: ["saltmarsh a", "saltmarsh b"])
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }

    // The comparison can see a retained row that went stale: facts taken BEFORE a flagged row came back
    // into the feed disagree with the models after it, in T2, T3 and the collapse.
    @Test func theComparisonSeesARowThatChangedAfterItWasExtracted() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let stale = all.map(RowFacts.extract)
        let flagged = try #require(all.first { $0.naturalKey == "lantern|2026-10-03" })
        flagged.missedScoutCount = 0
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("ContradictedCancellation.contradictedKeys") },
                "a row that stopped being flagged was not seen by the contradiction comparison")
        #expect(findings.contains { $0.hasPrefix("FeedBreakEvent.events") },
                "a row that left a feed break was not seen by the event comparison")
        #expect(findings.contains { $0.hasPrefix("disappearedFromFeed") },
                "the flag itself was not compared")
        #expect(!findings.contains { $0.contains("Lantern") || $0.contains("Harrowgate") },
                "a finding named a title or a venue rather than the row's identifier")
    }
}
