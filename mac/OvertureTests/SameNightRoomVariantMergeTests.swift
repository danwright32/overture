import Testing
import Foundation
import SwiftData

// #1761: one source page, scouted twice, transcribing its OWN room differently the second time. The
// title half of the same-night pass already folds ("AUGUST!" and "August" reduce alike, #1590). The venue
// half did not: "Jalopy Theatre" and "Jalopy Theater" are two keys, so the pass bucketed the two rows
// apart and could never see them. Dan triaged the same night twice, paid for the same contact lookup
// twice, and the two copies could disagree about the show's rank.
//
// LIVE-STORE-CLAIM verified=2026-07-30 measure="same-night groups whose titles confidently match, and the duplicate rows they hold"
// Measured over all 742 dated rows on 2026-07-30: 26 same-night groups whose titles confidently match,
// holding 32 duplicate rows, of which 23 sit inside the 90-day queue window Dan looks at. Every one of
// the 26 was read by hand and is one show. The pass that shipped before this change caught 3 of them.
//
// WHY THE ROOM NO LONGER PARTICIPATES. Dan's call, 2026-07-30, after seeing the candidate rules scored:
// if the title is the same on the same night, one pitch covers it, so it is one card. That holds even
// when the rooms genuinely differ, which in this store means exactly one group, the 2026 Brooklyn Folk
// Festival playing a church and a theatre on one night: still one festival, still one pitch. So the
// merge now rests on the SAME NIGHT plus a confident title match, and nothing else. Every earlier
// candidate (room name containment, a spelling-distance test, a shared listing link) was measured
// against the store first and scored strictly worse; the notes live on #1761.
//
// What still holds the line is the title, and the guards below pin it: two different acts in one room on
// one night stay two cards, two nights of one show stay a run, and an undated row is never grouped.
@MainActor
@Suite("Same-night room variant merge (#1761)")
struct SameNightRoomVariantMergeTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, _ group: String, date: String?, venue: String,
                        ingestedAt: TimeInterval = 1_000,
                        configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(date ?? "")|\(venue)", groupName: group,
                         discipline: "music", venue: venue, performanceDate: date,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        configure(p)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // The pair Dan saw: two cards for one show on Aug 5, one letter apart in the room.
    @Test func oneRoomSpelledTwoWaysOnOneNightCollapsesToOneCard() throws {
        let ctx = try context()
        insert(ctx, "Roots n' Ruckus! August", date: "2026-08-05",
               venue: "Jalopy Theatre, Red Hook, Brooklyn, NY", ingestedAt: 1_000)
        insert(ctx, "Roots n' Ruckus! AUGUST!", date: "2026-08-05",
               venue: "Jalopy Theater, 315 Columbia Street, Brooklyn, New York", ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        #expect(all(ctx).count == 1)
    }

    // A room's short name against its full one. The old containment test needed two words and so refused
    // a one-word venue, which is why seven live groups at this room never merged.
    @Test func aRoomsShortNameMergesWithItsFullName() throws {
        let ctx = try context()
        insert(ctx, "John Zorn's Alea Iacta Est (World Premiere)", date: "2026-09-27",
               venue: "Roulette Intermedium", ingestedAt: 1_000)
        insert(ctx, "John Zorn's Alea Iacta Est (World Premiere)", date: "2026-09-27",
               venue: "Roulette", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 1)
    }

    // The Derek Piotr workshop, stored four ways, two of which name different rooms in the same street.
    @Test func fourSpellingsOfOneWorkshopCollapseToOneCard() throws {
        let ctx = try context()
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy's Classroom at 319 Columbia St", ingestedAt: 2_000)
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy's Classroom, 319 Columbia St, Brooklyn, New York", ingestedAt: 3_000)
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "319 Columbia Street, Brooklyn, NY", ingestedAt: 4_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 3)
        #expect(all(ctx).count == 1)
    }

    // The one group in the store whose rooms genuinely differ. Dan's call: a festival on one night is
    // still one pitch, so it is still one card.
    @Test func aFestivalAcrossSeveralRoomsOnOneNightIsOneCard() throws {
        let ctx = try context()
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "downtown Brooklyn, NY (specific venue not named on page)", ingestedAt: 1_000)
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "St. Ann & the Holy Trinity Church, 157 Montague St, Brooklyn, New York",
               ingestedAt: 2_000)
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "Jalopy Theatre", ingestedAt: 3_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 2)
        #expect(all(ctx).count == 1)
    }

    // The survivor is chosen for what it HOLDS (Dan's decision, a paid answer, its age), which is not the
    // same as which row names the room best. Left alone, the festival above keeps the oldest row and the
    // card reads "specific venue not named on page" while a copy naming a real church is deleted. The
    // survivor takes the clearest room name in the group with it.
    @Test func theSurvivingCardTakesTheClearestRoomNameWithIt() throws {
        let ctx = try context()
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "downtown Brooklyn, NY (specific venue not named on page)", ingestedAt: 1_000)
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "St. Ann & the Holy Trinity Church, 157 Montague St, Brooklyn, New York",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        #expect(all(ctx).count == 1)
        #expect(survivor.venue?.contains("Holy Trinity Church") == true,
                "the card must name the room a copy knew, not the placeholder that outlived it")
    }

    // The same rule on the workshop: the sloppier "Jalopy Theatre" row is the oldest and so survives, but
    // the card should say which room the workshop is actually in.
    @Test func theSurvivingWorkshopCardNamesTheClassroomNotTheTheatre() throws {
        let ctx = try context()
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy's Classroom at 319 Columbia St", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        #expect(survivor.venue?.contains("Classroom") == true)
    }

    // THE FAILURE DIRECTION, and the only thing now holding the line. The Green Room 42 books two
    // different acts most nights, right through the live store, and those are two real cards. With the
    // room out of the comparison the title is the sole guard, so this is the test that must go red if the
    // title check is ever loosened.
    @Test func twoDifferentActsOnOneNightAreStillNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Bite Me", date: "2026-07-29", venue: "The Green Room 42", ingestedAt: 1_000)
        insert(ctx, "A Tom Lehrer Cabaret", date: "2026-07-29", venue: "The Green Room 42",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // Two different acts in two different rooms on one night. Dropping the room from the comparison must
    // not make unrelated shows reachable to each other.
    @Test func twoDifferentActsInTwoRoomsOnOneNightAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Bite Me", date: "2026-07-29", venue: "The Green Room 42", ingestedAt: 1_000)
        insert(ctx, "A Tom Lehrer Cabaret", date: "2026-07-29", venue: "Jalopy Theatre",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // Two rows in two rooms, both carrying real outreach history: the deferral rule holds across the
    // wider comparison exactly as it did within one room, because merging would move a sent email onto
    // the wrong show.
    @Test func twoSpellingsThatBothCarryHistoryAreLeftAloneAndCounted() throws {
        let ctx = try context()
        insert(ctx, "Copeland", date: "2026-09-17", venue: "Jalopy Theatre", ingestedAt: 1_000) {
            $0.sentAt = Date(timeIntervalSince1970: 9_000)
        }
        insert(ctx, "Copeland", date: "2026-09-17",
               venue: "The Jalopy Theatre & School of Music, 315 Columbia St, Brooklyn, New York",
               ingestedAt: 2_000) { $0.draftBody = "a draft Dan has already read" }

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // The paid answer must outlive a merge across two spellings. The probed row is deliberately the later
    // one, so the fallback survivor rule alone would throw the answer away.
    @Test func theProbedRowSurvivesAMergeAcrossTwoSpellings() throws {
        let ctx = try context()
        insert(ctx, "Tim Eriksen", date: "2026-09-08", venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "Tim Eriksen", date: "2026-09-08",
               venue: "The Jalopy Theatre & School of Music, 315 Columbia St, Brooklyn, New York",
               ingestedAt: 2_000) {
            $0.reachabilityProbedAt = Date(timeIntervalSince1970: 8_000)
            $0.reachabilityResult = .noEmailFound
        }

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let remaining = all(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.reachabilityProbedAt != nil,
                "the paid answer must outlive the merge")
    }

    // Two nights of one show are a RUN, not a duplicate, and the wider comparison must not start
    // reaching across dates.
    @Test func theSameShowAtTwoSpellingsOnTwoNightsIsLeftAlone() throws {
        let ctx = try context()
        insert(ctx, "Tim Eriksen", date: "2026-09-08", venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "Tim Eriksen", date: "2026-09-09", venue: "Jalopy Theater", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 2)
    }

    // An undated listing has no night to share, so it can never be a same-night duplicate however its
    // room is spelled.
    @Test func undatedRowsAreNeverMergedAcrossRooms() throws {
        let ctx = try context()
        insert(ctx, "Tim Eriksen", date: nil, venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "Tim Eriksen", date: nil, venue: "Jalopy Theater", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 2)
    }

    // Runs at every launch, so a second pass over an already-collapsed store must change nothing.
    @Test func asecondPassAcrossRoomsChangesNothing() throws {
        let ctx = try context()
        insert(ctx, "Roots n' Ruckus! August", date: "2026-08-05", venue: "Jalopy Theatre",
               ingestedAt: 1_000)
        insert(ctx, "Roots n' Ruckus! AUGUST!", date: "2026-08-05", venue: "Jalopy Theater",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()
        let second = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(second.duplicatesDeleted == 0)
        #expect(second.conflictsDeferred == 0)
        #expect(all(ctx).count == 1)
    }
}
