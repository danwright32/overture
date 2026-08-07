import Testing
import Foundation
import SwiftData

// #1751: the address Dan types on a source row is applied at INGEST, through the feed adapter, and by
// nothing else. `LocationBackfill` places stored rows from the venue text, the tour-title convention and
// the shared venue table, and never consults `WatchedSource.venueLocation`. So filling in an address
// changed nothing about the shows from that source ALREADY sitting in the queue until its calendar next
// happened to change and the scout re-emitted them.
//
// It has been harmless only by coincidence: the shared venue table already places every currently blank
// row. The next single-venue feed whose room is not in that table is where it bites, and a control that
// visibly does nothing after a correct save reads as a failed save (L14).
//
// WHY THIS IS NOT the per-source address #1744 deliberately refused. That refusal is about a MULTI-room
// source: Carnegie Hall's own address is 881 7th Ave, so stamping it on the whole source would place its
// Santo Domingo tour date in New York, and a confident wrong place is the one failure in this area that
// can hide a real show from Dan. A SINGLE-venue feed has no such date: every show it publishes is in the
// one room whose address he typed. The kind is what separates the two, so the kind is what gates this.
@MainActor
@Suite("An address typed on a source row places the shows already in the queue (#1751)")
struct SourceAddressPlacesStoredRowsTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func source(_ ctx: ModelContext, id: String, org: String, kind: SourceKind,
                        location: String?) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: org,
                              listingsURL: "https://example.org/\(id)", kind: kind)
        s.venueLocation = location
        ctx.insert(s)
        return s
    }

    // A venue deliberately absent from VenuePlaces, and a title with no tour convention in it, so the
    // only thing that can place this row is the source's own address. A room the shared table already
    // knows would make the test pass for a reason unrelated to the rule (L1).
    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String?, sourceIds: [String],
                      location: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "An evening of songs", discipline: "music",
                         venue: venue, performanceDate: "2099-05-05", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "neutral", coverage: "unknown", fitScore: 3, tier: "longshot",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.location = location
        p.sourceIds = sourceIds
        ctx.insert(p)
        return p
    }

    private let unknownRoom = "The Back Room At Sunny's"

    // MARK: - The rule

    @Test func aBlankRowFromASingleVenueFeedTakesThatSourcesAddress() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: "Brooklyn, NY")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys"])

        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(p.location == "Brooklyn, NY")
    }

    // Every other kind keeps the #1744 refusal. Carnegie is `algolia` and multi-room, and its own address
    // must never reach a show it published from somewhere else: 881 7th Ave is where Carnegie is, not
    // where its Santo Domingo tour date is, and a confident wrong place is the one failure in this area
    // that can remove a real show from Dan's queue.
    //
    // The room here is deliberately one the shared venue table does NOT know, so the only thing that
    // could place this row is the rule under test. Reaching for a real touring venue instead would place
    // it from the table and the assertion would hold for a reason unrelated to the refusal (L1).
    @Test func aMultiRoomSourcesAddressNeverReachesItsShows() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "carnegie", org: "Carnegie Hall", kind: .algolia, location: "New York, NY")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["carnegie"])

        #expect(LocationBackfill.run(in: ctx) == 0)
        #expect(p.location == nil)
    }

    // Additive only, exactly like the rest of the fill: a place the page itself reported, or one Dan
    // corrected, survives.
    @Test func aRowThatAlreadyKnowsWhereItIsIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: "Brooklyn, NY")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys"], location: "Red Hook, NY")

        #expect(LocationBackfill.run(in: ctx) == 0)
        #expect(p.location == "Red Hook, NY")
    }

    // The source's address is the LAST resort, below everything that reads text about this show. A venue
    // string carrying its own address answers first, and must, because it is first-hand about this show
    // while the source's address is a fact about the room in general.
    @Test func thePagesOwnWordsStillOutrankTheSourceAddress() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: "Brooklyn, NY")
        let p = show(ctx, key: "k1", venue: "Bay Chapel, 44 Main Street, Poughkeepsie, NY",
                     sourceIds: ["sunnys"])

        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(p.location?.contains("Poughkeepsie") == true)
    }

    @Test func aSourceWithNoAddressPlacesNothing() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: nil)
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys"])

        #expect(LocationBackfill.run(in: ctx) == 0)
        #expect(p.location == nil)
    }

    // A show can arrive from more than one source, which is why `sourceIds` is a list at all. When two of
    // them are single-venue feeds with DIFFERENT addresses, the row is left blank rather than given
    // whichever happened to sort first: an unplaced show is flagged and kept (#970), while a confidently
    // wrong place can remove a real show from the queue.
    @Test func twoSourcesDisagreeingAboutTheRoomPlaceNothing() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "a", org: "One Room", kind: .ovationTixFeed, location: "Brooklyn, NY")
        source(ctx, id: "b", org: "Another Room", kind: .venueTixFeed, location: "Boston, MA")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["a", "b"])

        #expect(LocationBackfill.run(in: ctx) == 0)
        #expect(p.location == nil)
    }

    // Two single-venue sources SAYING THE SAME THING are not a disagreement, and the row is placed.
    @Test func twoSourcesAgreeingAboutTheRoomStillPlaceIt() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "a", org: "One Room", kind: .ovationTixFeed, location: "Brooklyn, NY")
        source(ctx, id: "b", org: "Same Room", kind: .venueTixFeed, location: "Brooklyn, NY")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["a", "b"])

        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(p.location == "Brooklyn, NY")
    }

    // A multi-room source riding along beside a single-venue one is ignored rather than treated as a
    // dissenting voice: it never had an opinion about this room in the first place.
    @Test func aMultiRoomSourceAlongsideDoesNotCountAsADisagreement() throws {
        let ctx = ModelContext(try container())
        source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: "Brooklyn, NY")
        source(ctx, id: "carnegie", org: "Carnegie Hall", kind: .algolia, location: "New York, NY")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys", "carnegie"])

        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(p.location == "Brooklyn, NY")
    }

    // MARK: - Saving the address does it NOW, not on the next read

    // The half of this Dan can see. Typing an address and watching the queue not change is the defect;
    // the save has to place the rows in front of him.
    @Test func savingAnAddressPlacesThatSourcesRowsImmediately() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: nil)
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys"])

        #expect(WatchlistEditing.setVenueLocation(s, to: "Brooklyn, NY", in: ctx) == 1)
        #expect(p.location == "Brooklyn, NY")
    }

    // And it touches only its OWN source's shows, never the whole store.
    @Test func savingAnAddressLeavesAnotherSourcesShowsAlone() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: nil)
        source(ctx, id: "other", org: "Another Room", kind: .venueTixFeed, location: nil)
        let mine = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys"])
        let theirs = show(ctx, key: "k2", venue: unknownRoom, sourceIds: ["other"])

        #expect(WatchlistEditing.setVenueLocation(s, to: "Brooklyn, NY", in: ctx) == 1)
        #expect(mine.location == "Brooklyn, NY")
        #expect(theirs.location == nil)
    }

    // Clearing the address back to nil places nothing and, being additive-only, does not un-place what an
    // earlier save already wrote. Withdrawing the answer cannot reach into rows the scout has since acted
    // on, so it says so by doing nothing rather than by half-doing something.
    @Test func clearingAnAddressPlacesNothing() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "sunnys", org: "Sunny's Bar", kind: .ovationTixFeed, location: "Brooklyn, NY")
        let p = show(ctx, key: "k1", venue: unknownRoom, sourceIds: ["sunnys"], location: "Brooklyn, NY")

        #expect(WatchlistEditing.setVenueLocation(s, to: "", in: ctx) == 0)
        #expect(p.location == "Brooklyn, NY")
    }

    // MARK: - What the acknowledgement says

    // The whole point of the issue is that the save appeared to do nothing, so the acknowledgement now
    // reports what actually happened rather than promising a future read.
    @Test func theAcknowledgementSaysHowManyShowsItPlaced() {
        #expect(VenueLocationCopy.savedAck(org: "Sunny's Bar", placed: 12).contains("12"))
        #expect(VenueLocationCopy.savedAck(org: "Sunny's Bar", placed: 1).contains(" 1 show"))
    }

    // Nothing to place is its own sentence, and it may not claim a number it did not do.
    @Test func placingNothingSaysSoRatherThanClaimingAnything() {
        let none = VenueLocationCopy.savedAck(org: "Sunny's Bar", placed: 0)
        #expect(none.contains("0") == false)
        #expect(none != VenueLocationCopy.savedAck(org: "Sunny's Bar", placed: 1))
    }
}
