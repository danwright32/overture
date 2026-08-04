import Testing
import Foundation
import SwiftData

// #2031 migration dry-run, on the InquiryMigrationDryRunTests precedent (#1435).
//
// This one differs from every rehearsal before it: those added a new INDEPENDENT entity, which SwiftData
// can add without touching a single existing row. This adds THREE COLUMNS to entities that already hold
// Dan's real data (`Recipient.sendGroupId`, `Prospect.jointOpeningOverride`, `Prospect.sendsTogetherOverride`),
// so the migration reaches the tables that matter. Both are optional with a nil default, which is the shape SwiftData's lightweight
// migration handles, and this rehearses it against a COPY of the real Release store (never the live file).
//
// The failure it exists to catch is the loud one and the quiet one at once: a container that refuses to
// open, and a container that opens onto a silently FRESH store while the real rows sit unreachable in the
// file. Counting is what tells those apart.
//
// Gated on the live store existing, so it skips cleanly on CI and on any machine without one.
@MainActor
@Suite("Joint-send columns migration dry-run against a clone of the live store")
struct JointSendMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingTheJointSendColumnsPreservesACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = releaseStoreURL
        guard fm.fileExists(atPath: live.path) else { return }   // no live store here: nothing to rehearse

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("joint-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Clone the store and its WAL/SHM sidecars, or the copy is a snapshot missing the newest writes.
        let copy = tmpDir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: live.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix))
        }

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let recipients = try ctx.fetch(FetchDescriptor<Recipient>())

        // A store that migrated is a store that still has Dan's rows in it. Zero is the signature of the
        // quiet failure: a brand-new empty store opened beside the real data.
        #expect(!prospects.isEmpty, "the migrated clone holds no shows, which is a fresh store, not a migrated one")
        #expect(!recipients.isEmpty)
        // The rows are intact, not merely present.
        #expect(recipients.contains { $0.email?.isEmpty == false })

        // The new columns arrive empty on every existing row rather than carrying anything. This matters
        // beyond tidiness: `wasWrittenTo` now answers true for any contact holding a group id, and a
        // non-nil default here would make all 100-odd existing contacts read as written to.
        #expect(recipients.allSatisfy { $0.sendGroupId == nil })
        #expect(prospects.allSatisfy { $0.jointOpeningOverride == nil })
        // #2033: and the mode arrives unset on every existing show, which is what makes them all read as
        // "together" (the default Dan asked for) rather than as a choice he never made.
        #expect(prospects.allSatisfy { $0.sendsTogetherOverride == nil })
        #expect(prospects.allSatisfy { $0.sendsTogether })

        // Opening the ALREADY-migrated clone a second time must find exactly the same rows. A migration
        // that loses rows on a later launch is the version of this failure nobody would connect to this
        // change.
        let reopened = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                       configurations: [ModelConfiguration(url: copy)]))
        #expect(try reopened.fetch(FetchDescriptor<Prospect>()).count == prospects.count)
        #expect(try reopened.fetch(FetchDescriptor<Recipient>()).count == recipients.count)
    }
}
