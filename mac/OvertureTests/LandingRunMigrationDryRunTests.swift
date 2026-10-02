import Testing
import Foundation
import SwiftData

// #4336 (A7) migration dry run. `LandingRun` is a new INDEPENDENT entity (no relationship to any existing
// model and no new column on one), so the migration is purely additive. This rehearses it against a COPY
// of the real Release store (never the live file), through the one shared clone and MigrationRehearsal,
// and proves every existing Prospect and WatchedSource survives and the new table opens empty. It says so
// when it rehearsed nothing (no live store on this machine) rather than passing silently.
@MainActor
@Suite("LandingRun migration dry run against a clone of the live store (#4336)")
struct LandingRunMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingLandingRunPreservesEveryProspectAndSourceInACloneOfTheLiveStore() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("landing-run-dryrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { FileStores.remove(tmpDir) }

        let start = try MigrationRehearsal.begin("the LandingRun entity", liveStore: releaseStoreURL, into: tmpDir)
        guard case let .rehearse(copy) = start else {
            if case let .skipped(said) = start { MigrationRehearsal.report(said) }
            if case let .cloneFailed(said) = start { MigrationRehearsal.report(said) }
            return
        }

        var prospects = 0
        var sources = 0
        do {
            let oldModels = AppSchema.models.filter { ObjectIdentifier($0) != ObjectIdentifier(LandingRun.self) }
            let old = try FileStores.container(for: Schema(oldModels), configurations: [ModelConfiguration(url: copy)])
            let ctx = ModelContext(old)
            prospects = try ctx.fetch(FetchDescriptor<Prospect>()).count
            sources = try ctx.fetch(FetchDescriptor<WatchedSource>()).count
        }

        let container = try FileStores.container(for: AppSchema.schema, configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == prospects)
        #expect(try ctx.fetch(FetchDescriptor<WatchedSource>()).count == sources)
        #expect(try ctx.fetch(FetchDescriptor<LandingRun>()).isEmpty)
        // The lookup the landing makes answers on the migrated store, and the migrated store takes a write
        // and reads it back, which a schema mismatch breaks and an open-and-count would not notice.
        #expect(try LandingRun.landedAt("dry-run-results", in: ctx) == nil)
        let landedAt = Date(timeIntervalSince1970: 1_790_792_040)
        ctx.insert(LandingRun(runIdentity: "dry-run-results", landedAt: landedAt))
        try ctx.save()
        #expect(try LandingRun.landedAt("dry-run-results", in: ctx) == landedAt)
    }
}
