import Testing
import Foundation
@testable import Overture

// #1127: The Cell embeds a tickettailor box-office widget in its page. A plain fetch of the page reads the
// widget SHELL (the events live in a cross-origin widget the shell only points at), so the source yields
// nothing. Unlike OPERA/VenueTix this is NOT host-routed: tickettailor is embedded in arbitrary venue
// sites, and the page hands us the widget URL in a `data-url` attribute. The events widget itself is
// plain server-rendered HTML fetchable with browser headers (no Cloudflare block, no render). These tests
// pin the extraction of that widget URL from a real embed snippet.
@Suite("TicketTailor embed hop")
struct TicketTailorTests {
    // A real slice of thecelltheatre.org/box-office: the tickettailor widget is declared with a data-url.
    static let embedPage = #"""
    <div class="tt-widget" data-url="https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/"></div>
    <script src="https://cdn.tickettailor.com/js/widgets/min/widget.js"></script>
    """#

    @Test func findsTheWidgetUrlInAnEmbed() {
        let url = TicketTailor.widgetURL(inPage: Self.embedPage)
        #expect(url?.absoluteString == "https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/")
    }

    @Test func returnsNilWhenThePageHasNoTicketTailorEmbed() {
        #expect(TicketTailor.widgetURL(inPage: "<div>no tickets here</div>") == nil)
        // A tickettailor link that is not a box-office embed must not be mistaken for one.
        #expect(TicketTailor.widgetURL(inPage: #"<a href="https://www.tickettailor.com/?rf=wdg_1">x</a>"#) == nil)
    }

    // #1502: Ticket Tailor serves the SAME box office in two shapes, `all-tickets/<slug>` (list view) and
    // `all-tickets-calendar/<slug>` (calendar view). Only the calendar shape was recognised, so a venue
    // that embedded the list view fell through to the unreadable verdict and told Dan its calendar was
    // "drawn by JavaScript, so there is nothing to read", with Fix the address and Stop watching beside it.
    // Both are wrong advice on a page whose address is right and whose events are perfectly readable.
    //
    // Verified live 2026-07-25 with the header set in widgetRequest: both paths return 200 for the same
    // slug, and only the calendar one carries the `selectableDates` JSON the native parser reads for free.
    // So a list-view embed is normalised to its calendar twin rather than fetched as declared.
    static let afterArtsPage = #"""
    <div class="tt-widget" data-url="https://www.tickettailor.com/all-tickets/afterarts/?ref=website_widget&show_search_filter=true&show_date_filter=true&show_sort=true"></div>
    <script src="https://cdn.tickettailor.com/js/widgets/min/widget.js"></script>
    """#

    @Test func aListViewEmbedIsFoundAndPointedAtItsCalendarTwin() {
        let url = TicketTailor.widgetURL(inPage: Self.afterArtsPage)

        #expect(url?.absoluteString == "https://www.tickettailor.com/all-tickets-calendar/afterarts/")
    }

    // A calendar embed keeps exactly the URL it declares. The working case is not rewritten on the way
    // through: The Cell has been read from this URL since #1127 and must come out of here byte for byte.
    @Test func aCalendarEmbedIsLeftExactlyAsItWasDeclared() {
        #expect(TicketTailor.widgetURL(inPage: Self.embedPage)?.absoluteString
                == "https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/")
    }

    // The path segment is what tells a box office from a plain link, and widening it must not have widened
    // it to anything with "tickets" in the URL. These are the shapes that must still not match.
    @Test func aPlainTicketTailorLinkStillDoesNotCountAsABoxOffice() {
        for link in ["https://www.tickettailor.com/",
                     "https://www.tickettailor.com/pricing/",
                     "https://www.tickettailor.com/all-tickets/",       // no slug: not a box office
                     "https://www.tickettailor.com/box-office/afterarts/"] {
            #expect(TicketTailor.widgetURL(inPage: #"<a href="\#(link)">Powered by Ticket Tailor</a>"#) == nil,
                    "\(link) must not be read as a box-office embed")
        }
    }

    // #1502, the point of the fix: what Dan is TOLD changes, even though today it produces no shows.
    //
    // After Arts' box office is genuinely empty right now (verified live 2026-07-25: the calendar view
    // returns `var selectableDates = [];`). Before this, the hop never fired, so the shell read as
    // unreadable and the row said the calendar was drawn by JavaScript, offering Fix the address and Stop
    // watching. Now the hop fires, parses an honest zero, and the verdict is noDatedContent: nothing is
    // broken, there is simply nothing on. That is the difference between sending Dan to fix a page that is
    // fine and telling him the truth, and it means the source picks itself up the moment After Arts lists
    // a show, with no attention from him.
    @Test func anEmptyBoxOfficeReadsAsNothingOnRatherThanAsUnreadable() async throws {
        let extractor = TicketTailorExtractor(fetchEvents: { [] },
                                              venueName: "After Arts", location: "Brooklyn, NY")

        let listing = try await extractor.extract()

        #expect(listing.events.isEmpty)
        #expect(listing.verdict == .noDatedContent)
        #expect(listing.verdict != .unreadable)
    }

    // The widget is only reachable with a full browser header set; a bare fetch gets a Cloudflare 403.
    @Test func theWidgetRequestCarriesBrowserHeaders() {
        let req = TicketTailor.widgetRequest(URL(string: "https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/")!)
        #expect(req.url?.absoluteString.contains("all-tickets-calendar/thecelltheatre") == true)
        #expect((req.value(forHTTPHeaderField: "User-Agent") ?? "").contains("Mozilla"))
        #expect(req.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true)
        #expect(req.value(forHTTPHeaderField: "Sec-Fetch-Dest") != nil)
    }

    @Test func fetchWidgetReturnsTheServerRenderedListing() async throws {
        let widget = URL(string: "https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/")!
        let html = #"<div class="calendar-split__event"><h3>A Real Show</h3><time>2026-09-01</time></div>"#
        let page = try await TicketTailor.fetchWidget(widget) { _ in
            (Data(html.utf8), HTTPURLResponse(url: widget, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(page.normalizedHTML.contains("A Real Show"))
        #expect(page.finalURL == widget.absoluteString)
        #expect(!page.contentHash.isEmpty)
    }

    // #1301: a recurring show that gains a NEW DATE (no new events-filter <option>) must move the content
    // hash, or SourceSchedule.decide gates the re-read out (page.contentHash == lastContentHash) and the new
    // performance never surfaces. That change lives ONLY inside the <script> selectableDates, which
    // PageNormalizer strips, so a hash over the normalized bytes is blind to it; the widget's hash must
    // derive from the date data.
    static func widgetPage(dates: String) -> String {
        // Identical page markup and identical events-filter option list across calls: only `dates` varies.
        #"""
        <select class="tt-filter"><option value="429862">Beach visits</option></select>
        <script>var selectableDates = \#(dates);</script>
        """#
    }

    private func fetchedHash(_ html: String) async throws -> String {
        let widget = URL(string: "https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/")!
        return try await TicketTailor.fetchWidget(widget) { _ in
            (Data(html.utf8), HTTPURLResponse(url: widget, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }.contentHash
    }

    @Test func fetchWidgetHashMovesWhenARecurringShowGainsADate() async throws {
        // The same series (429862 "Beach visits") gains 2026-08-02; the option list is unchanged.
        let oneDate = Self.widgetPage(dates: #"{"2026-08-01":{"event_series":[{"series_id":429862,"name":"Beach visits"}]}}"#)
        let twoDates = Self.widgetPage(dates: #"{"2026-08-01":{"event_series":[{"series_id":429862,"name":"Beach visits"}]},"2026-08-02":{"event_series":[{"series_id":429862,"name":"Beach visits"}]}}"#)

        // Premise guard: the two pages normalize identically (the <script> is stripped), so a
        // normalized-HTML hash is blind to the new date. The fix must still tell them apart.
        #expect(PageNormalizer.normalize(oneDate) == PageNormalizer.normalize(twoDates))
        let h1 = try await fetchedHash(oneDate)
        let h2 = try await fetchedHash(twoDates)
        #expect(h1 != h2)
    }

    // Unchanged widget bytes hash the same, so a recurring show whose dates did not move is not needlessly
    // re-read (the hash still abstains when nothing changed).
    @Test func fetchWidgetHashIsStableWhenTheDatesAreUnchanged() async throws {
        let page = Self.widgetPage(dates: #"{"2026-08-01":{"event_series":[{"series_id":429862,"name":"Beach visits"}]}}"#)
        let h1 = try await fetchedHash(page)
        let h2 = try await fetchedHash(page)
        #expect(h1 == h2)
        #expect(!h1.isEmpty)
    }

    // An empty widget (`var selectableDates = [];`) still yields a stable, non-empty hash: the date-data
    // signal degrades gracefully to the empty literal rather than throwing or producing a blank hash.
    @Test func fetchWidgetHashIsStableForAnEmptyWidget() async throws {
        let empty = Self.widgetPage(dates: "[]")
        let h = try await fetchedHash(empty)
        #expect(!h.isEmpty)
        // Empty and populated must not collide, or a venue going from "shows" to "none" would look unchanged.
        let populated = Self.widgetPage(dates: #"{"2026-08-01":{"event_series":[{"series_id":429862,"name":"Beach visits"}]}}"#)
        #expect(h != (try await fetchedHash(populated)))
    }

    // A non-200 (e.g. the Cloudflare 403) must throw, never return an empty page that reads as "no shows".
    @Test func fetchWidgetThrowsOnANon200() async throws {
        let widget = URL(string: "https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/")!
        await #expect(throws: (any Error).self) {
            _ = try await TicketTailor.fetchWidget(widget) { _ in
                (Data("<html>Just a moment</html>".utf8),
                 HTTPURLResponse(url: widget, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    // The hop is wired into fetchSinglePage, which does a live plainFetch no unit test can drive, so the
    // wiring is guarded from source: the hop MUST sit before the readability return, because a tickettailor
    // box-office shell reads as "readable" yet carries no events, so a hop placed after it would never fire.
    @Test func fetchSinglePageHopsBeforeTheReadableCheck() {
        let src = SourceGuardHelper.source("Overture/Integration/SourceFetcher.swift")
        guard let hop = src.range(of: "TicketTailor.widgetURL(inPage: html)"),
              let readable = src.range(of: "carriesReadableContent(normalized)") else {
            Issue.record("could not find the tickettailor hop or the readable check in SourceFetcher")
            return
        }
        #expect(hop.lowerBound < readable.lowerBound)
        #expect(src.contains("TicketTailor.fetchWidget"))
    }
}
