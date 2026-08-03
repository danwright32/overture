import Testing
import Foundation
import SwiftData

// #1598 (milestone 32 Phase 5.1) migration dry-run, on the InquiryMigrationDryRunTests precedent.
// Adding OrgReachabilityAnswer is a lightweight additive migration (a new independent entity, no new
// column on an existing one), but "should be additive" is a claim, and the store it would damage is the
// only copy of Dan's queue. So it is rehearsed against a COPY of the real Release store before it ships,
// never the live file. Skips cleanly on any machine without a live store.
@MainActor
@Suite("Organisation ledger migration dry-run against a clone of the live store")
struct OrgAnswerMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingTheLedgerPreservesEveryProspectInACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = releaseStoreURL
        guard fm.fileExists(atPath: live.path) else { return }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("org-ledger-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let copy = tmpDir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: live.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix))
        }

        // Baseline under the OLD schema (no ledger): what must survive.
        var prospects = 0
        var inquiries = 0
        do {
            let oldModels = AppSchema.models.filter {
                ObjectIdentifier($0) != ObjectIdentifier(OrgReachabilityAnswer.self)
            }
            let oldContainer = try ModelContainer(for: Schema(oldModels),
                                                  configurations: [ModelConfiguration(url: copy)])
            let ctx = ModelContext(oldContainer)
            prospects = try ctx.fetch(FetchDescriptor<Prospect>()).count
            inquiries = try ctx.fetch(FetchDescriptor<Inquiry>()).count
        }

        // Migrate: the same clone under the NEW schema.
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == prospects)
        #expect(try ctx.fetch(FetchDescriptor<Inquiry>()).count == inquiries)
        #expect(try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()).isEmpty)

        // And the migrated store can actually take a write, which is the thing a schema mismatch breaks
        // and an open-and-count would not notice.
        ctx.insert(OrgReachabilityAnswer(orgKey: OrgKey.stored(for: "Dry Run Ensemble")!,
                                         result: .emailFound, probedAt: Date(),
                                         sourceNaturalKey: "k", sourceGroupName: "g",
                                         presenterName: "Dry Run Ensemble",
                                         foundEmails: ["hello@example.org"]))
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()).count == 1)
    }
}
