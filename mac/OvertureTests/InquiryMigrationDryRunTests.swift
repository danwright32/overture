import Testing
import Foundation
import SwiftData

// Phase 2 (#1435) migration dry-run. Adding Inquiry to the live schema is a lightweight additive
// migration (a new independent entity). This rehearses it against a COPY of the real Release store
// (never the live file) and proves every existing Prospect survives the migration and the new Inquiry
// table opens empty. Gated on the live store existing, so it skips cleanly on CI and any machine
// without one. This is the "dry-run against a clone" safeguard Dan asked for before shipping.
@MainActor
@Suite("Inquiry migration dry-run against a clone of the live store")
struct InquiryMigrationDryRunTests {
    // The real Release store path regardless of the build config the tests run under.
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingInquiryPreservesEveryProspectInACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = releaseStoreURL
        guard fm.fileExists(atPath: live.path) else { return }   // no live store here: nothing to rehearse

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inq-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // #1672: through the ONE shared clone, which takes the copy via SQLite's online backup
        // rather than racing three file copies against a live writer. See LiveStoreClone.
        guard let copy = try LiveStoreClone.makeClone(in: tmpDir) else { return }

        // Baseline: open the clone with the OLD schema (no Inquiry) and count the prospects that must
        // survive.
        var baseline = 0
        do {
            let oldModels = AppSchema.models.filter {
                ObjectIdentifier($0) != ObjectIdentifier(Inquiry.self)
            }
            let oldContainer = try ModelContainer(for: Schema(oldModels),
                                                  configurations: [ModelConfiguration(url: copy)])
            baseline = try ModelContext(oldContainer).fetch(FetchDescriptor<Prospect>()).count
        }

        // Migrate: open the SAME clone with the NEW schema (adds Inquiry) and confirm nothing was lost
        // and the new table exists.
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == baseline)
        #expect(try ctx.fetch(FetchDescriptor<Inquiry>()).isEmpty)
    }
}
