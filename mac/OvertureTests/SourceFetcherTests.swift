import Testing
import Foundation
@testable import Overture

// Serves one canned HTTP response, with real headers and a real final URL, so the fetch path's typed
// errors can be tested without a network. Distinct from CarnegieExtractorTests' StubURLProtocol, which
// serves a queue of bodies with no headers: this one needs the content type and the redirect target.
final class PageStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var contentType: String? = "text/html; charset=utf-8"
    nonisolated(unsafe) static var finalURL: String? = nil     // set to simulate a redirect
    nonisolated(unsafe) static var transportError: Error? = nil
    // #806 follow-up: serve DIFFERENT pages for different URLs, so the ticket-link hop (page A links to
    // page B; B is the one with the listing) can be exercised for real.
    nonisolated(unsafe) static var bodiesByURL: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let e = Self.transportError {
            client?.urlProtocol(self, didFailWithError: e)
            return
        }
        let url = URL(string: Self.finalURL ?? request.url!.absoluteString)!
        var headers: [String: String] = [:]
        if let ct = Self.contentType { headers["Content-Type"] = ct }
        let resp = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let body = Self.bodiesByURL[request.url?.absoluteString ?? ""].map { Data($0.utf8) } ?? Self.body
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        status = 200; body = Data(); contentType = "text/html; charset=utf-8"
        finalURL = nil; transportError = nil; bodiesByURL = [:]
    }
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PageStubURLProtocol.self]
    return URLSession(configuration: config)
}

// #799 slice 3: the app fetches a source's listings page ITSELF, natively, and hands the agent a
// pinned copy. That split is deliberate and load-bearing:
//
//   - The listing SET (which shows exist, which are gone) is what re-keys prospects and drives the
//     "did this show get cancelled?" reconcile. It must come from bytes the APP fetched and hashed,
//     not from whatever a site served an agent a second later.
//   - Every fetch failure becomes a TYPED, named error on the source: 401, 429, a timeout, a page that
//     is not HTML, a redirect to a different site. Dan sees which of those happened. "The scout found
//     nothing" is not an acceptable rendering of "the page 404s".
//   - The page is NORMALIZED and hashed here, so a page that has not changed never reaches an AI at
//     all. That is the cost model, not an optimization.
@Suite("Source fetch and page pin (#799)", .serialized)
struct SourceFetcherTests {
    private let url = URL(string: "https://org.example/events")!

    @Test func fetchesAPageAndNormalizesIt() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("""
        <html><head><title>t</title></head><body>
        <script>var junk = "megabytes of this";</script>
        <style>.a { color: red }</style>
        <table><tr><td class="day x9" data-id="17"><div>11</div>
        <a href="https://org.example/show/a">Aurora Strings</a></td></tr></table>
        </body></html>
        """.utf8)

        let page = try await SourceFetcher.fetch(url, session: stubSession())

