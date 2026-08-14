import Testing
import Foundation
import SwiftData

// #2684: a show Dan wanted, dropped because nobody could be reached.
//
// Every other never-pitched ending says something untrue about that show. "Not a fit" and "Don't want
// to shoot this" blame the org, "Too soon" claims he found it late, "Date conflict", "I had paid work"
// and "Pitching other shows that night" all claim the night was spent. The fact being recorded here is
// about OVERTURE (contact finding found no usable route), not about the org or the night, so folding it
// into any of those makes the question permanently unanswerable: the difference was never written down.
//
// This is the same argument that kept `pitchingOtherShows` out of `dateConflict` in #1821.
@MainActor
@Suite("No way to reach them (#2684)")
struct NoWayToReachThemOutcomeTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func dismissed(as outcome: ShowOutcome, in ctx: ModelContext,
                           group: String = "Aurora Strings") -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "chamber",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         status: .dismissed, dismissReason: outcome)
        ctx.insert(p)
        return p
    }

    // MARK: - It reaches the menus Dan actually uses

    // Nothing was ever sent, so it belongs in the never-pitched half and nowhere else. Being in that
    // list is the whole of its wiring: `ShowOutcome.menu(wasPitched:)` is the one place the choice of
    // menu is made, and the three dismiss menus read it.
    @Test func itIsANeverPitchedEndingAndReachesThatMenu() {
        #expect(ShowOutcome.neverPitched.contains(.noWayToReachThem))
        #expect(!ShowOutcome.pitched.contains(.noWayToReachThem))
        #expect(ShowOutcome.menu(wasPitched: false).contains(.noWayToReachThem))
        #expect(!ShowOutcome.menu(wasPitched: true).contains(.noWayToReachThem))
    }

    // It is Dan's to pick, not one Overture writes for itself. `isOverturesOwn` is derived from the two
    // halves, so a value missing from both would silently become automatic and `ProspectMutations`
    // would refuse it on every menu.
    @Test func danCanChooseItHimself() {
        #expect(!ShowOutcome.noWayToReachThem.isOverturesOwn)
        #expect(ShowOutcome.danCanChoose.contains(.noWayToReachThem))
    }

    @Test func itIsReportedAsNeverPitched() {
        #expect(ShowOutcome.noWayToReachThem.group == .neverPitched)
    }

    // MARK: - The words

    @Test func itReadsAsAFactAboutTheRouteNotAboutTheOrg() {
        #expect(ShowOutcome.noWayToReachThem.label == "No way to reach them")
        let line = ShowOutcome.recordedLine(.noWayToReachThem, org: "Aurora Strings")
        #expect(line == "Aurora Strings dismissed: no way to reach them.")
    }

    // Nothing counts the never-pitched endings in a sentence today, so wording written to sit after a
    // number would be a second vocabulary nothing reads (L46). nil says that plainly.
    @Test func itHasNoCountedPhrase() {
        #expect(ShowOutcome.noWayToReachThem.countedPhrase == nil)
    }

    // MARK: - LocalHistory must learn nothing at all

    // The whole risk this case carries. The org did nothing: Overture failed to find a way in. Recording
    // it as "declined" would file it with the scheduling misses, and "passed" would teach a STANDING
    // pass against that org at that venue (a 5 point penalty on every future show there), quietly
    // demoting an org Dan would happily shoot the moment somebody finds an address.
    @Test func itTeachesTheHistoryNothing() throws {
        let ctx = ModelContext(try container())
        dismissed(as: .noWayToReachThem, in: ctx)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.isEmpty)
    }

    // Measured against its neighbours in the same run, so a later sweep that tidies this case into
    // either existing dismissal branch goes red here rather than silently changing what the scout learns.
    @Test func itsNeighboursStillTeachWhatTheyAlwaysDid() throws {
        let ctx = ModelContext(try container())
        dismissed(as: .dateConflict, in: ctx, group: "Declined Org")
        dismissed(as: .dontWantToShoot, in: ctx, group: "Passed Org")
        dismissed(as: .noWayToReachThem, in: ctx, group: "Unreachable Org")

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(Set(records.map(\.status)) == ["declined", "passed"])
        #expect(!records.contains { $0.groupName == "Unreachable Org" })
    }

    // MARK: - The bridge to the vocabulary being replaced

    // The `DismissReason` bridge is TEMPORARY (#2395 removes it, #2685 sweeps its leftovers) and exists
    // only so stores written before #2394 can be read forward. This ending never existed under that
    // vocabulary, so it has no spelling there, and the bridge's contract is narrowed to say so
    // explicitly rather than leaving it as an unstated gap.
    @Test func itHasNoLegacyDismissReasonSpelling() {
        #expect(ShowOutcome.noWayToReachThem.asDismissReason == nil)
        #expect(!DismissReason.allCases.map(\.asShowOutcome).contains(.noWayToReachThem))
    }

    // MARK: - Siblings: menus this must NOT reach

    // An inquiry's endings derive from the pitched half, so a never-pitched value cannot leak in.
    // Confirmed rather than assumed while the change is open.
    @Test func itNeverReachesTheInquiryMenu() {
        #expect(!InquiryEnding.danCanChoose.contains(.noWayToReachThem))
    }

    // Dan is free that night; nothing about this ending says otherwise, so it must never offer to block
    // the date. `DayOffOffer` reads a whitelist, which is what keeps that true by construction.
    @Test func itNeverOffersToBlockTheDate() {
        #expect(DayOffOffer.offer(reason: .noWayToReachThem, performanceDate: "2026-09-12",
                                  alreadyBlocked: false) == nil)
    }
}
