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
    private func show(_ ctx: ModelContext, _ name: String, markedAt: Date? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Rowan Hall",
                         performanceDate: "2027-04-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        p.contradictionMarkedAt = markedAt
        try? ctx.save()
        return p
    }

    @Test func aMarkedRowIsReported() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Written Off", markedAt: Date())
        show(ctx, "Never Contradicted")

        let report = WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.total == 1)
        #expect(report.rows.first?.groupName == "Written Off")
    }

    // The absence of a prior-verdict field is DELIBERATE and is asserted, so a later reader does not
    // add one back on the plan's original reasoning without re-checking the premise. A row is marked
    // only where the stored verdict says there is no way in AND the row holds one, and `noEmailFound`
    // is the only verdict that says there is no way in, so such a field could hold exactly one value
    // and would tell a reader nothing (L46). If the marking rule widens, this test is what says the
    // field has to come back with it.
    @Test func everyMarkedRowWasContradictingTheSameVerdict() throws {
        let ctx = ModelContext(try container())
        let d = UserDefaults(suiteName: "backlog-\(UUID().uuidString)")!
        let key = Prospect.makeNaturalKey(groupName: "Marked By The Real Pass",
                                          performanceDate: "2027-04-18", venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Marked By The Real Pass", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        p.reachabilityResult = .socialOnly
        p.addRecipient(Recipient(id: "r", email: nil, name: "n", role: nil, provenance: .performer,
                                 contactMethodRaw: "form_or_dm", contactConfidenceRaw: "medium",
                                 contactFormURL: "https://instagram.com/someact", contactSourceURL: nil))
        try? ctx.save()

        _ = ReachabilityVerdictRefresh.run(in: ctx, defaults: d)

        // socialOnly IS a way in, so this row is not a contradiction and is not marked. That is the
        // premise the missing field rests on.
        #expect(p.contradictionMarkedAt == nil)
    }

    // No date means no marker, which is the whole of what makes a row a member of this list.
    @Test func aRowWithNoDateIsNotAContradiction() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Half Written", markedAt: nil)

        #expect(WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>())).total == 0)
    }

    // Stable order between reads, so the list does not reshuffle under Dan while he is reading it: newest
    // first, then by natural key on a tie. The same rule the other reports here follow.
    @Test func theOrderIsStableBetweenReads() throws {
        let ctx = ModelContext(try container())
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        show(ctx, "Older", markedAt: older)
        show(ctx, "Newer", markedAt: newer)

        let rows = WrittenOffBacklog.make(from: try ctx.fetch(FetchDescriptor<Prospect>())).rows
        #expect(rows.map(\.groupName) == ["Newer", "Older"])
    }
}
