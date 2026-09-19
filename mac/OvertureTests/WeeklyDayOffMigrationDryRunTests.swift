import Testing
import Foundation
import SwiftData

// #3620 migration dry-run, on the CancelledShootMigrationDryRunTests precedent.
//
// Adding `WeeklyDayOff` is a lightweight additive migration: a new independent entity, no relationship to
// any existing model and no new column on one. "Should be additive" is a claim, and the store it would
// damage is the only copy of Dan's queue, so it is rehearsed against a COPY of the real Release store
// before it ships, never the live file. Skips, and says so, on any machine without a live store.
@MainActor
@Suite("Weekly day off migration dry-run against a clone of the live store")
struct WeeklyDayOffMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingWeeklyDaysOffPreservesEveryRowInACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weekly-day-off-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let start = try MigrationRehearsal.begin("weekly days off", liveStore: releaseStoreURL, into: tmpDir)
        guard case let .rehearse(copy) = start else {
            if case let .skipped(said) = start { MigrationRehearsal.report(said) }
            if case let .cloneFailed(said) = start { MigrationRehearsal.report(said) }
            return
        }

        // Baseline under the OLD schema (no weekly rules): what must survive.
        var prospects = 0
        var daysOff = 0
        var cancelled = 0
        do {
            let oldModels = AppSchema.models.filter {
                ObjectIdentifier($0) != ObjectIdentifier(WeeklyDayOff.self)
            }
            let ctx = ModelContext(try ModelContainer(for: Schema(oldModels),
                                                      configurations: [ModelConfiguration(url: copy)]))
            prospects = try ctx.fetch(FetchDescriptor<Prospect>()).count
            daysOff = try ctx.fetch(FetchDescriptor<DayOff>()).count
            cancelled = try ctx.fetch(FetchDescriptor<CancelledShoot>()).count
        }

        // Migrate: the same clone under the NEW schema.
        let ctx = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                  configurations: [ModelConfiguration(url: copy)]))
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == prospects)
        // The two stores of Dan's own calendar decisions, checked by name rather than left to the prospect
        // count: a weekly rule is about the same calendar they build.
        #expect(try ctx.fetch(FetchDescriptor<DayOff>()).count == daysOff)
        #expect(try ctx.fetch(FetchDescriptor<CancelledShoot>()).count == cancelled)
        #expect(try ctx.fetch(FetchDescriptor<WeeklyDayOff>()).isEmpty)

        // And the migrated store takes a write, freed dates included, which a schema mismatch breaks and an
        // open-and-count would not notice.
        ctx.insert(WeeklyDayOff(weekday: 4, note: "Dry run", freedDates: ["2027-01-06"]))
        try ctx.save()
        let back = try ctx.fetch(FetchDescriptor<WeeklyDayOff>())
        #expect(back.count == 1)
        #expect(back.first?.freedDates == ["2027-01-06"])
    }
}
