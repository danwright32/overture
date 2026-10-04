import Testing
import Foundation
import SwiftData

// #4339 (A11): runScout's tail judges the shows its landing's working set holds rather than fetching the whole
// table again on the main thread, and still judges every show. The fetch it skips was measured at 216 ms at
// 1,372 shows and 866 at 5,500 (`LandingFirstHoldProbeTests`); what is asserted here is that the rows handed in
// are what is judged, and that a run still retires a blocked town's show end to end.
private struct NoFeed: SourceExtractor {
    func extract() async throws -> ExtractedListing { ExtractedListing(events: [], verdict: .noDatedContent) }
}

@MainActor
@Suite("#4339 runScout's tail judges the landing's rows rather than fetching the table again")
final class RunScoutTailRowsTests {
    private func show(_ ctx: ModelContext, _ key: String, location: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "opera", venue: "A venue",
                         performanceDate: "2026-12-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        ctx.insert(p)
        return p
    }

    @Test func theRetirementJudgesTheRowsItIsHandedAndOnlyThose() throws {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        let handed = show(ctx, "buffalo-a", location: "Buffalo, NY")
        let notHanded = show(ctx, "buffalo-b", location: "Buffalo, NY")
        try ctx.save()

        #expect(ExcludedTownRetirement.run(rows: [handed], in: ctx) == 1)
        #expect(handed.showOutcome == .tooFar)
        #expect(notHanded.status == .new, "a show the caller did not hand in was judged, so the table was fetched")
        // With none handed in, the table is fetched as before.
        #expect(ExcludedTownRetirement.run(in: ctx) == 1)
        #expect(notHanded.showOutcome == .tooFar)
    }

    @Test func aRunStillRetiresABlockedTownsShowThroughItsLandingsRows() async throws {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        let buffalo = show(ctx, "buffalo-opera", location: "Buffalo, NY")
        try ctx.save()
        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: NoFeed(), extractorRegistry: { _ in nil },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "x") },
            pin: { _, id in URL(fileURLWithPath: "/dev/null/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("RunScoutTailRowsTests"), landings: LandingSingleFlight())
        #expect(buffalo.showOutcome == .tooFar, "the run's tail left a blocked town's show in the queue")
    }
}
