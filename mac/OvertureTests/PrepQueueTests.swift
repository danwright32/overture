import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Prep queue build")
struct PrepQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func insert(_ ctx: ModelContext, group: String, status: ReviewStatus, hasDraft: Bool = false) {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-07-01", sourceListingURL: "https://src", websiteURL: "https://site",
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        if hasDraft { p.draftSubject = "s"; p.draftBody = "b" }
        ctx.insert(p)
        try? ctx.save()
    }

    @Test func needsPrepOnlyForKeptUndrafted() {
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: true) == false)  // already drafted
        #expect(PrepQueueBuilder.needsPrep(status: .new, hasDraft: false) == false)    // not kept
        #expect(PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: false) == false)
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true) == false)
    }

    @Test func gathersOnlyKeptUndraftedProspectsWithExactKey() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        insert(ctx, group: "Already Drafted", status: .queued, hasDraft: true)
        insert(ctx, group: "Not Kept", status: .new)
        insert(ctx, group: "Dismissed Group", status: .dismissed)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        let item = queue.items[0]
        #expect(item.groupName == "Kept Choir")
        // The key must be the prospect's exact stored key (opaque token).
        let expectedKey = Prospect.makeNaturalKey(groupName: "Kept Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        #expect(item.naturalKey == expectedKey)
        #expect(item.websiteURL == "https://site")
    }

    @Test func startPrepWritesWorkListThenReportsRunnerUnavailable() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // Launch throws (runner unavailable) — but the work-list must already be written.
        #expect(throws: PrepQueueService.PrepLaunchError.runnerUnavailable) {
            try PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                           queueURL: tmp, markerURL: marker,
                                           launch: { throw PrepQueueService.PrepLaunchError.runnerUnavailable })
        }
        let written = try Data(contentsOf: tmp)
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: written)
        #expect(decoded.items.count == 1)
        #expect(decoded.items[0].groupName == "Kept Choir")
    }

    @Test func startPrepThrowsWhenNothingToPrep() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Not Kept", status: .new)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        #expect(throws: PrepQueueService.PrepLaunchError.nothingToPrep) {
            try PrepQueueService.startPrep(from: ctx, now: Date(), markerURL: marker, launch: {})
        }
    }

    @Test func isRunningReflectsAFreshMarkerButIgnoresAStaleOne() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-running-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        #expect(PrepQueueService.isRunning(markerURL: marker, now: Date()) == false)  // absent

        try Data().write(to: marker)
        let written = (try marker.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate!
        #expect(PrepQueueService.isRunning(markerURL: marker, now: written.addingTimeInterval(60)) == true)   // fresh
        #expect(PrepQueueService.isRunning(markerURL: marker, now: written.addingTimeInterval(3600)) == false) // stale (>30m)
    }

    @Test func startPrepRefusesWhileARunIsInFlight() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        let tmpQueue = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpQueue); try? FileManager.default.removeItem(at: marker) }

        try Data().write(to: marker) // a run is already in flight
        #expect(throws: PrepQueueService.PrepLaunchError.alreadyRunning) {
            try PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: tmpQueue, markerURL: marker)
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let queue = PrepQueue(version: 1, generatedAt: "now", items: [
            PrepQueueItem(naturalKey: "k", groupName: "G", venue: "V", performanceDate: "2026-07-01",
                          discipline: "choral", websiteURL: nil, sourceListingURL: nil,
                          possibleMatchName: nil, priorRelationship: "none")
        ])
        let data = try PrepQueueBuilder.encode(queue)
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: data)
        #expect(decoded == queue)
    }
}
