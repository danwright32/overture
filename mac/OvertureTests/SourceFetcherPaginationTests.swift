import Foundation
import Testing

// #858. The app now walks a calendar's OWN month index and reads four months, not just the one the
// site happened to land you on.
//
// The four pages are stitched into ONE pinned document with ONE hash, and that is not tidiness: the
// listing SET must be determined by bytes the APP fetched and hashed (`SourceFetcher.swift:4-11`),
// because that set is what re-keys prospects and drives "was this show cancelled?". Four pages the app
// fetched and hashed together preserve that property exactly. Four pages an AI wandered off to find
// would destroy it.
@Suite("Reading four months of a calendar, not just the one you land on (#858)", .sharesTheNetworkStub)
struct SourceFetcherPaginationTests {

    private let base = "https://www.kaufmanmusiccenter.org/mch/calendar/"

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // Enough visible text to clear `thinTextFloor`, so these pages are not refused as unreadable shells.
    private func monthPage(_ label: String, shows: [String]) -> String {
        let index = ["2026/07/", "2026/08/", "2026/09/", "2026/10/", "2026/11/"]
            .map { "<option value=\"https://www.kaufmanmusiccenter.org/mch/calendar/\($0)\">\($0)</option>" }
            .joined()
        let listings = shows
            .map { "<div><a href=\"/mch/event/\($0.lowercased())\">\($0)</a> 7:30 pm</div>" }
            .joined()
        return """
        <html><body>
        <h1>Merkin Hall Calendar \(label)</h1>
        <select>\(index)</select>
        \(listings)
        <p>Kaufman Music Center presents concerts at Merkin Hall on the Upper West Side of Manhattan,
        with tickets, discounts, directions and rental spaces available on this site all season long.</p>
        </body></html>
        """
    }

    private func serveKaufman() {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.bodiesByURL = [
            base: monthPage("July 2026", shows: ["Immortal Gifts"]),
            base + "2026/08/": monthPage("August 2026", shows: ["Summer Serenade"]),
            base + "2026/09/": monthPage("September 2026", shows: ["Autumn Opening"]),
            base + "2026/10/": monthPage("October 2026", shows: ["PUBLIQuartet", "Orli Shaham"]),
            base + "2026/11/": monthPage("November 2026", shows: ["Should Not Be Read"]),
        ]
    }

    private func july2026() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 13
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // Pagination is OFF unless asked for: `SourceFetcher.fetch` with no horizon reads exactly one page.
    //
    // #1210 note: the scout now DOES ask for four months (it passes CalendarMonthIndex.defaultHorizon),
    // and the watchlist reconcile is protected on that paginating path by the wired sweep-coverage guard
    // (a short stitched read downgrades to incompleteExtraction and can cancel nothing, proven end to end
    // in StitchedSweepIngestWiringTests), NOT by refusing to paginate. So this test no longer asserts
    // anything about the watchlist; it pins the raw one-page default that a caller gets when it names no
    // horizon.
    //
    // Asserted on the REQUESTS, not the result: a document-shaped assertion would pass happily while
    // three extra fetches went out behind it.
    @Test func fetchWithNoHorizonReadsExactlyOnePage() async throws {
        serveKaufman()

        _ = try await SourceFetcher.fetch(URL(string: base)!, session: stubSession())

        #expect(PageStubURLProtocol.requestedURLs == [base])
    }

    // Four months, in one document, from the site's own index.
    @Test func askedForFourMonthsItReadsFourMonths() async throws {
        serveKaufman()

        let page = try await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                                 monthHorizon: 4, now: july2026())

