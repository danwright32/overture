import Testing
import Foundation
import SwiftData

// #1764's last part. That night was three rows; #1779 fixed the broken presenter key, #1792 surfaced the
// misspelled venue, and #1761 collapsed the copies whose titles agree. One row still stood apart, because
// the misspelling is inside the SHOW TITLE as well as the venue: two copies say "The Golden Hour Series at
// Greely Square: Vaden Landers" and the third says "Greeley Square". One letter, in the title, so the
// title match refuses them and the night reads as two cards.
//
// This is the loosest thing in the merge, and since #1761 the title is the ONLY guard left against a wrong
// merge, so it is deliberately narrow. Two titles match on a typo only when they hold the SAME NUMBER of
// words, exactly ONE word differs, and that word is at least four letters long, is not a number, and is
// one character from its twin.
//
// LIVE-STORE-CLAIM verified=2026-07-30 measure="same-night groups and duplicate rows before and after allowing a one-character typo in one word of the title"
// Measured over all 742 dated rows on 2026-07-30 before writing it: the group count does not move (26),
// duplicate rows removed goes from 32 to 34, and exactly TWO groups change, both of them Golden Hour
// nights absorbing the stranded copy that spells Greeley correctly. No new group appears anywhere in the
// store, which is what says this cannot reach shows it should not.
//
// The number and length rules are the whole safety of it, and they are what the failure tests below pin:
// a season's "Symphony No 5" and "Symphony No 6" are one character apart, and so are "Part I" and
// "Part II". Those are different concerts, and merging them would delete one.
@MainActor
@Suite("One letter's difference inside a show title (#1764)")
struct SameNightTitleTypoMergeTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func insert(_ ctx: ModelContext, _ group: String, date: String, venue: String,
                        ingestedAt: TimeInterval) {
        let p = Prospect(naturalKey: "\(group)|\(date)|\(venue)", groupName: group,
                         discipline: "music", venue: venue, performanceDate: date,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        ctx.insert(p)
        try? ctx.save()
    }

    private func count(_ ctx: ModelContext) -> Int {
        ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).count
    }

    // The night #1764 was opened for, in full. Three rows, one show.
    @Test func theNightThatWasThreeRowsBecomesOneCard() throws {
        let ctx = try context()
        insert(ctx, "The Golden Hour Series at Greely Square: Vaden Landers", date: "2026-09-17",
               venue: "Greely Square", ingestedAt: 1_000)
        insert(ctx, "The Golden Hour Series at Greeley Square: Vaden Landers", date: "2026-09-17",
               venue: "Greeley Square, New York, NY", ingestedAt: 2_000)
        insert(ctx, "The Golden Hour Series at Greely Square: Vaden Landers", date: "2026-09-17",
               venue: "Greeley Square", ingestedAt: 3_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 2)
        #expect(count(ctx) == 1)
    }

    // THE FAILURE DIRECTION that matters most. A season numbers its concerts, and those numbers are one
    // character apart by design. Merging them deletes a real show Dan could have shot.
    @Test func twoNumberedConcertsOfOneSeriesAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Beethoven Symphony No 5", date: "2026-09-17", venue: "Zankel Hall",
               ingestedAt: 1_000)
        insert(ctx, "Beethoven Symphony No 6", date: "2026-09-17", venue: "Zankel Hall",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(count(ctx) == 2)
    }

    // THE FAILURE DIRECTION for short words. "Part I" and "Part II", and any pair whose differing word is
    // too short to tell a typo from a real distinction, stay apart.
    @Test func twoPartsOfOneEveningAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "An Evening of Ballads Part I", date: "2026-09-17", venue: "Jalopy Theatre",
               ingestedAt: 1_000)
        insert(ctx, "An Evening of Ballads Part II", date: "2026-09-17", venue: "Jalopy Theatre",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(count(ctx) == 2)
    }

    // THE FAILURE DIRECTION for two-letter words: "Bite Me" and "Bite Ye" are one word and one character
    // apart, and are not the same show.
    @Test func twoShowsDifferingByAShortWordAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Bite Me", date: "2026-07-29", venue: "The Green Room 42", ingestedAt: 1_000)
        insert(ctx, "Bite Ye", date: "2026-07-29", venue: "The Green Room 42", ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(count(ctx) == 2)
    }

    // THE FAILURE DIRECTION for more than one differing word: a typo is one slip, not two.
    @Test func titlesDifferingInTwoWordsAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Autumn Ballads with Rachel Moore", date: "2026-09-17", venue: "Jalopy Theatre",
               ingestedAt: 1_000)
        insert(ctx, "Autumn Ballads with Rachael Moose", date: "2026-09-17", venue: "Jalopy Theatre",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(count(ctx) == 2)
    }

    // Two different acts on one night remain the case this must never touch.
    @Test func twoDifferentActsAreStillNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Bite Me", date: "2026-07-29", venue: "The Green Room 42", ingestedAt: 1_000)
        insert(ctx, "A Tom Lehrer Cabaret", date: "2026-07-29", venue: "The Green Room 42",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(count(ctx) == 2)
    }
}
