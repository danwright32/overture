import Testing
import Foundation
import SwiftData

// #1846: which room a merged card names. #1761 collapsed one show billed at one room spelled several
// ways into one card, and had to decide what the surviving card says when its copies disagree. It took
// the most SPECIFIC spelling, which is right when the copies are all guesses at a room Overture has never
// been told about, and wrong when Dan already named that room himself when he started watching it.
//
// Dan, 2026-07-30: "If it's a known venue that I watch, it should go to the venue that I entered when we
// started watching it. If it's a new venue because I'm watching the artist and we don't know it, it can
// go to the more specific one."
//
// LIVE-STORE-CLAIM verified=2026-07-30 measure="watched sources, whether venueName is ever set, and how many rooms each source's shows name"
// Measured 2026-07-30. Two facts shaped this rule and neither is visible from the code:
//   1. `WatchedSource.venueName`, the field that LOOKS like the name Dan entered, is set on 0 of 69
//      sources. It exists for one narrow shape (#1529) and has never been filled in. `orgName` is the
//      field that actually holds the name: "Jalopy Theatre", "Roulette Intermedium", "Abrons Arts Center".
//   2. A watched source is NOT necessarily one room. 11 sources publish shows naming more than one room,
//      and Carnegie Hall alone names 26 distinct room strings across 117 rows. Nothing in the model marks
//      which watched sources are venues and which are ensembles Dan follows from hall to hall, and
//      SourceKind deliberately refuses to answer it ("Jalopy's page is one room, Carnegie's is thirteen").
//
// So the entered name cannot simply win: applied bluntly it relabels a Zankel Hall concert as
// "Carnegie Hall" and loses which of the three halls it is in, which for a photographer is the whole
// question. The rule Dan chose instead: the entered name wins WHEN ONE OF THE COPIES ALREADY SPELLED THE
// ROOM THAT WAY. That gives him his own name everywhere he asked for it, and stays silent where his name
// names the building rather than the room.
// The match is on the ROOM NAME, not on which source produced the row: a room Dan named is the same room
// whoever lists the show. The `sourceIds` below are real-shaped rather than load-bearing.
@MainActor
@Suite("Which room a merged card names (#1846)")
struct MergedCardRoomNameTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func watch(_ ctx: ModelContext, id: String, orgName: String) {
        ctx.insert(WatchedSource(sourceId: id, orgName: orgName, kind: .html))
        try? ctx.save()
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, _ group: String, date: String?, venue: String,
                        sourceIds: [String] = [], ingestedAt: TimeInterval = 1_000) -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(date ?? "")|\(venue)", groupName: group,
                         discipline: "music", venue: venue, performanceDate: date,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        p.sourceIds = sourceIds
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func survivor(_ ctx: ModelContext) -> Prospect? {
        ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).first
    }

    // #1850 REVERSED this one, deliberately. The entered name used to beat a copy that named a more
    // specific room, which deleted the room from the only row holding it. Dan chose to keep both instead
    // and let the card render "building (room)", so the entered name now yields to anything that says
    // more, and "Jalopy's Classroom" survives where "Jalopy Theatre" used to win.
    @Test func aMoreSpecificRoomOutlivesTheEnteredName() throws {
        let ctx = try context()
        watch(ctx, id: "jalopytheatre-netlify-app", orgName: "Jalopy Theatre")
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy Theatre", sourceIds: ["jalopytheatre-netlify-app"], ingestedAt: 1_000)
        insert(ctx, "A Workshop with the Derek Piotr Fieldwork Archive", date: "2026-10-16",
               venue: "Jalopy's Classroom at 319 Columbia St",
               sourceIds: ["jalopytheatre-netlify-app"], ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivor(ctx)?.venue == "Jalopy's Classroom at 319 Columbia St")
    }

    // #1850: same reversal. The room inside the building outlives the merge, because the room is
    // the same room. Live shape: "Abrons Arts Center, New York, NY" against the room inside it.
    @Test func theRoomInsideTheBuildingOutlivesTheEnteredName() throws {
        let ctx = try context()
        watch(ctx, id: "abronsartscenter-org", orgName: "Abrons Arts Center")
        insert(ctx, "Orbit", date: "2026-08-09", venue: "Abrons Arts Center, New York, NY",
               sourceIds: ["abronsartscenter-org"], ingestedAt: 1_000)
        insert(ctx, "Orbit", date: "2026-08-09", venue: "Experimental Theater at Abrons Arts Center",
               sourceIds: ["abronsartscenter-org"], ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivor(ctx)?.venue == "Experimental Theater at Abrons Arts Center")
    }

    // The entered name is the LONGER one here, so this passes for the wrong reason unless the rule really
    // consults the watchlist: it is also what the most-specific rule would pick. Kept because it is the
    // live shape at seven groups, and paired with the guard below that no longer holds.
    @Test func theEnteredNameWinsWhenItIsTheFullerSpelling() throws {
        let ctx = try context()
        watch(ctx, id: "roulette-org", orgName: "Roulette Intermedium")
        insert(ctx, "John Zorn's Alea Iacta Est", date: "2026-09-27", venue: "Roulette",
               sourceIds: ["roulette-org"], ingestedAt: 1_000)
        insert(ctx, "John Zorn's Alea Iacta Est", date: "2026-09-27", venue: "Roulette Intermedium",
               sourceIds: ["roulette-org"], ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivor(ctx)?.venue == "Roulette Intermedium")
    }

    // THE FAILURE DIRECTION, and the reason the rule is conditional. Carnegie Hall is watched under the
    // name of the BUILDING and its shows play three different halls. Neither copy calls the room
    // "Carnegie Hall", so the entered name must stay out of it and the actual hall must survive. Without
    // the condition this card reads "Carnegie Hall" and which hall the concert is in is gone.
    @Test func theEnteredNameLosesWhenItNamesTheBuildingAndNotTheRoom() throws {
        let ctx = try context()
        watch(ctx, id: "carnegie", orgName: "Carnegie Hall")
        insert(ctx, "Trio Azura", date: "2026-10-14", venue: "Zankel Hall",
               sourceIds: ["carnegie"], ingestedAt: 1_000)
        insert(ctx, "Trio Azura - New York Debut", date: "2026-10-14",
               venue: "Zankel Hall at Carnegie Hall", sourceIds: ["carnegie"], ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let venue = survivor(ctx)?.venue ?? ""
        #expect(venue.contains("Zankel"), "the hall must survive, got \(venue)")
        #expect(venue != "Carnegie Hall")
    }

    // The other half of Dan's sentence: a show found by watching a PERFORMER, playing a room nobody has
    // ever named, keeps the most specific spelling its copies hold.
    @Test func aRoomNobodyWatchesKeepsTheMostSpecificSpelling() throws {
        let ctx = try context()
        watch(ctx, id: "heartbeat-opera", orgName: "Heartbeat Opera")
        insert(ctx, "Salome", date: "2026-08-11", venue: "Baruch",
               sourceIds: ["heartbeat-opera"], ingestedAt: 1_000)
        insert(ctx, "Salome", date: "2026-08-11", venue: "Baruch Performing Arts Center",
               sourceIds: ["heartbeat-opera"], ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivor(ctx)?.venue == "Baruch Performing Arts Center")
    }

    // A show from a source nobody watches at all must not crash or blank the room.
    @Test func aShowFromAnUnwatchedSourceKeepsTheMostSpecificSpelling() throws {
        let ctx = try context()
        insert(ctx, "Copeland", date: "2026-09-17", venue: "Jalopy Theatre", ingestedAt: 1_000)
        insert(ctx, "Copeland", date: "2026-09-17",
               venue: "The Jalopy Theatre & School of Music, 315 Columbia St, Brooklyn, New York",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivor(ctx)?.venue?.contains("School of Music") == true)
    }

    // A merge of rows that all spell the room identically must leave the field completely alone, whether
    // or not a watchlist entry exists, so the common case never rewrites anything.
    @Test func rowsThatAgreeOnTheRoomAreLeftUntouched() throws {
        let ctx = try context()
        watch(ctx, id: "jalopytheatre-netlify-app", orgName: "Jalopy Theatre")
        insert(ctx, "Tim Eriksen", date: "2026-09-08", venue: "Jalopy Theatre",
               sourceIds: ["jalopytheatre-netlify-app"], ingestedAt: 1_000)
        insert(ctx, "Tim Eriksen: an evening of ballads", date: "2026-09-08", venue: "Jalopy Theatre",
               sourceIds: ["jalopytheatre-netlify-app"], ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivor(ctx)?.venue == "Jalopy Theatre")
    }
}
