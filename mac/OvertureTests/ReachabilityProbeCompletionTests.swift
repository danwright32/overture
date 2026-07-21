import Testing
import Foundation
import SwiftData
@testable import Overture

// #1308 Layer 2 Phase 3 core: settling a finished run. Because a probe and a real Prep share the single
// runner and results file, the completion path uses the probe-run marker to tell them apart: marker present
// => it was a probe, so mark every probed show, ingest the results probe-safely (never a draft), and clear
// the marker; marker absent => a normal prep the caller ingests as before. A probe that produced NO results
// still marks its shows probed, so the badge resolves instead of sticking.
@MainActor
@Suite("Reachability probe completion (#1308)")
struct ReachabilityProbeCompletionTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    @Test func settlesAProbeMarksShowsIngestsContactsAndClearsMarker() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [PrepContact(name: "Jane", role: "Mgr", email: "jane@aurora.org",
                                                             method: "named_decision_maker", confidence: "high",
                                                             formUrl: nil, provenance: "act")], draft: nil)
        ]))

        let wasProbe = PrepQueueService.settleReachabilityProbe(
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        #expect(wasProbe == true)
        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        let pb = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == b })).first
        #expect(pa?.reachabilityProbedAt == now)
        #expect(pa?.recipients.first?.email == "jane@aurora.org")   // found contact stored
        #expect(pb?.reachabilityProbedAt == now)                    // probed even with no result for it
        #expect(pa?.status == .new)                                 // never drafted
        #expect(try ReachabilityProbeMarker.read(from: markerURL) == nil)   // marker cleared
    }

    @Test func aTotalMissStillMarksEveryShowProbed() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")   // never written: an empty run
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)

        let wasProbe = PrepQueueService.settleReachabilityProbe(
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        #expect(wasProbe == true)
        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(pa?.reachabilityProbedAt == now)
    }

    @Test func noMarkerMeansNotAProbe() throws {
        let ctx = ModelContext(try container())
        _ = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let wasProbe = PrepQueueService.settleReachabilityProbe(
            markerURL: d.appendingPathComponent("absent.json"),
            resultsURL: d.appendingPathComponent("results.json"),
            into: ctx, now: Date(), defaults: freshDefaults())
        #expect(wasProbe == false)
    }

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "probe-\(UUID().uuidString)")!
        return d
    }
}
