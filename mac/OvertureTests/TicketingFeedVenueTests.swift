import Testing
import Foundation
import SwiftData

// #1529: The Players Theatre's own schedule page is unreadable, so the scout followed its ticket link one
// hop and landed on OvationTix. The hop re-entered the fetcher WITHOUT the source's name, so the adapter
// fell back to the HOSTNAME and synthesized 149 rows reading "2026-07-26 at web.ovationtix.com". The paid
// run then did the right thing (a hostname is not a room, so venue was null on every row) and the guard
// dropped all 149 shows of a real Greenwich Village theatre.
//
// These pin the fix end to end: no synthesized document ever writes a hostname where a venue goes; a
// hopped ticketing feed is read NATIVELY from the same bytes (free, no paid read at all); the room comes
// from Dan's assertion, never from the org name we happen to know; and with no assertion the rows are
// disclosed as listings the feed named no venue for, not as pages Overture could not read.
@MainActor
@Suite("A ticketing feed reached by a ticket-link hop (#1529)")
struct TicketingFeedVenueTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // 2026-06-21, so both shows below are upcoming and inside the four-month horizon whatever the clock says.
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    private final class LaunchBox { var launched = false }

    private static let ovationTixFeedURL = "https://web.ovationtix.com/trs/cal/277"
    private static let venueTixFeedURL = "https://thegreenroom42.venuetix.com/"

    // Two productions, one of them a two-night run, in the shape the live feed answers with.
    private static let ovationTixJSON = Data("""
    [{"date":"2026-07-20","productions":[{"productionId":1,"name":"Bone Wars","subtitle":"A New Musical"}]},
     {"date":"2026-08-05","productions":[{"productionId":2,"name":"Masticate"}]}]
    """.utf8)

    private static let venueTixJSON = Data("""
    [{"title":"Cabaret Night","dateTime":1785972600000}]
    """.utf8)

    private func hoppedPage(feedURL: String, json: Data, html: String) -> FetchedPage {
        FetchedPage(normalizedHTML: html,
                    finalURL: feedURL,
                    contentHash: "hop-hash-1",
                    // The hop is what says Dan pointed at an ORG's page, not at the venue's own feed.
                    followedTicketLinkFrom: "https://www.theplayerstheatre.com/show-schedule.html",
                    ticketingFeedURL: feedURL,
                    ticketingFeedJSON: json)
    }

    private func playersTheatre(in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "theplayerstheatre-com", orgName: "The Players Theatre",
                              listingsURL: "https://www.theplayerstheatre.com/show-schedule.html",
                              kind: .html)
        ctx.insert(s)
        return s
    }

    // MARK: the synthesized document

    @Test func aFeedWithNoVenueNameNeverWritesTheHostnameWhereTheVenueGoes() throws {
        let events = try OvationTixCalendar.parseEvents(Self.ovationTixJSON)
        let html = OvationTixCalendar.listingHTML(events, venueName: nil)

        #expect(!html.contains("ovationtix"))
        #expect(!html.contains(" at "))
        // The shows themselves are still all there: the document loses the venue line, not the listings.
        #expect(html.contains("Bone Wars"))
        #expect(html.contains("Masticate"))
    }

    @Test func aVenueTixFeedWithNoVenueNameAlsoWritesNoPlace() throws {
        let events = try VenueTixCalendar.parseEvents(Self.venueTixJSON)
        let html = VenueTixCalendar.listingHTML(events, venueName: nil)

        #expect(!html.contains("venuetix"))
        #expect(!html.contains(" at "))
        #expect(html.contains("Cabaret Night"))
    }

    @Test func anAssertedVenueStillAppearsOnEveryRow() throws {
        let events = try OvationTixCalendar.parseEvents(Self.ovationTixJSON)
        let html = OvationTixCalendar.listingHTML(events, venueName: "The Players Theatre",
                                                  location: "115 MacDougal Street, New York, NY")

        #expect(html.contains("at The Players Theatre, 115 MacDougal Street, New York, NY"))
    }

    // MARK: the read path

    @Test func aHoppedFeedIngestsNativelyWithTheVenueDanNamed() async throws {
        let ctx = try context()
        let source = playersTheatre(in: ctx)
        source.venueName = "The Players Theatre"          // Dan's assertion: these shows play in his room
        source.venueLocation = "115 MacDougal Street, New York, NY"
        let box = LaunchBox()
        let page = hoppedPage(feedURL: Self.ovationTixFeedURL, json: Self.ovationTixJSON,
                              html: "<html><body><section></section></body></html>")

        let outcome = try await ScoutService.runScout(
            into: ctx,
            fetch: { _, _, _ in page },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            now: now,
            defaults: UserDefaults(suiteName: "tfv-\(UUID().uuidString)")!)

        // Both productions reached the ingest, for free...
        #expect(outcome.found == 2)
        // ...and no paid read was launched at all.
        #expect(box.launched == false)
        // The feed the hop landed on is recorded, so the Sources sheet can offer the venue control on
        // exactly this row instead of on every source.
        #expect(source.ticketingFeedURL == Self.ovationTixFeedURL)
    }

    @Test func aHoppedFeedWithNoVenueNamedIngestsNothingAndSpendsNothing() async throws {
        let ctx = try context()
        let source = playersTheatre(in: ctx)          // venueName deliberately unset
        let box = LaunchBox()
        let page = hoppedPage(feedURL: Self.ovationTixFeedURL, json: Self.ovationTixJSON,
                              html: "<html><body><section></section></body></html>")

        let outcome = try await ScoutService.runScout(
            into: ctx,
            fetch: { _, _, _ in page },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            now: now,
            defaults: UserDefaults(suiteName: "tfv-\(UUID().uuidString)")!)

        // Nothing is invented: with no room named, the shows have no venue and stay out of the queue.
        #expect(outcome.found == 0)
        // But Dan is not billed for discovering that, which is what today's behaviour costs him.
        #expect(box.launched == false)
        // And they are disclosed as listings the FEED named no venue for, never as pages Overture failed
        // to read: a feed parse follows no detail page, so there is no page that could have failed.
        #expect(source.lastStructuralGapCount == 2)
        #expect(source.lastUnreadableCount == 0)
        #expect(source.ticketingFeedURL == Self.ovationTixFeedURL)
    }

    @Test func aVenueTixFeedReachedByAHopReadsTheSameWay() async throws {
        let ctx = try context()
        let source = playersTheatre(in: ctx)
        source.venueName = "The Green Room 42"
        source.venueLocation = "New York, NY"
        let box = LaunchBox()
        let page = hoppedPage(feedURL: Self.venueTixFeedURL, json: Self.venueTixJSON,
                              html: "<html><body><section></section></body></html>")

        let outcome = try await ScoutService.runScout(
            into: ctx,
            fetch: { _, _, _ in page },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            now: now,
            defaults: UserDefaults(suiteName: "tfv-\(UUID().uuidString)")!)

        #expect(outcome.found == 1)
        #expect(box.launched == false)
    }

    // The regression this fix must not introduce: a source Dan pointed STRAIGHT at a venue's ticketing
    // feed named that venue himself, so its org name is still the room. Only a hop off somebody's own
    // page loses that right.
    @Test func aSourcePointedStraightAtTheFeedKeepsUsingItsOrgName() async throws {
        let ctx = try context()
        let source = WatchedSource(sourceId: "soho", orgName: "SoHo Playhouse",
                                   listingsURL: "https://ci.ovationtix.com/35583", kind: .html)
        source.venueLocation = "New York, NY"
        ctx.insert(source)
        let box = LaunchBox()
        var page = hoppedPage(feedURL: Self.ovationTixFeedURL, json: Self.ovationTixJSON,
                              html: "<html><body><section></section></body></html>")
        page.followedTicketLinkFrom = nil          // no hop: this IS the address Dan is watching

        let outcome = try await ScoutService.runScout(
            into: ctx,
            fetch: { _, _, _ in page },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            now: now,
            defaults: UserDefaults(suiteName: "tfv-\(UUID().uuidString)")!)

        #expect(outcome.found == 2)
        #expect(box.launched == false)
    }

    // MARK: naming the venue

    @Test func namingTheVenueForcesTheNextScoutToReadTheFeedAgain() throws {
        let ctx = try context()
        let source = playersTheatre(in: ctx)
        source.lastContentHash = "already-ingested"    // an unchanged feed would otherwise be skipped

        WatchlistEditing.setVenueName(source, to: "  The Players Theatre  ", in: ctx)

        #expect(source.venueName == "The Players Theatre")     // trimmed
        #expect(source.lastContentHash == nil)                 // so the same bytes are read again
        #expect(source.hasUnreadChanges)
    }

    // The sheet asks for a room on the row that reads a ticketing feed, and on no other: every other
    // source's shows carry their own venue, so the question would be noise on all 60-odd of them.
    @Test func onlyATicketingFeedRowIsAskedForItsRoom() throws {
        let ctx = try context()
        let ordinary = WatchedSource(sourceId: "dessoff", orgName: "Dessoff Choirs",
                                     listingsURL: "https://dessoff.org/concerts", kind: .html)
        ctx.insert(ordinary)
        let feedRow = playersTheatre(in: ctx)
        feedRow.ticketingFeedURL = Self.ovationTixFeedURL

        #expect(TicketingFeedRead.readsATicketingFeed(ordinary) == false)
        #expect(TicketingFeedRead.readsATicketingFeed(feedRow))
        // Answered, it stays on the row so Dan can correct it, rather than vanishing the moment it is set.
        feedRow.venueName = "The Players Theatre"
        #expect(TicketingFeedRead.readsATicketingFeed(feedRow))
    }

    @Test func clearingTheVenueNameLeavesNothingBehind() throws {
        let ctx = try context()
        let source = playersTheatre(in: ctx)
        WatchlistEditing.setVenueName(source, to: "The Players Theatre", in: ctx)

        WatchlistEditing.setVenueName(source, to: "   ", in: ctx)

        #expect(source.venueName == nil)
    }
}
