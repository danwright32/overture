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
    // #858: a month page that 404s while the others answer, and a count of what was actually asked for.
    // The count is what proves the watchlist still fetches ONE page: an assertion about the returned
    // document could pass while three extra requests went out behind it.
    nonisolated(unsafe) static var statusByURL: [String: Int] = [:]
    nonisolated(unsafe) static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let e = Self.transportError {
            client?.urlProtocol(self, didFailWithError: e)
            return
        }
        let requested = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(requested)
        let url = URL(string: Self.finalURL ?? request.url!.absoluteString)!
        var headers: [String: String] = [:]
        if let ct = Self.contentType { headers["Content-Type"] = ct }
        let status = Self.statusByURL[requested] ?? Self.status
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let body = Self.bodiesByURL[requested].map { Data($0.utf8) } ?? Self.body
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        status = 200; body = Data(); contentType = "text/html; charset=utf-8"
        finalURL = nil; transportError = nil; bodiesByURL = [:]
        statusByURL = [:]; requestedURLs = []
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

    // #972: the app has no App Transport Security exception, so macOS refuses a cleartext http request
    // outright and the source lands on the `unreachable` failure. That reads as "their site is down" when
    // the site is perfectly up: of the three failing sources after the #359 backfill, Rainer Crosett and
    // The Cell Theatre were BOTH just stored with an http URL and both answer https with a 200. So ask for
    // https. Strictly an improvement, never a regression: a cleartext fetch cannot succeed today, so no
    // source that works now can break. The assertion is on what was REQUESTED, not on what came back,
    // because a test that only checked the returned page would still pass with the upgrade wired out.
    @Test func anInsecureSourceIsFetchedOverHTTPSKeepingItsPathAndQuery() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("""
        <html><body><table><tr><td><div>11</div>
        <a href="https://org.example/show/a">Aurora Strings</a></td></tr></table></body></html>
        """.utf8)

        _ = try await SourceFetcher.fetch(URL(string: "http://org.example/events?view=list")!,
                                          session: stubSession())

        #expect(PageStubURLProtocol.requestedURLs.first == "https://org.example/events?view=list")
        #expect(!PageStubURLProtocol.requestedURLs.contains { $0.hasPrefix("http://") })
    }

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

    // MARK: - #1543: a broken handshake is not a dead link

    private func fetchFailure(given transport: Error) async -> SourceFetchError? {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportError = transport
        do {
            _ = try await SourceFetcher.fetch(url, session: stubSession(), render: { _ in "" })
            return nil
        } catch let error as SourceFetchError {
            return error
        } catch {
            return nil
        }
    }

    // Dan's Dinu Mihailescu row. The site answers plain http with 200 and 37KB of HTML; its https endpoint
    // sends a fatal TLS alert as soon as the client offers ALPN, which every real client does. #972
    // predicted this source by name ("a genuinely broken TLS handshake, which no scheme fixes and which
    // SHOULD keep failing") and it does keep failing, correctly. What was wrong is only what it SAID: the
    // same "Couldn't reach that page." as a dead domain, which sends Dan to fix or retire a live site.
    @Test func aBrokenTLSHandshakeIsNamedRatherThanCalledUnreachable() async {
        let failure = await fetchFailure(given: URLError(.secureConnectionFailed))

        #expect(failure == .secureConnectionFailed)
    }

    // The rest of the TLS family lands in the same place. An expired or untrusted certificate is the same
    // fact from Dan's side: the site is there, its secure connection cannot be established, and nothing he
    // does to the address will change that.
    @Test func theRestOfTheCertificateFamilyIsTheSameHonestFailure() async {
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot] {
            let failure = await fetchFailure(given: URLError(code))
            #expect(failure == .secureConnectionFailed, "\(code) should read as a broken secure connection")
        }
    }

    // The guard that keeps the new sentence honest. A timeout and a dead domain are still `unreachable`,
    // because for those the sentence is TRUE and the response Dan owes is different. Widening the TLS case
    // to swallow ordinary transport failures would trade one wrong sentence for another.
    @Test func anOrdinaryTransportFailureIsStillJustUnreachable() async {
        for code in [URLError.Code.timedOut, .cannotFindHost, .notConnectedToInternet,
                     .networkConnectionLost] {
            let failure = await fetchFailure(given: URLError(code))
            #expect(failure == .unreachable, "\(code) should stay unreachable")
        }
    }

    // A transport error that is not a URLError at all (a URLSession can surface others) must fail SAFE on
    // the generic sentence rather than claim a TLS problem it has no evidence for.
    @Test func anUnrecognizedTransportErrorFallsBackToUnreachable() async {
        struct Odd: Error {}
        let failure = await fetchFailure(given: Odd())

        #expect(failure == .unreachable)
    }

    // The reader itself, at the boundary the feed adapters reach it by. None of them catch their own
    // session errors, so a raw URLError from an OperaAmerica or VenueTix host arrives untyped at
    // ScoutService and is read here. Without this the same broken handshake would read honestly on an html
    // source and as a dead link on a feed one, which is the drift the shared reader exists to prevent.
    @Test func theSameReaderNamesAnUntypedTransportErrorFromAFeedHost() {
        #expect(SourceFetchError.transport(URLError(.secureConnectionFailed)) == .secureConnectionFailed)
        #expect(SourceFetchError.transport(URLError(.timedOut)) == .unreachable)
        // An already typed error is never re-read as a transport failure: a 404 stays a 404.
        #expect(SourceFetchError.transport(SourceFetchError.http(404)) == .unreachable)
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

    // #1056: the candidate set is a small, fixed list of calendar paths taken off the site ROOT, with the
    // query and fragment dropped. No crawling, no growth with the page's own depth.
    @Test func siblingCandidatesAreABoundedSetOffTheSiteRoot() {
        let url = URL(string: "https://www.nyys.org/some/deep/programs?view=list#top")!
        let candidates = SiblingCalendar.candidates(for: url).map(\.absoluteString)
        #expect(candidates == [
            "https://www.nyys.org/events/",
            "https://www.nyys.org/calendar/",
            "https://www.nyys.org/events",
            "https://www.nyys.org/calendar",
        ])
    }

    // #1056: the set never re-tries the exact page we already failed to read. A watched page at /events/
    // (whether or not it has a trailing slash) drops both /events forms from the candidates.
    @Test func theSiblingSetNeverRetriesThePageWeAlreadyFailedToRead() {
        let candidates = SiblingCalendar.candidates(for: URL(string: "https://org.example/events/")!)
            .map(\.absoluteString)
        #expect(candidates == [
            "https://org.example/calendar/",
            "https://org.example/calendar",
        ])
    }

    // #1056 the whole point: NYYS's watched URL is a JavaScript shell that even a browser render cannot
    // read, but the org keeps a plain-HTML calendar at /events/. Rather than declaring the source
    // unreadable, the fetch tries the sibling path and reads it, and it SAYS which page it fell back to.
    @Test func aJavaScriptShellFallsBackToAReadablePlainSibling() async throws {
        PageStubURLProtocol.reset()
        let watched = "https://org.example/programs"
        let sibling = "https://org.example/events/"
        PageStubURLProtocol.bodiesByURL = [
            watched: """
            <html><body>
            <div><a href="/">Home</a> <a href="/about">About</a> <a href="/contact">Contact</a></div>
            <div>Proudly created with Wix.com</div>
            </body></html>
            """,
            sibling: """
            <html><body><h1>Upcoming Events</h1>
            <div><h3>October 3, 2026</h3><p>New York Youth Symphony at Carnegie Hall.</p></div>
            <div><h3>November 14, 2026</h3><p>Works of Brahms and Dvorak.</p></div>
            </body></html>
            """,
        ]

        // The watched page stays a shell even after a browser render, so the sibling is the only way in.
        let page = try await SourceFetcher.fetch(URL(string: watched)!, session: stubSession(),
                                                 render: { _ in "<html><body><div>Loading</div></body></html>" })

        #expect(PageNormalizer.carriesReadableContent(page.normalizedHTML))
        #expect(page.normalizedHTML.contains("October 3"))
        #expect(page.finalURL == sibling)                 // we ended up on the readable sibling
        #expect(page.readableSiblingOf == watched)        // and we can SAY which page we fell back from
    }

    // #1056 failure path: when the watched page is unreadable AND every sibling guess 404s, the source
    // stays honestly unreadable rather than being papered over. A missing sibling is expected (we are
    // guessing paths), so it is swallowed, but the overall verdict is still the loud one.
    @Test func whenNoSiblingReadsTheSourceStaysHonestlyUnreadable() async throws {
        PageStubURLProtocol.reset()
        let watched = "https://org.example/programs"
        PageStubURLProtocol.bodiesByURL = [watched: """
            <html><body>
            <div><a href="/">Home</a> <a href="/about">About</a> <a href="/contact">Contact</a></div>
            <div>Proudly created with Wix.com</div>
            </body></html>
            """]
        PageStubURLProtocol.statusByURL = [
            "https://org.example/events/": 404,
            "https://org.example/calendar/": 404,
            "https://org.example/events": 404,
            "https://org.example/calendar": 404,
        ]

        let page = try await SourceFetcher.fetch(URL(string: watched)!, session: stubSession(),
                                                 render: { _ in "<html><body><div>Loading</div></body></html>" })

        #expect(!PageNormalizer.carriesReadableContent(page.normalizedHTML))
        #expect(page.readableSiblingOf == nil)
        #expect(page.finalURL == watched)                 // it kept the page Dan actually gave us
    }

    // #1056 cost guard: a page that reads on its own must never fire a single sibling request. The probe
    // is a rescue for unreadable pages only, not something the watchlist pays for on every healthy source.
    @Test func aReadablePageNeverProbesSiblings() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.body = Data("""
        <html><body><h1>Concerts for July 2026</h1>
        <table><tr><td><div>11</div><a href="/c/a">Immortal Gifts: Mozart and Schubert</a></td></tr></table>
        </body></html>
        """.utf8)

        let page = try await SourceFetcher.fetch(URL(string: "https://org.example/events")!,
                                                 session: stubSession(),
                                                 render: { _ in "" })

        #expect(page.readableSiblingOf == nil)
        #expect(PageStubURLProtocol.requestedURLs == ["https://org.example/events"])
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

    // A site's own navigation is content, and we were deleting it. Verified on the live Kaufman Music
    // Center calendar (2026-07-13): the way to reach its other twenty-four months is not an `href` at
    // all, it is `<option value="https://.../2026/10/">`. `value` was not in the allow-list, so every
    // one of those month links was stripped before anything could read it. Nothing failed; the pinned
    // page simply held less than the site served.
    //
    // You cannot follow navigation that has already been deleted from the bytes you kept, which is why
    // multi-page calendars (#858) could not be built on top of this.
    // The markup here is COPIED VERBATIM from what Kaufman actually serves, indentation, line breaks,
    // bare `selected` and all. That is deliberate. The last bug in this normalizer survived a green
    // suite precisely because every fixture had been tidied onto one line, so the fixtures agreed with
    // the code and both disagreed with the web. A real `<option>` carries a boolean attribute with no
    // `="value"` after the one we want, and its text sits on the next line; a tidied fixture proves
    // nothing about either.
    @Test func normalizingKeepsTheLinksASiteUsesToReachItsOwnOtherPages() {
        let html = """
        <select>
            <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/07/" selected>
            July 2026
        </option>
            <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/10/">
            October 2026
        </option>
        </select>
        <link rel="next" href="/mch/calendar/2026/08/">
        """
        let out = PageNormalizer.normalize(html)

        #expect(out.contains("value=\"https://www.kaufmanmusiccenter.org/mch/calendar/2026/10/\""))
        #expect(out.contains("value=\"https://www.kaufmanmusiccenter.org/mch/calendar/2026/07/\""))
        #expect(out.contains("rel=\"next\""))
        #expect(out.contains("October 2026"))
    }

    // The one real risk in keeping those attributes, stated and then locked rather than believed: the
    // hash must not move. `contentProjection` is the visible text plus `href` values, and the visible
    // text has every tag stripped out of it, so an attribute can never reach either half. Keeping more
    // attributes therefore cannot churn the hash, cannot break the "skip unchanged pages" saving, and
    // cannot cost a single token.
    //
    // If a later change ever routes attributes into the projection, this is the test that says so.
    @Test func keepingNavigationAttributesCannotMoveTheContentHash() {
        let bare = PageNormalizer.normalize("""
        <select><option>October 2026</option></select>
        <a href="/c/1">Immortal Gifts</a>
        """)
        let navigable = PageNormalizer.normalize("""
        <select><option value="/calendar/2026/10/">October 2026</option></select>
        <a rel="bookmark" title="Immortal Gifts" href="/c/1">Immortal Gifts</a>
        """)
        #expect(PageNormalizer.contentHash(bare) == PageNormalizer.contentHash(navigable))
    }

    // Why `<head>` stays stripped, which is the question #892 left open.
    //
    // Preserving it looks like the same idea (a `<link rel="next">` lives up there), but it is the
    // opposite: `<head>` is full of ASSET hrefs, and `contentProjection` reads every href. The live
    // Kaufman page serves `<link rel="stylesheet" href="/ui/css/main.2026-07-09-13-37-08.css">`, whose
    // URL carries the site's BUILD TIMESTAMP. Keep the head and that timestamp lands in the hash, so
    // every CSS redeploy makes an unchanged calendar look changed and buys a full AI re-read of it.
    //
    // That is the exact silent 10x this file's hash comment exists to prevent, so it gets a test and not
    // a comment. A stylesheet is not a listing; the head's hrefs are not content.
    @Test func aRedeployedStylesheetInTheHeadCannotMakeAnUnchangedCalendarLookChanged() {
        func page(cssBuild: String) -> String {
            PageNormalizer.normalize("""
            <html>
            <head><link rel="stylesheet" href="/ui/css/main.\(cssBuild).css"></head>
            <body><a href="/c/1">Immortal Gifts</a></body>
            </html>
            """)
        }
        #expect(PageNormalizer.contentHash(page(cssBuild: "2026-07-09-13-37-08"))
                == PageNormalizer.contentHash(page(cssBuild: "2026-08-22-09-04-11")))
    }

    // The normalizer collapses ALL whitespace (including newlines) to keep the change hash stable, which
    // can leave a whole page on ONE line. The detached reader's line-oriented Read tool cannot page past
    // a single oversized line, so a big single-line page (Chain Theatre: 82KB, zero newlines) is read
    // only in part and loops on incomplete_extraction forever, re-read on every scout and never clearing.
    // pageableForReading re-introduces line breaks (for the on-disk pin only) so the reader's offset
    // paging covers the whole page: a tag-dense page becomes one line per element, none of them oversized.
    @Test func pageableForReadingBreaksAGiantSingleLineIntoReadableLines() {
        let oneGiantLine = String(repeating: "<div>Aurora Strings, Oct 3</div>", count: 6000)
        #expect(!oneGiantLine.contains("\n"))   // the shape the normalizer produces

        let pageable = PageNormalizer.pageableForReading(oneGiantLine)
        let lines = pageable.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.count <= PageNormalizer.readerLineWidth })
        // Only whitespace was added: strip whitespace from both and the bytes are identical, so the reader
        // sees exactly the same markup and text, and no non-whitespace can have shifted into the hash.
        #expect(pageable.filter { !$0.isWhitespace } == oneGiantLine.filter { !$0.isWhitespace })
    }

    // The safety backstop: a run of text with no tag boundaries longer than the reader can take (a
    // pathological page, not a normal calendar) is still hard-wrapped so no single line is unreadable.
    @Test func pageableForReadingHardWrapsALongTaglessRun() {
        let blob = String(repeating: "x", count: PageNormalizer.readerLineWidth * 3 + 17)

        let pageable = PageNormalizer.pageableForReading(blob)
        let lines = pageable.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.allSatisfy { $0.count <= PageNormalizer.readerLineWidth })
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

