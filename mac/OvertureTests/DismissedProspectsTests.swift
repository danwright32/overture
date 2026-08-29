import Testing
import Foundation
import SwiftData

// #28: dismissed prospects drop out of the queue, but Dan needs to see them and undo a
// mistaken cut. The list shows only dismissed ones (most recent first); restore puts a
// prospect back as an undecided candidate and clears the dismiss reason.
@MainActor
@Suite("Dismissed prospects")
struct DismissedProspectsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, group: String, status: ReviewStatus,
                      reason: ShowOutcome? = nil, ingested: Date) {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "music", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status, dismissReason: reason, ingestedAt: ingested)
        ctx.insert(p)
        try? ctx.save()
    }

    @Test func listsOnlyDismissedMostRecentFirst() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Kept", status: .queued, ingested: Date(timeIntervalSince1970: 1))
        make(ctx, group: "OldCut", status: .dismissed, reason: .notAFit, ingested: Date(timeIntervalSince1970: 2))
        make(ctx, group: "NewCut", status: .dismissed, reason: .hadPaidWork, ingested: Date(timeIntervalSince1970: 9))

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let dismissed = DismissedProspects.list(from: all)
        #expect(dismissed.map(\.groupName) == ["NewCut", "OldCut"])
    }

    @Test func restorePutsItBackAsUndecidedAndClearsReason() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Cut", status: .dismissed, reason: .notAFit, ingested: Date())
        let cut = try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.status == .dismissed }!

        DismissedProspects.restore(cut)
        #expect(cut.status == .new)
        #expect(cut.showOutcomeRaw == nil)
    }
}
