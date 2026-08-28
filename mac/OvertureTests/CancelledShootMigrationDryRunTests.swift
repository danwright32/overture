import Testing
import Foundation
import SwiftData

// #2692 migration dry-run, on the OrgAnswerMigrationDryRunTests precedent.
//
// Adding `CancelledShoot` is a lightweight additive migration: a new independent entity, no relationship
// to any existing model and no new column on one. But "should be additive" is a claim, and the store it
// would damage is the only copy of Dan's queue, so it is rehearsed against a COPY of the real Release
// store before it ships, never the live file. Skips cleanly on any machine without a live store.
@MainActor
@Suite("Cancelled shoot migration dry-run against a clone of the live store")
struct CancelledShootMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingCancelledShootsPreservesEveryProspectInACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = releaseStoreURL

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cancelled-shoot-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Through the ONE shared clone, which copies via SQLite's online backup rather than racing file
        // copies against a live writer, and through MigrationRehearsal, which SAYS when it rehearsed
        // nothing rather than leaving the same green tick as a real run (L98).
        let start = try MigrationRehearsal.begin("cancelled shoots", liveStore: live, into: tmpDir)
        guard case let .rehearse(copy) = start else {
            if case let .skipped(said) = start { MigrationRehearsal.report(said) }
            if case let .cloneFailed(said) = start { MigrationRehearsal.report(said) }
            return
        }

        // Baseline under the OLD schema (no cancellations): what must survive.
        var prospects = 0
        var daysOff = 0
        do {
            let oldModels = AppSchema.models.filter {
                ObjectIdentifier($0) != ObjectIdentifier(CancelledShoot.self)
            }
            let oldContainer = try ModelContainer(for: Schema(oldModels),
                                                  configurations: [ModelConfiguration(url: copy)])
            let ctx = ModelContext(oldContainer)
            prospects = try ctx.fetch(FetchDescriptor<Prospect>()).count
            daysOff = try ctx.fetch(FetchDescriptor<DayOff>()).count
        }

        // Migrate: the same clone under the NEW schema.
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == prospects)
        // Dan's own blocked days are the rows nearest this change and are checked by name rather than
        // being left to the prospect count: a cancellation is about the same calendar they build.
        #expect(try ctx.fetch(FetchDescriptor<DayOff>()).count == daysOff)
        #expect(try ctx.fetch(FetchDescriptor<CancelledShoot>()).isEmpty)

        // And the migrated store can actually take a write, which is the thing a schema mismatch breaks
        // and an open-and-count would not notice.
        ctx.insert(CancelledShoot(bookingId: "dry-run-booking", shootName: "Dry Run Shoot",
                                  startDate: "2027-04-20"))
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<CancelledShoot>()).count == 1)
    }
}
