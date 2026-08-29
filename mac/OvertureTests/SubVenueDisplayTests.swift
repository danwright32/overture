import Testing
import Foundation
import SwiftData

// #1850: a card names the building Dan has a relationship with, with the room inside it in brackets:
// "Carnegie Hall (Zankel Hall)". Dan, 2026-07-30: "Actually I like the Carnegie Hall (Zankel) so it's
// like a subvenue". The building is what he pitches; the room is what he needs in order to shoot it, and
// until now a card could show only one of them.
//
// The pairing comes from two places, and deliberately from nowhere else:
//   1. The curated table, which already knows Carnegie's own halls (#342).
//   2. The venue string itself, when it names both out loud: "Playhouse Theater at Abrons Arts Center".
//      The trailing name must be one the table already knows, so a room is never attributed to a
//      building on the strength of the string alone.
//
// A bare room name is NEVER attributed to a building. "Main Gallery" on its own stays "Main Gallery",
// because galleries, playhouses and studios share names across buildings and a confident wrong parent
// would put Dan in the wrong place. That is the table's standing rule (anything uncertain is omitted so
// it falls through) applied to the parent as well as the city.
@Suite("A room shown inside its building (#1850)")
struct SubVenueDisplayTests {
    private func line(_ venue: String) -> String {
        VenueDisplay.resolve(venue).nameLine
    }

    // The case Dan named. The table already knows Zankel Hall sits inside Carnegie Hall.
    @Test func aKnownHallReadsAsItsBuildingThenTheRoom() {
        #expect(line("Zankel Hall") == "Carnegie Hall (Zankel Hall)")
    }

    // The same pairing when the source spelled both, so the card must not print the building twice.
    @Test func aStringNamingBothDoesNotPrintTheBuildingTwice() {
        #expect(line("Weill Recital Hall, Carnegie Hall") == "Carnegie Hall (Weill Recital Hall)")
    }

    // The live Abrons shape: the room and its building joined by the word "at". Three of Dan's cards
    // carry this, naming rooms the table has never heard of on their own.
    @Test func aRoomJoinedToItsBuildingByAtIsSplit() {
        #expect(line("Playhouse Theater at Abrons Arts Center")
                == "Abrons Arts Center (Playhouse Theater)")
        #expect(line("Main Gallery at Abrons Arts Center")
                == "Abrons Arts Center (Main Gallery)")
        #expect(line("Experimental Theater at Abrons Arts Center")
                == "Abrons Arts Center (Experimental Theater)")
    }

    // Jalopy's Classroom is Jalopy's own room, taught to the table as part of this change.
    @Test func jalopysClassroomReadsAsJalopyTheatre() {
        #expect(line("Jalopy's Classroom") == "Jalopy Theatre (Jalopy's Classroom)")
    }

    // The string the live store ACTUALLY holds, which is not the tidy one above: the room, then "at",
    // then its street rather than its building. The room half is the half the table knows, so the
    // building has to be found from that end too. Written after a simulation against the real store
    // showed the tidy fixture passing while the stored shape fell straight through.
    @Test func aRoomFollowedByItsStreetStillFindsItsBuilding() {
        #expect(line("Jalopy's Classroom at 319 Columbia St") == "Jalopy Theatre (Jalopy's Classroom)")
        #expect(line("Jalopy's Classroom, 319 Columbia St, Brooklyn, New York")
                == "Jalopy Theatre (Jalopy's Classroom)")
    }

    // A building with no room named is just the building. No empty brackets, no repetition.
    @Test func aBuildingOnItsOwnIsUnchanged() {
        #expect(line("Jalopy Theatre") == "Jalopy Theatre")
        #expect(line("Abrons Arts Center") == "Abrons Arts Center")
    }

    // THE FAILURE DIRECTION. A bare room name that the table cannot place must never be handed a parent.
    // "Main Gallery" belongs to no building as far as Overture can prove, and guessing would send Dan to
    // the wrong address.
    @Test func aBareRoomNameIsNeverGivenABuilding() {
        #expect(line("Main Gallery") == "Main Gallery")
        #expect(line("Playhouse Theater") == "Playhouse Theater")
    }

    // THE FAILURE DIRECTION for the "at" split: the trailing name has to be a building the table knows.
    // Two names joined by "at" prove nothing on their own.
    @Test func atOnlySplitsWhenTheBuildingIsOneWeKnow() {
        #expect(line("The Attic at Somewhere Nobody Watches")
                == "The Attic at Somewhere Nobody Watches")
    }

    // A venue nobody has ever heard of reads exactly as it is stored.
    @Test func anUnknownVenueIsPrintedAsItStands() {
        #expect(line("Baruch Performing Arts Center") == "Baruch Performing Arts Center")
    }

    // A missing venue keeps saying so rather than gaining brackets.
    @Test func aMissingVenueStillReadsVenueTBD() {
        #expect(VenueDisplay.resolve(nil).nameLine == VenueDisplay.venueTBD)
    }
}

