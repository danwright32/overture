import Testing
import Foundation
import SwiftData

// #1744: the launch pass that places the rows ALREADY in the store. Without it the fix is forward-only:
// a stored location is rewritten only when the hash-gated scout re-emits that row, so Carnegie's 75 blank
// rows would have stayed blank until Carnegie's calendar next changed, and Dan would still be looking at
// the queue he complained about.
@Suite("Placing the shows already in the store (#1744)")
struct LocationBackfillTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, key: String, groupName: String,
                          venue: String?, location: String? = nil,
                          scoutGroupName: String? = nil,
                          discipline: String = "music") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: groupName, discipline: discipline, venue: venue,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        p.scoutGroupName = scoutGroupName
        ctx.insert(p)
        return p
    }

    // The whole point: a stored row that names a known venue and no place gets one.
    @Test func placesAStoredRowFromItsVenue() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", groupName: "Songmaking 2026", venue: "Weill Recital Hall")
        let n = LocationBackfill.run(in: ctx)
        #expect(p.location == "New York, NY")
        #expect(n == 1)
    }

    // A whitespace-only location is blank, not a place. This is why the pass filters in Swift instead of
    // with a `location == nil` predicate, which would have skipped exactly these rows.
    @Test func treatsAWhitespaceOnlyLocationAsBlank() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", groupName: "A Show", venue: "The Cutting Room", location: "   ")
        LocationBackfill.run(in: ctx)
        #expect(p.location == "New York, NY")
    }

    // NEVER overwrites. A page's own words, and anything Dan corrected, both survive.
    @Test func leavesARowThatAlreadyHasAPlaceAlone() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", groupName: "A Show", venue: "Weill Recital Hall",
                         location: "Somewhere Dan Typed")
        let n = LocationBackfill.run(in: ctx)
        #expect(p.location == "Somewhere Dan Typed")
        #expect(n == 0)
    }

    // Idempotent, and it has to be: this runs on every launch, on Dan's live store.
    @Test func runningItTwiceChangesNothingTheSecondTime() throws {
        let ctx = try makeContext()
        prospect(ctx, key: "a", groupName: "A Show", venue: "Weill Recital Hall")
        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(LocationBackfill.run(in: ctx) == 0)
    }

    // A row Dan renamed still gets placed by the SOURCE's title. The tour convention is something
    // Carnegie writes, so reading Dan's rename would stop placing precisely the rows he has touched.
    @Test func readsTheScoutsTitleNotDansRename() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", groupName: "The Santo Domingo one", venue: "A Hall Nobody Knows",
                         scoutGroupName: "NYO2 in Santo Domingo, Dominican Republic")
        LocationBackfill.run(in: ctx)
        #expect(p.location == "Santo Domingo, Dominican Republic")
    }

    // A row nothing can place is left blank rather than guessed at, and it does not count as placed.
    @Test func leavesAnUnplaceableRowBlank() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", groupName: "A Show", venue: "A Room No Table Has Heard Of")
        let n = LocationBackfill.run(in: ctx)
        #expect(p.location == nil)
        #expect(n == 0)
    }

    // A row whose new place is OUT of range is still filled. The pass places shows; deciding what to do
    // about a far one belongs to the gate and to ExcludedTownRetirement, which run after it.
    @Test func placesARowThatWillTurnOutToBeOutOfRange() throws {
        let ctx = try makeContext()
        let p = prospect(ctx, key: "a", groupName: "NYO-USA in Edinburgh, Scotland",
                         venue: "Usher Hall")
        LocationBackfill.run(in: ctx)
        #expect(p.location == "Edinburgh, Scotland")
        #expect(GeoRefusals.none.hidesFromQueue(location: p.location, discipline: .music))
    }
}

// #1744: which rows get an address box in the Sources sheet. The predicate used to live in SourcesView
// and read "is the listings URL a VenueTix host", which is why exactly ONE of 68 watched sources had a box
// and SoHo Playhouse, a single-venue OvationTix feed, had none.
@Suite("Which sources are single-venue (#1744)")
struct SingleVenueSourceKindTests {

    // The two single-venue ticketing feeds. OvationTix is the one that was missing.
    @Test func aSingleVenueTicketingFeedIsSingleVenue() {
        #expect(SourceKind.venueTixFeed.isSingleVenue)
        #expect(SourceKind.ovationTixFeed.isSingleVenue)
    }

    // Everything else is not, and each for its own reason: Carnegie's feed covers thirteen rooms, an html
    // page may be one room or many and its kind cannot say, OPERA America's feed is a national calendar,
    // and a Squarespace page is any org's own site.
    @Test func everyOtherKindIsNotSingleVenue() {
        for kind: SourceKind in [.algolia, .html, .operaAmericaFeed, .squarespaceFeed] {
            #expect(kind.isSingleVenue == false, "\(kind.rawValue)")
        }
    }

    // Exhaustive on purpose: a new source kind must be classified deliberately rather than silently
    // defaulting into or out of the address box.
    @Test func everyKindIsClassified() {
        #expect(SourceKind.allCases.count == 6)
        #expect(SourceKind.allCases.filter(\.isSingleVenue).count == 2)
    }
}

// #1744: an unplaced show and a placed one must not render as the same card. Decided in the model, so the
// distinction is testable at all (a rule in a SwiftUI body is not).
@Suite("A show with no known city says so (#1744)")
struct UnknownCityLineTests {

    @Test func aPlacedShowShowsItsCity() {
        let line = VenueDisplay.resolve("Weill Recital Hall").locationLine
        #expect(line?.text == "New York, NY")
        #expect(line?.isUnknown == false)
    }

    // The one live row nothing places: a common church name deliberately kept out of the table, because
    // an entry sending it to Washington would hide a real Manhattan show at the same name.
    @Test func anUnplacedShowStatesThatItsCityIsNotKnown() {
        let line = VenueDisplay.resolve("Church of the Epiphany").locationLine
        #expect(line?.text == "City not known")
        #expect(line?.isUnknown == true)
    }

    // But a show with NO VENUE gets no line at all. It already reads "Venue TBD" above, and "City not
    // known" beneath it is the same nothing said twice (#843). Found by reading the rendered pair cold
    // rather than from the code, which is the only thing that catches this class.
    @Test func aVenuelessShowSaysItOnceNotTwice() {
        #expect(VenueDisplay.resolve(nil).hall == "Venue TBD")
        #expect(VenueDisplay.resolve(nil).locationLine == nil)
    }
}