        #expect(!page.normalizedHTML.contains("megabytes"))     // scripts gone
        #expect(!page.normalizedHTML.contains("color: red"))    // styles gone
        #expect(!page.normalizedHTML.contains("data-id"))       // attribute noise gone
        #expect(page.normalizedHTML.contains("<td>"))           // ...but the GRID SURVIVES
        #expect(page.normalizedHTML.contains("11"))             // and the day number in the cell
        #expect(page.normalizedHTML.contains(#"<a href="https://org.example/show/a">"#))  // and the link
        #expect(page.normalizedHTML.contains("Aurora Strings"))
    }

    // THE BUG DAN HIT ON HIS FIRST REAL LEAD, and the reason it slipped through: every test above uses
    // a script that fits on ONE LINE. Real scripts do not. NSRegularExpression's `.` does not cross a
    // newline unless you ask it to, so a multi-line <script> was never stripped at all.
    //
    // On secondendingensemble.com (a Wix site) that left 32 script blocks intact: the "normalized" page
    // was 246KB instead of 32KB, and the run was handed a quarter-megabyte of JavaScript and reasonably
    // concluded there were no events on it. Dan was told "that doesn't look like an events page". It
    // was, and the page was fine. WE were unreadable, not the site.
    //
    // The failure mode is the worst kind: a confident, plausible, WRONG answer, from a step that
    // reported success.
    @Test func aMultiLineScriptIsStrippedToo() {
        let html = """
        <html><body>
        <script>
          var config = {
            tracking: "megabytes of this",
            nonce: "abc123"
          };
        </script>
        <style>
          .a { color: red }
        </style>
        <div>Second Ending Ensemble</div>
        <a href="/show/1">Oct 3</a>
        </body></html>
        """
        let out = PageNormalizer.normalize(html)

        #expect(!out.contains("megabytes"))          // was: left fully intact
        #expect(!out.contains("tracking"))
        #expect(!out.contains("color: red"))
        #expect(!out.lowercased().contains("<script"))
        #expect(out.contains("Second Ending Ensemble"))   // and the real content survives
        #expect(out.contains("Oct 3"))
    }

    // Why the tag structure must survive: Bargemusic prints NO dates at all. Each concert sits in a
    // cell of a month grid and its date is implied by WHICH cell. Strip to plain text and that
    // information is destroyed. Verified on the real page: normalizing this way cut it from ~17,900
    // tokens to ~1,500 (92%) and the extraction still returned all 6 concerts, still correctly dating
    // the trailing cells to AUGUST rather than July.
    @Test func normalizingKeepsWhatAMonthGridCalendarNeedsToBeReadable() {
        let html = """
        <table><tr>
        <td class="pad"><div>10</div></td>
        <td class="has-event"><div>11</div><h3><a href="/c/a">Immortal Gifts</a></h3></td>
        </tr></table>
        """
        let out = PageNormalizer.normalize(html)
        #expect(out.contains("<td><div>10</div></td>"))
        #expect(out.contains("11"))
        #expect(out.contains("Immortal Gifts"))
    }

    // The second half of what Dan hit: secondendingensemble.com is a Wix site, and once the scripts are
    // correctly stripped, what remains is a NAVIGATION SHELL. Its entire visible text is "Home / Our
    // Story / Prior Performances / Upcoming Events / Contact ... © 2025 ... Proudly created with
    // Wix.com". The shows are drawn by JavaScript and are simply not in the bytes we fetched.
    //
    // The app can see that for itself, natively, and must: handing this to a Claude run wastes a minute
    // and a Claude invocation to be told what we already know, and invites a CONFIDENT WRONG ANSWER
    // ("no events on this page") about a page that is full of events we cannot see.
    //
    // So: a page with essentially no readable content is UNREADABLE, and we say so honestly, rather
    // than blaming the page for not being an events page.
    @Test func aJavaScriptOnlyShellIsRecognizedAsUnreadableRatherThanEmpty() {
        let wixShell = """
        <html><body>
        <script>window.__INITIAL_STATE__ = {"lots":"of state"};</script>
        <div><a href="/">Home</a> <a href="/story">Our Story</a>
        <a href="/upcoming-events">Upcoming Events</a> <a href="/contact">Contact</a></div>
        <div>© 2025 by Second Ending LLC. Proudly created with Wix.com</div>
        </body></html>
        """
        #expect(!PageNormalizer.carriesReadableContent(PageNormalizer.normalize(wixShell)))
    }

    // ...and a real page must NOT be mistaken for a shell, or real sources get declared unreadable and
    // the feature quietly stops working on exactly the small orgs Dan cares about.
    //
    // This is the test that killed the first version of the rule. A length floor looked obviously
    // right, and it would have called THIS page (a small org, three concerts, less text than a Wix
    // shell has boilerplate) unreadable. Wrongly refusing a real page is far worse than wasting a run
    // on a shell, so the rule refuses only a page that is BOTH too thin AND mentions no date at all.
    @Test func aRealPageIsNotMistakenForAShell() {
        let realCalendar = """
        <html><body><h1>Concerts for July 2026</h1>
        <table><tr>
          <td><div>11</div><h3><a href="/c/a">Immortal Gifts: Mozart and Schubert, works for violin and piano</a></h3></td>
          <td><div>12</div><h3><a href="/c/b">Complete Beethoven Piano Sonatas with Conversation, Part 2</a></h3></td>
          <td><div>25</div><h3><a href="/c/c">Vienna Meets Bohemia: Piano Trios of Haydn, Brahms and Dvorak</a></h3></td>
        </tr></table>
        <p>All concerts are admission free. Doors open 20 minutes before the concert.</p>
        </body></html>
        """
        #expect(PageNormalizer.carriesReadableContent(PageNormalizer.normalize(realCalendar)))
    }

    // #806: when the plain download carries nothing to read, load the page the way a BROWSER does (let
    // its JavaScript run) and read the finished page instead.
    //
    // This is what stands between Dan and his own ensemble's site, and between the watchlist and a whole
    // class of the orgs he pitches: small arts organizations live on Wix and Squarespace, whose calendars
    // exist only after their scripts run.
    @Test func aJavaScriptDrawnSiteIsRenderedAndThenReadable() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("""
        <html><body>
        <script>/* the calendar is built here, at runtime */</script>
        <div><a href="/">Home</a> <a href="/events">Upcoming Events</a> <a href="/contact">Contact</a></div>
        <div>© 2025. Proudly created with Wix.com</div>
        </body></html>
        """.utf8)

        // What that page looks like once a browser has run it.
        let rendered = """
        <html><body><h1>Upcoming Events</h1>
        <div><h3>October 3, 2026</h3><p>Second Ending Ensemble at Merkin Hall: piano trios of Haydn,
        Brahms and Dvorak, with a conversation afterwards.</p></div>
        <div><h3>November 14, 2026</h3><p>Mozart and Schubert, works for violin and piano.</p></div>
        </body></html>
        """

        var renderedCount = 0
        let page = try await SourceFetcher.fetch(url, session: stubSession(),
                                                 render: { _ in renderedCount += 1; return rendered })

        #expect(renderedCount == 1)                                 // the fallback fired
        #expect(page.wasRendered)
        #expect(page.normalizedHTML.contains("Second Ending Ensemble"))
        #expect(page.normalizedHTML.contains("October 3"))
        #expect(PageNormalizer.carriesReadableContent(page.normalizedHTML))
    }

    // ...and the browser must NOT be used when the plain download already works. Rendering costs seconds
    // and a whole WebKit instance per source; the watchlist re-checks dozens of sources on a schedule, so
    // "render everything, it's simpler" would quietly make the daily run an order of magnitude slower.
    @Test func aPlainPageIsNeverRenderedBecauseItDoesNotNeedToBe() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("""
        <html><body><h1>Concerts for July 2026</h1>
        <table><tr><td><div>11</div><a href="/c/a">Immortal Gifts: Mozart and Schubert</a></td></tr></table>
        </body></html>
        """.utf8)

        var renderedCount = 0
        let page = try await SourceFetcher.fetch(url, session: stubSession(),
                                                 render: { _ in renderedCount += 1; return "" })

        #expect(renderedCount == 0)          // never touched the browser
        #expect(!page.wasRendered)
        #expect(page.normalizedHTML.contains("Immortal Gifts"))
    }

    // If even the browser cannot produce anything readable, we say so honestly rather than pretending.
    // A page behind a login renders to a sign-in form, and that is not a calendar.
    @Test func aPageThatIsUnreadableEvenAfterRenderingStaysUnreadable() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("<html><body><div>Sign in</div></body></html>".utf8)

        let page = try await SourceFetcher.fetch(url, session: stubSession(),
                                                 render: { _ in "<html><body><form>Sign in</form></body></html>" })

        #expect(page.wasRendered)                                        // we tried
        #expect(!PageNormalizer.carriesReadableContent(page.normalizedHTML))   // and it is still nothing
    }

    // A browser that hangs, crashes, or is simply unavailable must not take the fetch down with it: the
    // raw page is still the best thing we have, and returning it lets the honest "I can't read this"
    // path run instead of an opaque crash.
    @Test func aRenderFailureFallsBackToTheRawPageRatherThanThrowing() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("<html><body><div>Home</div></body></html>".utf8)

        let page = try await SourceFetcher.fetch(url, session: stubSession(),
                                                 render: { _ in throw SourceFetchError.unreachable })

        #expect(!page.wasRendered)
        #expect(page.normalizedHTML.contains("Home"))
    }

    // The hop itself, at the fetch level: Dan's real chain, in miniature. His ensemble's show page has
    // nothing to read (it is a poster IMAGE and a "BUY TIX HERE" button, even after rendering), and that
    // button points at Lincoln Center, which carries the whole listing.
    //
    // THE INFORMATION WAS NEVER ON THE ENSEMBLE'S SITE AT ALL. The link is the lead.
    @Test func aPageWithNothingToReadFollowsItsTicketLinkToThePageThatHasIt() async throws {
        PageStubURLProtocol.reset()
        let ensemble = "https://www.secondendingensemble.com/single-project-1"
        let lincoln = "https://lincolncenter.org/venue/alice-tully-hall/second-ending-290"
        PageStubURLProtocol.bodiesByURL = [
            ensemble: """
            <html><body><div><a href="/">Home</a></div><img src="poster.jpg">
            <a href="\(lincoln)">BUY TIX HERE</a>
            <div>© 2025. Proudly created with Wix.com</div></body></html>
            """,
            lincoln: """
            <html><body><h1>Second Ending Ensemble: Mahler 1 "Titan"</h1>
            <p>Alice Tully Hall, October 3, 2026 at 7:30pm. The ensemble performs Mahler's first
            symphony in a chamber arrangement, alongside works written for the group, in a programme
            running about ninety minutes with one interval. Tickets from the box office.</p></body></html>
            """,
        ]

        let page = try await SourceFetcher.fetch(URL(string: ensemble)!, session: stubSession(),
                                                 render: { _ in "<html><body><img></body></html>" })

        #expect(page.normalizedHTML.contains("Mahler"))                  // we ended up on the right page
        #expect(page.normalizedHTML.contains("Alice Tully Hall"))
        #expect(page.finalURL == lincoln)
        #expect(page.followedTicketLinkFrom == ensemble)                 // and we can SAY so to Dan
        #expect(PageNormalizer.carriesReadableContent(page.normalizedHTML))
    }

    // It must not hop from the page it hopped TO: one hop, then stop. A ticketing page that links to
    // another ticketing page is not an invitation to crawl the internet on Dan's behalf.
    @Test func theHopHappensOnceAndDoesNotKeepGoing() async throws {
        PageStubURLProtocol.reset()
        let a = "https://org.example/show"
        let b = "https://www.eventbrite.com/e/1"
        let c = "https://www.ticketmaster.com/e/2"
        PageStubURLProtocol.bodiesByURL = [
            a: "<html><body><a href=\"\(b)\">Buy Tickets</a></body></html>",
            b: "<html><body><a href=\"\(c)\">Buy Tickets</a></body></html>",   // still nothing to read
            c: "<html><body><h1>The listing nobody should reach</h1></body></html>",
        ]

        let page = try await SourceFetcher.fetch(URL(string: a)!, session: stubSession(),
                                                 render: { _ in "<html><body></body></html>" })

        // It hopped to B, found B unreadable too, and STOPPED. It did not chain on to C.
        #expect(!page.normalizedHTML.contains("nobody should reach"))
        // And because the hop bought nothing, it keeps the page Dan actually gave us and admits defeat,
        // rather than substituting a ticketing page that helps him no more than the original did.
        #expect(page.finalURL == a)
        #expect(page.followedTicketLinkFrom == nil)
        #expect(!PageNormalizer.carriesReadableContent(page.normalizedHTML))
    }

    // A page with nothing readable and NO ticket link stays honestly unreadable, rather than following
    // something at random. Reading the wrong page and presenting it as the lead is worse than admitting
    // we cannot read this one.
    @Test func withNoTicketLinkThePageStaysHonestlyUnreadable() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("<html><body><div>Home</div><div>Contact</div></body></html>".utf8)

        let page = try await SourceFetcher.fetch(url, session: stubSession(),
                                                 render: { _ in "<html><body><div>Home</div></body></html>" })

        #expect(page.followedTicketLinkFrom == nil)
        #expect(!PageNormalizer.carriesReadableContent(page.normalizedHTML))
    }

    // The hash is the cost model. A page whose CONTENT has not changed must hash the same even though
    // its bytes differ, because sites churn whitespace, script nonces and analytics blobs on every
    // request. If the hash moved on every fetch, the AI would re-read every source every day forever
    // and the "skip unchanged pages" saving would silently be zero.
    @Test func theHashIgnoresChurnButNoticesRealChanges() {
        let monday = PageNormalizer.normalize("""
        <script>window.nonce="abc123";</script>
        <div>  Aurora   Strings  </div>
        """)
        let tuesday = PageNormalizer.normalize("""
        <script>window.nonce="zzz999";</script>
        <div>Aurora Strings</div>
        """)
        #expect(PageNormalizer.contentHash(monday) == PageNormalizer.contentHash(tuesday))

        let wednesday = PageNormalizer.normalize("<div>Aurora Strings</div><div>Vega Quartet</div>")
        #expect(PageNormalizer.contentHash(monday) != PageNormalizer.contentHash(wednesday))
    }

    // Every failure is NAMED. A source that 404s, rate-limits us, or serves a PDF must be visibly
    // broken, never silently empty: a dead source and a quiet off-season look identical otherwise, and
    // the spike found the quiet off-season is the NORMAL state (5 of 7 real sites).
    @Test func anHTTPErrorIsNamedNotSwallowed() async {
        for code in [401, 403, 404, 429, 500] {
            PageStubURLProtocol.reset()
            PageStubURLProtocol.status = code
            await #expect(throws: SourceFetchError.http(code)) {
                _ = try await SourceFetcher.fetch(url, session: stubSession())
            }
        }
    }

    @Test func aPageThatIsNotHTMLIsNamedRatherThanParsedAsOne() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.contentType = "application/pdf"
        PageStubURLProtocol.body = Data("%PDF-1.4".utf8)

        await #expect(throws: SourceFetchError.notHTML("application/pdf")) {
            _ = try await SourceFetcher.fetch(url, session: stubSession())
        }
    }

    // The real case from the #770 spike: thirdstreetmusicschool.org/events answers HTTP 200 on a
    // DIFFERENT DOMAIN (thirdstreet.nyc), serving a homepage. Guessing by convention, that reads as a
    // healthy fetch of an events page that happens to have no events. It is not. The recorded URL is
    // wrong and Dan has to be told, not left with a source that quietly reports nothing forever.
    @Test func aRedirectToADifferentSiteIsAnErrorNotAQuietSuccess() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.finalURL = "https://www.thirdstreet.nyc/"
        PageStubURLProtocol.body = Data("<html><body>homepage</body></html>".utf8)

        await #expect(throws: SourceFetchError.redirectedAway("www.thirdstreet.nyc")) {
            _ = try await SourceFetcher.fetch(URL(string: "https://thirdstreetmusicschool.org/events")!,
                                              session: stubSession())
        }
    }

    // ...but the ordinary redirects every site does (adding www, forcing https, appending a slash,
    // moving /calendar to /calendar-tickets) are NOT a different site and must not trip the guard.
    // Bargemusic really does redirect /calendar to www.bargemusic.org/calendar-tickets/.
    @Test func anOrdinaryWWWOrPathRedirectIsFine() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.finalURL = "https://www.bargemusic.org/calendar-tickets/"
        PageStubURLProtocol.body = Data("<html><body><td>11</td></body></html>".utf8)

        let page = try await SourceFetcher.fetch(URL(string: "https://bargemusic.org/calendar")!,
                                                 session: stubSession())
        #expect(page.finalURL == "https://www.bargemusic.org/calendar-tickets/")
    }

    @Test func aTransportFailureIsNamedTooRatherThanBecomingAnEmptyPage() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportError = URLError(.timedOut)

        await #expect(throws: SourceFetchError.unreachable) {
            _ = try await SourceFetcher.fetch(url, session: stubSession())
        }
    }
}