// #972: an http source is upgraded to https before the fetch. The comment on `secured` rests its whole
// "cannot regress anything" argument on two facts, both pinned here: a working (https) source is handed
// back untouched, and a non-http scheme is left alone, so the only URL this ever rewrites is a cleartext
// one that (with no ATS exception) could not have succeeded anyway. #982: previously untested.
@Suite("Scheme upgrade (#972)")
struct SecuredSchemeTests {
    @Test func cleartextHttpIsUpgradedToHttps() {
        #expect(SourceFetcher.secured(URL(string: "http://rainercrosett.com/events")!)
                == URL(string: "https://rainercrosett.com/events")!)
    }

    // The scheme match is case-insensitive, so a stored "HTTP://" is upgraded too rather than slipping
    // through as if it were already secure.
    @Test func anUppercaseHttpSchemeIsAlsoUpgraded() {
        #expect(SourceFetcher.secured(URL(string: "HTTP://example.org/x")!).scheme == "https")
    }

    // The path, query and fragment survive the swap: only the scheme changes.
    @Test func onlyTheSchemeChanges() {
        #expect(SourceFetcher.secured(URL(string: "http://ex.org/a/b?q=1#f")!)
                == URL(string: "https://ex.org/a/b?q=1#f")!)
    }

    // The load-bearing half of "cannot regress anything": a source that already works (https) is returned
    // byte-for-byte, and a non-http scheme (mailto, ftp) is left alone rather than mangled into an https URL.
    @Test func httpsAndOtherSchemesPassThroughUntouched() {
        let https = URL(string: "https://carnegiehall.org/calendar")!
        #expect(SourceFetcher.secured(https) == https)
        let mailto = URL(string: "mailto:press@example.org")!
        #expect(SourceFetcher.secured(mailto) == mailto)
        let ftp = URL(string: "ftp://files.example.org/x")!
        #expect(SourceFetcher.secured(ftp) == ftp)
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

    // #982: safeName's comment claims the mapping "only collapses characters, never whole ids: an empty
    // result still gets a stable stand-in". The stand-in branch fires only when every character was
    // dropped, which happens for the empty id (each character maps to itself or a dash, never to nothing).
    // Without it an empty id would build "overture-scout-page-.html" and every empty-id page would collide.
    @Test func anEmptySourceIdGetsAStableStandInName() {
        #expect(ScoutPagePin.safeName("") == "unnamed")
        // A non-empty id is never wholesale-replaced by the stand-in: its characters are only collapsed.
        #expect(ScoutPagePin.safeName("a/b") == "a-b")
        #expect(ScoutPagePin.safeName("!!!") != "unnamed")
    }
}