        #expect(page.monthsRead == ["2026-07", "2026-08", "2026-09", "2026-10"])
        #expect(page.normalizedHTML.contains("Immortal Gifts"))     // July, the page we landed on
        #expect(page.normalizedHTML.contains("Autumn Opening"))     // September, which we never saw before
        #expect(page.normalizedHTML.contains("PUBLIQuartet"))       // October, the richest month
        #expect(page.normalizedHTML.contains("Orli Shaham"))
    }

    // The horizon is a hard cap. November is in the index, is in the future, and must NOT be read.
    @Test func itStopsAtTheHorizonEvenThoughMoreMonthsAreOffered() async throws {
        serveKaufman()

        let page = try await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                                 monthHorizon: 4, now: july2026())

        #expect(!page.normalizedHTML.contains("Should Not Be Read"))
        #expect(!PageStubURLProtocol.requestedURLs.contains(base + "2026/11/"))
    }

    // THE FAILURE PATH. October 404s while the other three answer.
    //
    // A silently shorter sweep is the whole danger of this feature: fewer shows come back, and on the
    // watchlist path that reads as "those shows were cancelled". So a month we could not read is NAMED,
    // never merely absent, and the three months we DID read still come back rather than the lead dying
    // whole. "A dead run and a broken calendar must never look alike."
    @Test func aMonthThatCannotBeReadIsNamedRatherThanSilentlyMissing() async throws {
        serveKaufman()
        PageStubURLProtocol.statusByURL = [base + "2026/10/": 404]

        let page = try await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                                 monthHorizon: 4, now: july2026())

        #expect(page.monthsRead == ["2026-07", "2026-08", "2026-09"])
        #expect(page.monthsUnread == ["2026-10"])          // said out loud, not dropped
        #expect(page.normalizedHTML.contains("Autumn Opening"))   // what we could read, we kept
        #expect(!page.normalizedHTML.contains("PUBLIQuartet"))
    }

    // The hash is the cost model (`SourceFetcher.swift:205-213`). Kaufman really does rotate a token on
    // every request, verified on the live site:
    //
    //     <input type="hidden" name="meta" value="yDVL2BYFV0F8zVgk/GIT52Oe...">   (fetch 1)
    //     <input type="hidden" name="meta" value="f0hGd3nui6KCgUCwMSJzfqde...">   (fetch 2)
    //
    // It lands in a `value` attribute, which #892 now KEEPS. If that nonce reached the hash, every one of
    // the four pages would look changed on every single fetch, the "skip unchanged pages" saving would be
    // zero, and Dan would pay for an AI re-read of four pages every day forever. It does not reach the
    // hash, because `contentProjection` is visible text plus `href` values only. Locked here across all
    // four stitched months, because pagination is what makes the bill four times as large.
    @Test func aRotatingTokenOnEveryMonthCannotMoveTheStitchedHash() async throws {
        func fetchOnce(nonce: String) async throws -> String {
            serveKaufman()
            for (url, body) in PageStubURLProtocol.bodiesByURL {
                PageStubURLProtocol.bodiesByURL[url] =
                    body.replacingOccurrences(of: "<body>",
                                              with: "<body><input name=\"meta\" value=\"\(nonce)\">")
            }
            return try await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                                 monthHorizon: 4, now: july2026()).contentHash
        }

        #expect(try await fetchOnce(nonce: "yDVL2BYFV0F8zVgk") == (try await fetchOnce(nonce: "f0hGd3nui6KCgUCw")))
    }

    // ...but a real change in a LATER month must still be noticed, or the whole point of reading four
    // months is lost: October's listings could change all season and the app would never re-read it.
    @Test func aChangeInALaterMonthStillMovesTheHash() async throws {
        serveKaufman()
        let before = try await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                                   monthHorizon: 4, now: july2026()).contentHash

        serveKaufman()
        PageStubURLProtocol.bodiesByURL[base + "2026/10/"] =
            monthPage("October 2026", shows: ["PUBLIQuartet", "Orli Shaham", "A Newly Added Concert"])
        let after = try await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                                  monthHorizon: 4, now: july2026()).contentHash

        #expect(before != after)
    }

    // A page that is not a calendar is not paginated, however many months are asked for. Dan pastes
    // single show pages and homepages, and none of them should start fetching extra pages.
    @Test func aPageWithNoMonthIndexIsFetchedOnceEvenWithAHorizon() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.bodiesByURL = [
            "https://example.org/show": """
            <html><body><h1>Immortal Gifts</h1>
            <p>A concert at Merkin Hall on October 3rd, 2026, with tickets available at the box office
            and a full programme of chamber music running through the evening for all who attend.</p>
            </body></html>
            """,
        ]

        _ = try await SourceFetcher.fetch(URL(string: "https://example.org/show")!, session: stubSession(),
                                          monthHorizon: 4, now: july2026())

        #expect(PageStubURLProtocol.requestedURLs == ["https://example.org/show"])
    }

    // #900. A calendar that pages by QUERY (?month=2026-10) instead of by path. We cannot follow it, so
    // one page is all we get, exactly as before. The change is that the page now says so.
    //
    // Asserted on the REQUESTS as well as the result, because the tempting bug here is the opposite of
    // the old one: having NAMED October, start guessing at a URL for it. The original #858 premise did
    // exactly that and was wrong (its assumed /P20 answers 200 with page one's content, so the guesser
    // would have fetched the same page four times and called it a complete sweep). Naming a month is not
    // a licence to invent its address.
    @Test func aCalendarWeCannotPageThroughNamesItsMonthsAndStillFetchesOnce() async throws {
        let options = ["07": "July", "08": "August", "09": "September", "10": "October"]
            .sorted { $0.key < $1.key }
            .map { "<option value=\"?month=2026-\($0.key)\">\($0.value) 2026</option>" }
            .joined()
        PageStubURLProtocol.reset()
        PageStubURLProtocol.bodiesByURL = [
            "https://merkin.example.org/calendar": """
            <html><body><h1>Calendar</h1><select>\(options)</select>
            <div><a href="/event/immortal-gifts">Immortal Gifts</a> July 18, 7:30 pm</div>
            <p>Concerts at Merkin Hall on the Upper West Side of Manhattan, with tickets, discounts,
            directions and rental spaces available on this site throughout the whole season.</p>
            </body></html>
            """,
        ]

        let page = try await SourceFetcher.fetch(URL(string: "https://merkin.example.org/calendar")!,
                                                 session: stubSession(), monthHorizon: 4, now: july2026())

        #expect(page.monthsUnreachable == ["2026-08", "2026-09", "2026-10"])
        #expect(page.monthsRead.isEmpty)                                    // nothing was stitched
        #expect(PageStubURLProtocol.requestedURLs == ["https://merkin.example.org/calendar"])
    }

    // ...and the verdict costs nothing. It is metadata: it must not touch the document or move the hash.
    //
    // The hash is the cost model. If noticing an unreachable month moved it, every calendar of this shape
    // would look changed on every check and buy a full AI re-read, every day, forever, and nothing would
    // look broken. So the SAME page is fetched down both paths (the watchlist's, which never paginates
    // and never looks; the lead's, which does both) and the bytes and the hash must be identical. Only
    // the metadata may differ. This also pins the watchlist path itself: it stays blind to all of this,
    // which is what keeps a stitched page away from the reconcile that can cancel Dan's shows (#897).
    @Test func noticingAnUnreachableMonthMovesNeitherTheDocumentNorTheHash() async throws {
        func fetchOnce(monthHorizon: Int) async throws -> FetchedPage {
            PageStubURLProtocol.reset()
            PageStubURLProtocol.bodiesByURL = [
                "https://merkin.example.org/calendar": """
                <html><body><h1>Calendar</h1>
                <select><option value="?month=2026-10">October 2026</option></select>
                <div><a href="/event/immortal-gifts">Immortal Gifts</a> July 18, 7:30 pm</div>
                <p>Concerts at Merkin Hall on the Upper West Side of Manhattan, with tickets, discounts,
                directions and rental spaces available on this site throughout the whole season.</p>
                </body></html>
                """,
            ]
            return try await SourceFetcher.fetch(URL(string: "https://merkin.example.org/calendar")!,
                                                 session: stubSession(), monthHorizon: monthHorizon,
                                                 now: july2026())
        }

        let watchlist = try await fetchOnce(monthHorizon: 1)
        let lead = try await fetchOnce(monthHorizon: 4)

        #expect(lead.monthsUnreachable == ["2026-10"])          // the lead path sees it...
        #expect(watchlist.monthsUnreachable.isEmpty)            // ...and the watchlist path never looks
        #expect(lead.normalizedHTML == watchlist.normalizedHTML)
        #expect(lead.contentHash == watchlist.contentHash)
    }
}
