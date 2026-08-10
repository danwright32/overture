import Testing
import Foundation
import SwiftData

// #2233: repointing a source at a genuinely DIFFERENT venue carried the old room name and street address
// onto it. For a single-venue ticketing feed both are threaded into every show the source produces, so
// the new venue's shows were attributed to the old room at the old address, and the geography gate placed
// them by that address. Nothing on screen said the room came from a previous page: the Sources sheet
// rendered it identically to one Dan had just typed.
//
// This is the never-guess-a-venue rule (the Bargemusic case) arrived at from the other direction. The app
// is not guessing; it is carrying forward an answer that was true of a different building, and a wrong
// room in a pitch names the wrong place to the person reading it.
@MainActor
@Suite("Repointing a source across venues (#2233)")
struct RepointAcrossVenuesTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ ctx: ModelContext, url: String) -> WatchedSource {
        let s = WatchedSource(sourceId: "the-players-theatre", orgName: "The Players Theatre",
                              listingsURL: url, kind: .html)
        s.venueName = "The Players Theatre"
        s.venueLocation = "115 MacDougal St, New York, NY"
        ctx.insert(s)
        try? ctx.save()
        return s
    }

    // The ordinary correction, and the one every live use of "Fix the address" has been: a better page
    // for the same venue. Dan's answers are his, and discarding them would be its own defect (L5).
    @Test func abetterPageForTheSameVenueKeepsBothAnswers() throws {
        let ctx = try context()
        let s = source(ctx, url: "https://theplayerstheatre.example/shows")

        _ = WatchlistEditing.editURL(s, to: "https://theplayerstheatre.example/show-schedule.html", in: ctx)

        #expect(s.venueName == "The Players Theatre")
        #expect(s.venueLocation == "115 MacDougal St, New York, NY")
    }

    // The hole. A different host is a different building, and neither answer is true of it.
    @Test func adifferentVenueClearsTheRoomAndTheAddress() throws {
        let ctx = try context()
        let s = source(ctx, url: "https://theplayerstheatre.example/shows")

        _ = WatchlistEditing.editURL(s, to: "https://someothervenue.example/calendar", in: ctx)

        #expect(s.venueName == nil, "the old room would have been threaded into every show from the new one")
        #expect(s.venueLocation == nil, "and the geography gate would place them by the old street")
    }

    // Adding or dropping `www.` is not a different building.
    @Test func theSameSiteWithAndWithoutWwwIsOneVenue() throws {
        let ctx = try context()
        let s = source(ctx, url: "https://theplayerstheatre.example/shows")

        _ = WatchlistEditing.editURL(s, to: "https://www.theplayerstheatre.example/events", in: ctx)

        #expect(s.venueName == "The Players Theatre")
    }

    // A previous address nobody can parse answers "not the same", which is the safe direction: the row
    // asks again rather than asserting a room whose provenance can no longer be checked.
    @Test func anUnreadablePreviousAddressIsNotTreatedAsTheSameVenue() {
        #expect(!WatchlistEditing.sameHost("not a url at all", as: "https://venue.example/calendar"))
        #expect(!WatchlistEditing.sameHost(nil, as: "https://venue.example/calendar"))
    }

    @Test func theHostComparisonIsCaseInsensitive() {
        #expect(WatchlistEditing.sameHost("https://Venue.Example/one", as: "https://venue.example/two"))
    }

    // The row ASKS rather than going quiet: #1529's control renders its prompt for a ticketing-feed
    // source carrying no venue name, which is what makes clearing the answer safe rather than lossy.
    @Test func aClearedRoomLeavesTheRowAskingAgain() throws {
        let ctx = try context()
        let s = source(ctx, url: "https://oldvenue.example/shows")
        s.kind = .venueTixFeed

        _ = WatchlistEditing.editURL(s, to: "https://newvenue.venuetix.example/calendar", in: ctx)

        #expect(s.venueName == nil)
        // The row's own reading of an unnamed ticketing feed, which is what #1529's prompt renders from.
        // Asked of the domain rather than the view, so this proves the ask is real rather than assumed.
        #expect(TicketingFeedRead.whileUnnamed(s).isCostingShows,
                "the row must ask which room this is, or clearing the answer would just lose it")
    }
}
