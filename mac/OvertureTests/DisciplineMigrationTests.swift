import Testing
import Foundation
import SwiftData
@testable import Overture

// #350: Choral folded into Music as one editorial taxonomy decision. Existing prospects stored
// as "choral" get relabeled to "music" on next launch; fitScore/tier are left untouched (Dan's
// call: don't retroactively re-rank already-queued items, only newly scouted events use the
// updated scoring rules).
@Suite("Discipline migration (#350)")
struct DisciplineMigrationTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, key: String, discipline: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: discipline, venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @Test func relabelsChoralProspectsToMusic() throws {
        let ctx = try makeContext()
        prospect(ctx, key: "a", discipline: "choral")
        DisciplineMigration.run(in: ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.first?.discipline == "music")
    }

    @Test func leavesFitScoreAndTierUntouched() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", discipline: "choral")
        DisciplineMigration.run(in: ctx)
        #expect(p.fitScore == 3)
        #expect(p.tier == "longshot")
    }

    @Test func leavesNonChoralProspectsAlone() throws {
        let ctx = try makeContext()
        prospect(ctx, key: "a", discipline: "music")
        prospect(ctx, key: "b", discipline: "dance")
        DisciplineMigration.run(in: ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(Set(all.map(\.discipline)) == ["music", "dance"])
    }

    @Test func isIdempotentOnASecondRun() throws {
        let ctx = try makeContext()
        prospect(ctx, key: "a", discipline: "choral")
        DisciplineMigration.run(in: ctx)
        DisciplineMigration.run(in: ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)
        #expect(all.first?.discipline == "music")
    }
}