// The pinned page is the exact file the agent reads. It must live FLAT in the handoff directory (the
// #321 guard) and its name must be derived safely: a source id is data, and data must never be able to
// reach outside the folder it is written into.
@Suite("Scout page pin (#799)")
struct ScoutPagePinTests {
    @Test func theFileIsFlatInTheHandoffDirectory() {
        let url = ScoutPagePin.url(forSourceId: "bargemusic")
        #expect(url.deletingLastPathComponent() == StoreLocation.handoffDirectory)
        #expect(url.lastPathComponent == "overture-scout-page-bargemusic.html")
    }

    // A source id ultimately traces back to a URL Dan pasted. A crafted one must not be able to write
    // outside the handoff directory or overwrite another handoff file. This is cheap to enforce and
    // catastrophic to get wrong, so it is enforced at the one place the name is built.
    @Test func aHostileSourceIdCannotEscapeTheHandoffDirectory() {
        for nasty in ["../../etc/passwd", "a/b", "..", "with space", "UPPER/../x"] {
            let url = ScoutPagePin.url(forSourceId: nasty)
            #expect(url.deletingLastPathComponent() == StoreLocation.handoffDirectory)
            #expect(!url.lastPathComponent.contains("/"))
            #expect(!url.lastPathComponent.contains(".."))
        }
    }

    @Test func distinctSourcesGetDistinctFiles() {
        #expect(ScoutPagePin.url(forSourceId: "a") != ScoutPagePin.url(forSourceId: "b"))
    }
}
