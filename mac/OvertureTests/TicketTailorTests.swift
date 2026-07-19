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
        // A tickettailor link that is not the all-tickets-calendar embed must not be mistaken for one.
        #expect(TicketTailor.widgetURL(inPage: #"<a href="https://www.tickettailor.com/?rf=wdg_1">x</a>"#) == nil)
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
