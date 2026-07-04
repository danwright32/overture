import Testing
import Foundation
import SwiftData
@testable import Overture

// #479: applicationDidFinishLaunching ran the recipient backfill, the thread-down repair, and the
// salutation strip against mainContext with no save after them, so a short-lived launch could lose the
// writes and the idempotency guard would just leave a fragile unsaved window every time it re-ran. This
// proves the fix against a real, file-backed store (an in-memory one has nothing to "reopen"): run the
// migrations against one context, WITHOUT the test itself ever calling save, then open a second,
// independent container/context on the same file and confirm the writes already landed.
@Suite("Launch migrations explicit save (#479)")
struct LaunchMigrationsTests {
    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    private func makeProspect(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: key, discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "warm", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    @Test func persistsAllThreeLaunchMigrationsWithoutTheCallerEverCallingSave() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("overture-launch-migrations-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let storeURL = scratch.appendingPathComponent("default.store")

        let container = try openContainer(at: storeURL)
        let context = ModelContext(container)
        let p = makeProspect("k1")
        p.contactEmail = "ann@example.com"
        p.draftBody = "Hi Emma, I photograph performing arts in New York."
        context.insert(p)
        try context.save()   // seed data, as if it were already durable before this launch

        let succeeded = LaunchMigrations.run(in: context)
        #expect(succeeded)

        // The caller (AppDelegate) never calls save itself. Open a brand new container/context on the
        // SAME file: every migrated write must already be there if LaunchMigrations.run saved for real.
        let reopened = try openContainer(at: storeURL)
        let reContext = ModelContext(reopened)
        let reProspects = try reContext.fetch(FetchDescriptor<Prospect>())
        #expect(reProspects.count == 1)
        let reProspect = try #require(reProspects.first)
        #expect(reProspect.recipients.count == 1)
        #expect(reProspect.recipients.first?.provenance == .act)
        #expect(reProspect.draftBody == "I photograph performing arts in New York.")
    }
}
