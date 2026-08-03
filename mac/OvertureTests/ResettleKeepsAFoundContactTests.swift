import Testing
import Foundation
import SwiftData

// #1623: settling a finished check TWICE must not turn a found address into "No email found".
//
// The settle writes a pre-guard floor (`reachabilityResult = .noEmailFound`) before the ingest, because at
// that moment it cannot tell a sendable address from a front desk; the ingest that follows upgrades it
// (#1596 Phase 3). On a RE-settle the ingest does not follow: `consumeIfNew` refuses a results file it has
// already read, so the floor is the only thing that runs and nothing ever upgrades it. A show that found
// jane@example.org last night comes back reading "No email found" with that address still printed
// underneath it, and the verdict is trusted for 90 days, so it is also locked out of a re-check.
//
// The fix is the seam the issue named: the floor is written by a writer that KNOWS whether an upgrade is
// still coming, which is the same decision `consumeIfNew` already makes.
//
// Two obvious fixes are wrong and both are pinned below. Writing the floor only when the result is nil
// would leave a stale positive standing after a genuine re-check that found nothing, which is exactly what
// the unconditional write exists to prevent. And skipping the whole stamp on a re-settle would leave a row
// whose first settle failed to save unstamped forever, offering to pay again for a lookup that happened.
@MainActor
@Suite("A re-settle never turns a found contact into no contact (#1623)")
struct ResettleKeepsAFoundContactTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, group: String = "Aurora Strings") -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12",
                                          venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    private func foundResults(_ key: String) -> PrepResults {
        PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: "Jane Doe", role: "Artistic Director",
                                              email: "jane@aurora.example",
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: "act",
                                              sourceUrl: "https://aurora.example/about")],
                       draft: nil)
        ])
    }

    private func row(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    // THE BUG. Settle the same finished run twice, which is what a relaunch after ingest does, and the
    // found answer has to survive it.
    @Test func settlingTheSameFinishedCheckTwiceKeepsTheAnswerItFound() throws {
        let ctx = ModelContext(try container())
        let key = prospect(ctx)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let defaults = freshDefaults()
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        try writeResults(resultsURL, foundResults(key))

        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                 into: ctx, now: first, defaults: defaults)
        #expect(try row(ctx, key)?.reachabilityResult == .emailFound)

        // The same run settled again: the marker is rewritten (a relaunch finds it), the results file is
        // byte-identical, so the ingest refuses it as already consumed.
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL, into: ctx,
                                                 now: first.addingTimeInterval(3600), defaults: defaults)

        #expect(try row(ctx, key)?.reachabilityResult == .emailFound)
        #expect(try row(ctx, key)?.recipients.first?.email == "jane@aurora.example")
    }

    // And it does not quietly extend the 90-day freshness window either. Re-reading a file changes nothing
    // about WHEN the show was actually researched, and a later stamp would push a stale answer's re-check
    // further away every time the app relaunched.
    @Test func aResettleDoesNotMakeAnOldAnswerLookNewer() throws {
        let ctx = ModelContext(try container())
        let key = prospect(ctx)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let defaults = freshDefaults()
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        try writeResults(resultsURL, foundResults(key))

        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                 into: ctx, now: first, defaults: defaults)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL, into: ctx,
                                                 now: first.addingTimeInterval(86_400), defaults: defaults)

        #expect(try row(ctx, key)?.reachabilityProbedAt == first)
    }

    // FAILURE DIRECTION 1, the reason the floor is written unconditionally in the first place: a genuine
    // NEW check that finds nothing must overwrite a positive from an earlier one. A stale "Email found"
    // left standing would send Dan to an address the check just failed to confirm.
    @Test func aFreshCheckThatFindsNothingStillClearsAnEarlierPositive() throws {
        let ctx = ModelContext(try container())
        let key = prospect(ctx)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let defaults = freshDefaults()
        let first = Date(timeIntervalSince1970: 1_780_000_000)

        try writeResults(resultsURL, foundResults(key))
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                 into: ctx, now: first, defaults: defaults)
        #expect(try row(ctx, key)?.reachabilityResult == .emailFound)

        // A DIFFERENT run: its own results file, so its own fingerprint, and it answered this show with
        // nobody. This one is not a re-settle at all and the floor must land.
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "a later run", results: [
            PrepResult(naturalKey: key, contacts: nil, draft: nil, emptyReason: "nothing_published")
        ]))
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s2"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL, into: ctx,
                                                 now: first.addingTimeInterval(86_400), defaults: defaults)

        #expect(try row(ctx, key)?.reachabilityResult == .noEmailFound)
        #expect(try row(ctx, key)?.reachabilityProbedAt == first.addingTimeInterval(86_400))
    }

    // FAILURE DIRECTION 2: a row the first settle never managed to stamp is still rescued by the second.
    // Skipping the stamp outright on a re-settle would leave that show reading "never checked" forever,
    // so Dan would be offered it again and pay a second time for a lookup that already happened.
    @Test func aResettleStillRescuesAShowTheFirstSettleNeverStamped() throws {
        let ctx = ModelContext(try container())
        let key = prospect(ctx)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        // The results file was consumed (the ingest ran and recorded it) while this row was left unstamped,
        // which is what a save failure between the two writes leaves behind.
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, draft: nil, emptyReason: "nothing_published")
        ]))
        PrepImporter.consumeIfNew(at: resultsURL, into: ctx, defaults: defaults)
        #expect(try row(ctx, key)?.reachabilityProbedAt == nil)

        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                 into: ctx, now: now, defaults: defaults)

        #expect(try row(ctx, key)?.reachabilityProbedAt == now)
        #expect(try row(ctx, key)?.reachabilityResult == .noEmailFound)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "resettle-\(UUID().uuidString)")!
    }
}
