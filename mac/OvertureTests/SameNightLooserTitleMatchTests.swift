import Testing
import Foundation
import SwiftData
@testable import Overture

// #1590 follow-up, found by Dan walking the first real run (2026-07-28). The dedupe took his headline
// example, three Jalopy open mic cards on one night, from three cards to TWO rather than to one. The
// third survived because it carries a seven word parenthetical aside:
//
//   "Jalopy Open Mic (Every Wednesday)"
//   "Jalopy Open Mic Every Wednesday! ( either in the theatre or the tavern)"
//
// Five shared words out of twelve is 0.42, under GroupNameMatch's 0.6 containment threshold.
//
// That threshold is NOT loosened globally, and that is the whole point of this change. `isConfident` is
// shared with repeat-client detection, where a loose match warms a lead off the wrong organisation, so
// its default stays exactly where it is. The same-night pass gets its own, looser value, because being
// the same night at the same venue is already strong evidence that the strict title test does not have.
//
// LIVE-STORE-CLAIM verified=2026-07-28 measure="extra same-night groups merged at each containment threshold, over untriaged dated shows"
// Measured over all 558 untriaged dated shows on 2026-07-28: dropping the same-night threshold to 0.40
// merges exactly 2 more groups and NOTHING is gained below it (0.34, 0.30 and 0.25 all find the same
// two), so 0.40 is where the curve goes flat rather than an arbitrary pick. Both extras are real: the
// Jalopy pair, and "Total Vocal with Deke Sharon: A Holiday Celebration" against "Total Vocal: Holiday
// Edition with Deke Sharon", one Carnegie concert on one night listed two ways. No false merge.
@MainActor
@Suite("A looser title match, same night only (#1590 follow-up)")
struct SameNightLooserTitleMatchTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, _ group: String, date: String, venue: String,
                        ingestedAt: TimeInterval) -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(date)|\(venue)", groupName: group,
                         discipline: "music", venue: venue, performanceDate: date,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "neutral", coverage: "unknown",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // The row Dan saw on screen.
    @Test func theOpenMicWithAParentheticalAsideMergesToo() throws {
        let ctx = ModelContext(try container())
        insert(ctx, "Jalopy Open Mic (Every Wednesday)", date: "2026-07-29",
               venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "Jalopy Open Mic Every Wednesday! ( either in the theatre or the tavern)",
               date: "2026-07-29", venue: "Jalopy Theatre", ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        #expect(all(ctx).count == 1, "one open mic, one card")
    }

    // The second group the measurement found, and the reason the threshold is 0.40 rather than 0.45.
    @Test func oneConcertListedTwoWaysOnOneNightMerges() throws {
        let ctx = ModelContext(try container())
        insert(ctx, "Total Vocal with Deke Sharon: A Holiday Celebration", date: "2026-11-24",
               venue: "Stern Auditorium / Perelman Stage", ingestedAt: 1_000)
        insert(ctx, "Total Vocal: Holiday Edition with Deke Sharon", date: "2026-11-24",
               venue: "Stern Auditorium / Perelman Stage", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 1)
    }

    // THE GUARD THAT MATTERS MOST. The shared rule must be untouched, or a loose title match starts
    // warming leads off the wrong organisation in repeat-client detection, which is a far worse failure
    // than a duplicate card. The Jalopy pair must still read as NOT a confident match by default.
    @Test func theSharedRuleUsedForClientMatchingIsUnchanged() {
        #expect(!GroupNameMatch.isConfident(
            "Jalopy Open Mic (Every Wednesday)",
            "Jalopy Open Mic Every Wednesday! ( either in the theatre or the tavern)"),
            "the default threshold must stay strict for client matching")
        #expect(!GroupNameMatch.isConfident(
            "Total Vocal with Deke Sharon: A Holiday Celebration",
            "Total Vocal: Holiday Edition with Deke Sharon"))
    }

    // And the looser value must still refuse two genuinely different acts sharing a night and a room.
    // The Green Room 42 books two different shows most nights, right through the live store.
    @Test func theLooserRuleStillRefusesTwoDifferentActs() throws {
        let ctx = ModelContext(try container())
        insert(ctx, "Bite Me", date: "2026-07-29", venue: "The Green Room 42", ingestedAt: 1_000)
        insert(ctx, "A Tom Lehrer Cabaret", date: "2026-07-29", venue: "The Green Room 42",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // A different show at the same venue that night whose title shares the venue's own name must not be
    // dragged in. This is the real third card on Dan's Jul 29 Jalopy date.
    @Test func aGenuinelyDifferentShowAtTheSameVenueSurvives() throws {
        let ctx = ModelContext(try container())
        insert(ctx, "Jalopy Open Mic (Every Wednesday)", date: "2026-07-29",
               venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "Neal Todten / Stuart Bogie & Buck McDaniel", date: "2026-07-29",
               venue: "Jalopy Theatre", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 2, "two different shows at one room on one night")
    }
}
