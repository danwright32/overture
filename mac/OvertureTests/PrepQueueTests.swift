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

    @discardableResult
    private func insert(_ ctx: ModelContext, group: String, status: ReviewStatus, hasDraft: Bool = false,
                        reprepDraftRequested: Bool = false, reprepContactsRequested: Bool = false,
                        sentAt: Date? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: "2026-07-01", sourceListingURL: "https://src", websiteURL: "https://site",
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        if hasDraft { p.draftSubject = "s"; p.draftBody = "b" }
        p.reprepDraftRequested = reprepDraftRequested
        p.reprepContactsRequested = reprepContactsRequested
        p.sentAt = sentAt
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func needsPrepOnlyForKeptUndrafted() {
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: true) == false)  // already drafted
        #expect(PrepQueueBuilder.needsPrep(status: .new, hasDraft: false) == false)    // not kept
        #expect(PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: false) == false)
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true) == false)
    }

    // #367: a drafted/approved prospect flagged for re-prep re-enters the queue even though it
    // already has a draft, but only for the eligible statuses; contacted/dismissed never qualify
    // no matter what the flags say.
    @Test func needsPrepAlsoTrueForReprepFlaggedEligibleStatuses() {
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true,
                                           reprepDraftRequested: false, reprepContactsRequested: true) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: true) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: false) == true)
    }

    @Test func needsPrepFalseWhenReprepFlagsSetButNoFlagsActuallyTrue() {
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true,
                                           reprepDraftRequested: false, reprepContactsRequested: false) == false)
    }

    @Test func needsPrepNeverTrueForContactedOrDismissedEvenWithReprepFlags() {
        #expect(PrepQueueBuilder.needsPrep(status: .contacted, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: true) == false)
        #expect(PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: true) == false)
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
        // #366 Phase 1: the AI research step needs to know if a show is self-produced.
        #expect(item.production == "self")
    }

    // #367: a normal, never-drafted prospect carries no reprepMode (do both, as always).
    @Test func normalQueuedUndraftedItemCarriesNoReprepMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Fresh Choir", status: .queued)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == nil)
    }

    @Test func reprepDraftOnlyProducesDraftOnlyMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Redraft Me", status: .drafted, hasDraft: true, reprepDraftRequested: true)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == "draft_only")
    }

    @Test func reprepContactsOnlyProducesContactsOnlyMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Find Contacts", status: .approved, hasDraft: true, reprepContactsRequested: true)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == "contacts_only")
    }

    @Test func reprepBothFlagsProducesNoReprepMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Both Please", status: .drafted, hasDraft: true,
              reprepDraftRequested: true, reprepContactsRequested: true)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == nil)
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
        // The runner heartbeats the marker (#47), so "fresh" means touched within the
        // staleness window; only a marker untouched past the window reads as crashed.
        let window = PrepQueueService.markerStaleAfter
        #expect(PrepQueueService.isRunning(markerURL: marker, now: written.addingTimeInterval(window - 1)) == true)
        #expect(PrepQueueService.isRunning(markerURL: marker, now: written.addingTimeInterval(window + 1)) == false)
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

    // #480: the marker must be claimed atomically before launch, not written after, or two rapid
    // presses can both pass the isRunning guard and both launch. The nested call inside `launch`
    // simulates a second press landing while the first is still mid-flight, exactly the check-then-act
    // window a plain post-launch marker write leaves open.
    @Test func concurrentStartPrepCallsYieldExactlyOneLaunch() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        var launches = 0
        _ = try PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL, launch: {
            launches += 1
            #expect(throws: PrepQueueService.PrepLaunchError.alreadyRunning) {
                try PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL,
                                               launch: { launches += 1 })
            }
        })

        #expect(launches == 1)
    }

    // #480: mirrors ReplyClassifyService. If launch fails, the atomic lock must be released so a
    // retry is not permanently blocked.
    @Test func aFailedLaunchReleasesTheLock() throws {
        struct LaunchFailed: Error {}
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        #expect(throws: LaunchFailed.self) {
            try PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL,
                                           launch: { throw LaunchFailed() })
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)   // lock released
    }

    @Test func roundTripsThroughJSON() throws {
        let queue = PrepQueue(version: 2, generatedAt: "now", items: [
            PrepQueueItem(naturalKey: "k", groupName: "G", venue: "V", performanceDate: "2026-07-01",
                          discipline: "choral", websiteURL: nil, sourceListingURL: nil,
                          possibleMatchName: nil, priorRelationship: "none", production: "self")
        ])
        let data = try PrepQueueBuilder.encode(queue)
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: data)
        #expect(decoded == queue)
    }
}