// The other half of #1850: a merge must stop discarding the room. #1846 overwrote the surviving row's
// venue with the name Dan entered on the watchlist, which on the live store threw away
// "Playhouse Theater at Abrons Arts Center" and the other Abrons rooms in favour of the bare building.
// Once deleted, no row holds the room and no display change can bring it back, so the merge now keeps
// whichever spelling NAMES THE MOST and lets the card do the splitting.
@MainActor
@Suite("A merge keeps the room, not just the building (#1850)")
struct MergeKeepsTheRoomTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func watch(_ ctx: ModelContext, id: String, orgName: String) {
        ctx.insert(WatchedSource(sourceId: id, orgName: orgName, kind: .html))
        try? ctx.save()
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

    private func survivingVenue(_ ctx: ModelContext) -> String? {
        ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).first?.venue
    }

    // The live shape, and the data loss this closes: the room must outlive the merge even though Dan
    // watches the building under its bare name.
    @Test func theRoomOutlivesAMergeWithTheWatchedBuilding() throws {
        let ctx = try context()
        watch(ctx, id: "abronsartscenter-org", orgName: "Abrons Arts Center")
        insert(ctx, "Orbit", date: "2026-08-09", venue: "Abrons Arts Center, New York, NY",
               ingestedAt: 1_000)
        insert(ctx, "Orbit", date: "2026-08-09", venue: "Experimental Theater at Abrons Arts Center",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let venue = survivingVenue(ctx) ?? ""
        #expect(venue.contains("Experimental Theater"), "the room must survive, got \(venue)")
        #expect(VenueDisplay.resolve(venue).nameLine == "Abrons Arts Center (Experimental Theater)")
    }

    // Where the watched name really is the fullest thing anyone said, it still wins, so #1846's headline
    // case is untouched.
    @Test func theWatchedNameStillWinsWhenNothingMoreSpecificExists() throws {
        let ctx = try context()
        watch(ctx, id: "roulette-org", orgName: "Roulette Intermedium")
        insert(ctx, "John Zorn's Alea Iacta Est", date: "2026-09-27", venue: "Roulette",
               ingestedAt: 1_000)
        insert(ctx, "John Zorn's Alea Iacta Est", date: "2026-09-27", venue: "Roulette Intermedium",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivingVenue(ctx) == "Roulette Intermedium")
    }

    // A festival playing a church and a theatre keeps the room a copy actually named, rather than the
    // building of whichever source happened to list it. Nothing in the data says the church sits inside
    // the theatre, because it does not.
    @Test func aFestivalKeepsTheRoomACopyNamed() throws {
        let ctx = try context()
        watch(ctx, id: "jalopytheatre-netlify-app", orgName: "Jalopy Theatre")
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "downtown Brooklyn, NY (specific venue not named on page)", ingestedAt: 1_000)
        insert(ctx, "The 2026 Brooklyn Folk Festival", date: "2026-11-06",
               venue: "St. Ann & the Holy Trinity Church, 157 Montague St, Brooklyn, New York",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(survivingVenue(ctx)?.contains("Holy Trinity Church") == true)
    }
}
