import Testing
import Foundation
import SwiftData

// Milestone 61 Phase 0.3. The reader for the contradiction marker.
//
// `ReachabilityVerdictRefresh` stamps every row it finds carrying a stored "no way in" over a route the
// row actually holds, and then repairs it. The stamp is the only surviving record that the contradiction
// existed, because the repair is what removes it (L277). This is what reads that record back.
//
// It answers one question Dan can act on: which shows were written off as unreachable and turned out to
// hold a route all along. That is the population Phase 5.2's second stratum measures over, and it is
// also the honest accounting of what the paid checks got wrong.
@MainActor
@Suite("Shows that were written off and turned out to be reachable (#3356 Phase 0.3)")
struct WrittenOffBacklogTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ name: String, markedAt: Date? = nil,
                      priorRaw: String? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Rowan Hall",
                         performanceDate: "2027-04-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        p.contradictionMarkedAt = markedAt
        p.contradictionPriorResultRaw = priorRaw
        try? ctx.save()
        return p
    }

    @Test func aMarkedRowIsReported() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Written Off", markedAt: Date(), priorRaw: "no_email_found")
        show(ctx, "Never Contradicted")

        let report = WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.total == 1)
        #expect(report.rows.first?.groupName == "Written Off")
    }

    // WHICH verdict was contradicted, because `no_email_found` and `social_only` are different findings
    // about the hunt and a bare count cannot tell them apart. This is the whole reason
    // `contradictionPriorResultRaw` is stored rather than only the date.
    @Test func itSaysWhichVerdictWasContradicted() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Said No Email", markedAt: Date(), priorRaw: "no_email_found")
        show(ctx, "Said Social Only", markedAt: Date(), priorRaw: "social_only")

        let report = WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.count(of: .noEmailFound) == 1)
        #expect(report.count(of: .socialOnly) == 1)
    }

    // A marker whose prior verdict this build cannot read is COUNTED and reported as unattributed rather
    // than dropped, because a row silently vanishing from the total makes the report claim fewer
    // contradictions than were observed (L98, L11).
    @Test func aPriorVerdictThisBuildCannotReadIsStillCounted() throws {
        let ctx = ModelContext(try container())
        show(ctx, "From A Later Build", markedAt: Date(), priorRaw: "some_future_verdict")

        let report = WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.total == 1)
        #expect(report.unattributed == 1)
    }

    // A marker with no date is not a marker. Asserted because the two fields are written together by one
    // pass, so a row carrying only the prior verdict means something went wrong rather than that a
    // contradiction was observed.
    @Test func aPriorVerdictWithNoDateIsNotAContradiction() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Half Written", markedAt: nil, priorRaw: "no_email_found")

        #expect(WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>())).total == 0)
    }

    // Stable order between reads, so the list does not reshuffle under Dan while he is reading it: newest
    // first, then by natural key on a tie. The same rule the other reports here follow.
    @Test func theOrderIsStableBetweenReads() throws {
        let ctx = ModelContext(try container())
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        show(ctx, "Older", markedAt: older, priorRaw: "no_email_found")
        show(ctx, "Newer", markedAt: newer, priorRaw: "no_email_found")

        let rows = WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>())).rows
        #expect(rows.map(\.groupName) == ["Newer", "Older"])
    }
}
