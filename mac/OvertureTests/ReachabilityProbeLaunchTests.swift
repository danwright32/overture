import Testing
import Foundation
import SwiftData
@testable import Overture

// #1308 Layer 2 Phase 1 (part 2): launching a reachability probe and settling it on completion. The probe
// reuses the single detached-run slot (mutually exclusive with a real Prep), writes a contacts-only queue,
// and records WHICH shows it probed in a side marker so the completion path can mark them probed and route
// the results through the probe-safe ingest, even if the run found nothing.
@MainActor
@Suite("Reachability probe launch (#1308)")
struct ReachabilityProbeLaunchTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String, date: String = "2026-09-12") -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func launchWritesTheProbeQueueMarkerAndKeys() async throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let dir = tmp()
        let queueURL = dir.appendingPathComponent("queue.json")
        let markerURL = dir.appendingPathComponent("prep-running")
        let probeRunURL = dir.appendingPathComponent("probe-run.json")
        var launched = false

        let count = try await PrepQueueService.startReachabilityProbe(
            keys: [a, b], from: ctx, now: Date(timeIntervalSince1970: 0),
            queueURL: queueURL, markerURL: markerURL, probeRunURL: probeRunURL,
            launch: { launched = true })

        #expect(count == 2)
        #expect(launched == true)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))          // took the run lock
        // The probe-run side marker records which shows were probed, for the completion path.
        let recorded = try ReachabilityProbeMarker.read(from: probeRunURL)
        #expect(recorded?.keys == [a, b])
    }

    @Test func launchRefusesWhileAnotherRunHoldsTheLock() async throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let dir = tmp()
        let markerURL = dir.appendingPathComponent("prep-running")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: markerURL)   // a run already holds the lock

        await #expect(throws: PrepQueueService.PrepLaunchError.self) {
            try await PrepQueueService.startReachabilityProbe(
                keys: [a], from: ctx, now: Date(timeIntervalSince1970: 0),
                queueURL: dir.appendingPathComponent("q.json"), markerURL: markerURL,
                probeRunURL: dir.appendingPathComponent("p.json"), launch: {})
        }
    }

    @Test func launchWithNoMatchingKeysRefuses() async throws {
        let ctx = ModelContext(try container())
        _ = newProspect(ctx, group: "Aurora Strings")
        let dir = tmp()
        await #expect(throws: PrepQueueService.PrepLaunchError.self) {
            try await PrepQueueService.startReachabilityProbe(
                keys: ["no-such-key"], from: ctx, now: Date(timeIntervalSince1970: 0),
                queueURL: dir.appendingPathComponent("q.json"),
                markerURL: dir.appendingPathComponent("m"),
                probeRunURL: dir.appendingPathComponent("p.json"), launch: {})
        }
    }

    // #1595: a probe over untriaged Scout shows that finds nothing to check must not say "No kept
    // prospects need prepping. Keep some prospects first." Dan is not prepping and has kept nothing; the
    // sentence describes a different feature and would send him looking for a button that is not the
    // problem.
    @Test func aProbeWithNothingToCheckDoesNotTalkAboutPrepping() async throws {
        let ctx = ModelContext(try container())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let thrown = await #expect(throws: PrepQueueService.PrepLaunchError.self) {
            try await PrepQueueService.startReachabilityProbe(
                keys: ["no-such-key"], from: ctx, now: Date(timeIntervalSince1970: 0),
                queueURL: dir.appendingPathComponent("q.json"),
                markerURL: dir.appendingPathComponent("m"),
                probeRunURL: dir.appendingPathComponent("p.json"), launch: {})
        }
        let message = (thrown?.errorDescription ?? "").lowercased()
        #expect(!message.contains("prep"))
        #expect(message.contains("check"))
    }

    // #1594: the completion behavior. A show is marked probed when the run ANSWERED it, found a contact or
    // not, so the badge resolves instead of sticking on the heuristic. A show the run was asked about but
    // never reached is left alone: stamping it would say "No email found" about a show nobody looked at,
    // and hold it out of a re-check for the 90-day freshness window.
    //
    // This test used to assert the opposite (markProbedStampsEveryProbedShow), which is the defect.
    @Test func markProbedStampsOnlyTheShowsTheRunAnswered() async throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resultsURL = dir.appendingPathComponent("results.json")
        // The run reached Aurora and reported no contacts. It never reached Boreal.
        try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil)
        ])).write(to: resultsURL)

        var stampSaveFailed = false
        PrepQueueService.markProbed(keys: [a, b], answeredIn: resultsURL, in: ctx, now: now,
                                    saveFailed: &stampSaveFailed)
        #expect(!stampSaveFailed)

        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        let pb = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == b })).first
        #expect(pa?.reachabilityProbedAt == now)
        #expect(pb?.reachabilityProbedAt == nil)
    }
}
