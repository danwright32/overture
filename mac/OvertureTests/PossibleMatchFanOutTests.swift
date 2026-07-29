import Testing
import Foundation
import SwiftData
@testable import Overture

// #1694: a possible-match flag is a QUESTION Dan has to answer by hand, so its value is entirely in how
// rarely it is wrong. #1693 was found because he happened to notice one wrong flag on one card; the store
// actually held 18 prospects all asking about the SAME record ("Carnegie Hall Citywide: Ivalas Quartet"),
// which is by itself conclusive evidence the rule had locked onto something those shows shared (the
// building's brand) rather than onto the act. Nothing measured that, and nothing said it.
//
// This is the tripwire for the NEXT one, whatever causes it. The matcher fix (#1702) closed the cause we
// know about; this closes the class, because the tell is the same however the rule goes wrong: one name,
// many cards.
//
// Deliberately NOT applied to a confident client match (`matchedClientName`). A client Dan works with
// repeatedly legitimately appears on many cards at once, so the same rule there would cry wolf on his
// best relationships, and an alert that cries wolf gets ignored.
@MainActor
@Suite("Possible-match fan-out (#1694)")
struct PossibleMatchFanOutTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func flagged(_ ctx: ModelContext, key: String, name: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Show \(key)", discipline: "music",
                         venue: "A Hall", performanceDate: "2026-10-08", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: name == nil ? nil : "history",
                         possibleMatchName: name, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The shape of the real defect: one record, a crowd of cards.
    @Test func oneNameOnACrowdOfCardsIsReportedWithItsCount() throws {
        let ctx = try context()
        for i in 1...19 { flagged(ctx, key: "carnegie-\(i)", name: "Carnegie Hall Citywide: Ivalas Quartet") }

        let findings = PossibleMatchFanOut.findings(in: ctx)

        #expect(findings.count == 1)
        #expect(findings.first?.name == "Carnegie Hall Citywide: Ivalas Quartet")
        #expect(findings.first?.count == 19)
    }

    // The three flags on Dan's real store sit at one card each. If this rule ever reported those, the
    // warning would fire on every store forever and mean nothing.
    @Test func aFlagOnASingleCardIsNeverReported() throws {
        let ctx = try context()
        flagged(ctx, key: "a", name: "Bay Ridge School of Music")
        flagged(ctx, key: "b", name: "TENET Vocal Artists")
        flagged(ctx, key: "c", name: "The Pushover (Chain Theatre)")

        #expect(PossibleMatchFanOut.findings(in: ctx).isEmpty)
    }

    // The boundary, asserted from both sides, so the threshold is a real line and not a number that
    // happens to sit below every case the fixture tries.
    @Test func theThresholdIsARealLine() throws {
        let ctx = try context()
        for i in 1...(PossibleMatchFanOut.defaultThreshold - 1) {
            flagged(ctx, key: "under-\(i)", name: "Just Under")
        }
        #expect(PossibleMatchFanOut.findings(in: ctx).isEmpty)

        flagged(ctx, key: "at", name: "Just Under")
        #expect(PossibleMatchFanOut.findings(in: ctx).map(\.name) == ["Just Under"])
    }

    // A caller shows the worst one first, so the order is part of what this promises.
    @Test func theWorstFanOutIsReportedFirst() throws {
        let ctx = try context()
        for i in 1...4 { flagged(ctx, key: "small-\(i)", name: "Smaller Fan Out") }
        for i in 1...9 { flagged(ctx, key: "big-\(i)", name: "Bigger Fan Out") }

        #expect(PossibleMatchFanOut.findings(in: ctx).map(\.name) == ["Bigger Fan Out", "Smaller Fan Out"])
    }

    // --- what Dan reads -------------------------------------------------------------------------------
    //
    // The sentence lives here rather than in the view, so it can be read cold in a test and so the count
    // it states is provably the count the rule found.

    @Test func theWarningNamesTheRecordAndSaysHowManyCardsAsk() {
        let line = PossibleMatchFanOut.warningLine(
            [.init(name: "Carnegie Hall Citywide: Ivalas Quartet", count: 19)])

        #expect(line == "Carnegie Hall Citywide: Ivalas Quartet is flagged as a possible match on 19 "
                + "shows, which usually means the match is wrong.")
    }

    // Two at once names the worst and counts the rest, rather than growing the masthead a line per
    // finding or, worse, naming none of them and leaving Dan nothing to go on.
    @Test func asecondFanOutIsCountedNotListed() {
        let line = PossibleMatchFanOut.warningLine([
            .init(name: "Bigger Fan Out", count: 9),
            .init(name: "Smaller Fan Out", count: 4),
        ])

        #expect(line == "Bigger Fan Out is flagged as a possible match on 9 shows, which usually means "
                + "the match is wrong. One other match is flagged the same way.")
    }

    @Test func threeOrMoreReadsAsAPlural() {
        let line = PossibleMatchFanOut.warningLine([
            .init(name: "A", count: 9), .init(name: "B", count: 5), .init(name: "C", count: 4),
        ])

        #expect(line?.hasSuffix("2 other matches are flagged the same way.") == true)
    }

    // Nothing found says nothing at all. A line that renders on every launch to report that all is well
    // is how the one launch where it matters gets read past.
    @Test func noFanOutSaysNothing() {
        #expect(PossibleMatchFanOut.warningLine([]) == nil)
    }

    // Rows carrying no flag are not a name, and an empty string is not a name either: counted, they
    // would fan out across the whole store instantly and report a crowd on every launch.
    @Test func rowsWithNoFlagAreNotAName() throws {
        let ctx = try context()
        for i in 1...30 { flagged(ctx, key: "none-\(i)", name: nil) }
        for i in 1...30 { flagged(ctx, key: "blank-\(i)", name: "") }

        #expect(PossibleMatchFanOut.findings(in: ctx).isEmpty)
    }
}
