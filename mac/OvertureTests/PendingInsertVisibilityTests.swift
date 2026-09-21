import Testing
import Foundation
import SwiftData

// #4056 asks for the production token poison map to be built ONCE for the batch, "before the per row
// loop in `ScoutService.apply`". Whether that is safe turns on one fact about SwiftData that nothing
// here has ever asserted: does a `fetch` inside the loop SEE rows an earlier iteration inserted but has
// not saved?
//
// `apply` inserts at `ScoutService.swift:1467`, inside the loop, and saves once at `:1528`, after it. So
// if pending inserts ARE visible, the per listing fetch the arm does today is what lets two listings in
// ONE sweep join through the token, and hoisting it to before the loop would silently remove that. That
// is precisely the case #4051 exists for (`Operation Mincemeat`, two nights 70 days apart in one sweep).
//
// Asserted rather than reasoned about from CoreData's `includesPendingChanges` default, because the
// whole design of #4056 rests on the answer (L681).
@MainActor
@Suite("A fetch sees rows inserted earlier in the same batch (#4056)")
struct PendingInsertVisibilityTests {

    @Test func afetchBeforeSaveSeesAnUnsavedInsert() throws {
        let schema = Schema([Prospect.self, Recipient.self])
        let ctx = ModelContext(try ModelContainer(for: schema,
                        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))

        let p = Prospect(naturalKey: "a show|2026-11-14|a room", groupName: "A Show",
                         discipline: "music", venue: "A Room", performanceDate: "2026-11-14",
                         sourceListingURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "unknown", coverage: "unknown", fitScore: 3, tier: "medium",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        // Deliberately NO save, which is the state every iteration of `apply`'s loop is in.

        let fetched = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(fetched.count == 1,
                "a fetch did not see an unsaved insert, so hoisting apply's fetch would change nothing")
        #expect(fetched.first?.groupName == "A Show")
    }
}
