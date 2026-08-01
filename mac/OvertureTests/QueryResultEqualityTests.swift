import Testing
import Foundation
import SwiftData
@testable import Overture

// #1774: the measurement that decided the design, rather than an assertion about it.
//
// The issue proposes an @Observable model that "recomputes when the STORE changes, not when the body
// evaluates". Anything of that shape needs a signal saying the store changed, and the obvious candidate is
// to compare this render's @Query results against the last render's. This suite measures whether that
// comparison can actually see an edit.
//
// It matters because getting it wrong is silent: a cache that decides to SKIP would keep serving the row
// Dan just edited, with nothing on screen to say so, which is L40 exactly ("a check that decides to SKIP
// work must compare something that changes whenever the content changes").
@MainActor
@Suite("Comparing query results cannot see an in-place edit (#1774)")
struct QueryResultEqualityTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, fit: Int) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-11-14",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: fit, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The whole question. An edit lands on an existing row; the array's membership is unchanged.
    //
    // Measured on 2026-07-31 by asserting the opposite first and watching it fail: the two fetches compare
    // EQUAL across a saved edit. So a render that skipped its work whenever this render's query results
    // equalled the last render's would skip the render that had to redraw Dan's edit.
    @Test func anEditChangesTheContentButNotTheArray() throws {
        let ctx = try context()
        let p = show(ctx, key: "a", fit: 5)
        show(ctx, key: "b", fit: 7)

        let before = try ctx.fetch(FetchDescriptor<Prospect>())
        p.fitScore += 1
        try ctx.save()
        let after = try ctx.fetch(FetchDescriptor<Prospect>())

        // The content genuinely moved. Without this half the suite would pass just as well against a
        // store where nothing had been edited, which would prove nothing at all.
        #expect(Set(after.map(\.fitScore)) == Set([6, 7]))
        // And the comparison a results-cache would make is blind to it.
        #expect(before == after)
    }

    // The other half of L40: a check that DOES change whenever the content changes is available, it is
    // simply not the array. Pinned so the reason the cache was declined cannot be misread as "SwiftData
    // gives you nothing", which would invite someone to reach for a timestamp or a count instead.
    @Test func theRowCountIsBlindToAnEditTheSameWay() throws {
        let ctx = try context()
        let p = show(ctx, key: "a", fit: 5)

        let before = try ctx.fetch(FetchDescriptor<Prospect>()).count
        p.fitScore += 1
        try ctx.save()
        let after = try ctx.fetch(FetchDescriptor<Prospect>()).count

        #expect(before == after)
    }
}
