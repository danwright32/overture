import Testing
import Foundation

// #1544: reading a site whose https is broken but whose plain http serves the page.
//
// Dan's Dinu Mihailescu source, probed live 2026-07-26: `http://dinumihailescu.com/concerts/` answers
// 200 with 37,418 bytes and no redirect, while its https endpoint kills the handshake the instant a
// client offers ALPN. #1543 made the row SAY that honestly. This makes the page readable.
//
// It costs a real security control, so the shape was Dan's decision (2026-07-26) and he chose the narrow
// one: name the single host in the app's transport policy rather than open cleartext everywhere and rely
// on Overture's own code to be the only gate. The operating system keeps enforcing encryption for every
// other source on the watchlist, so a bug in the logic below cannot expose them.
//
// Two gates have to agree for a cleartext read to happen at all: the OS one (Info.plist) and the app's
// own (the rules in SourceFetcher). A permission granted in two places that can drift is the trap #887
// named, so the first test here pins them to each other rather than trusting either alone.
@Suite("Cleartext fallback for a broken handshake (#1544)", .serialized, .sharesTheNetworkStub)
struct CleartextFallbackTests {

    private let concerts = URL(string: "http://dinumihailescu.com/concerts/")!
    private let securedConcerts = "https://dinumihailescu.com/concerts/"
    private let cleartextConcerts = "http://dinumihailescu.com/concerts/"

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // Enough visible prose to clear the thin-text floor, so the page is not refused as an empty shell.
    private func concertPage() -> String {
        """
        <html><body>
        <h1>Concerts</h1>
        <div><a href="/concerts/brahms">Brahms Sonatas</a> October 14, 2026, 7:30 pm</div>
        <div><a href="/concerts/schubert">Schubert Evening</a> November 2, 2026, 8:00 pm</div>
        <p>Recitals and chamber music performances throughout the season, with programme notes,
        ticketing details and directions to each of the halls listed on this page.</p>
        </body></html>
        """
    }

    // MARK: - The two gates must name the same hosts

    // The OS half, pinned on the BUILT bundle rather than the source file, exactly as the single-instance
    // flag is (#1544 follows that precedent): a plist key no unit of logic exercises is otherwise verified
    // by nobody until it is wrong in Dan's hands.
    @Test func theBuiltBundleAllowsCleartextForExactlyTheHostsTheCodeAllows() {
        let bundle = Bundle(for: AppDelegate.self)
        let ats = bundle.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        let domains = Set((ats?["NSExceptionDomains"] as? [String: Any] ?? [:]).keys)

        #expect(domains == SourceFetcher.cleartextFallbackHosts,
                "the app's transport policy and its own fallback rule must name the same hosts")
    }

    // The decision Dan made, stated as a test so the narrow option cannot quietly become the broad one.
    // Turning this key on would open cleartext to every host on the watchlist and leave the whole
    // protection resting on the code below never being called wrong.
    @Test func theAppNeverOpensCleartextToEverything() {
        let bundle = Bundle(for: AppDelegate.self)
        let ats = bundle.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]

        #expect(ats?["NSAllowsArbitraryLoads"] as? Bool != true)
    }

    // MARK: - The fallback itself

    // The live case. https dies at the handshake, http serves the page, and Overture comes back with the
    // concerts instead of a failure.
    @Test func aBrokenHandshakeOnAStoredHttpAddressIsRetriedInTheClear() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [securedConcerts: URLError(.secureConnectionFailed)]
        PageStubURLProtocol.bodiesByURL = [cleartextConcerts: concertPage()]

        let page = try await SourceFetcher.fetch(concerts, session: stubSession(),
                                                 allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(page.normalizedHTML.contains("Brahms Sonatas"))
        // https was tried FIRST and the cleartext address only after it failed. Asserted on the requests,
        // because a result-shaped assertion would pass just as happily if it had gone straight to http.
        #expect(PageStubURLProtocol.requestedURLs == [securedConcerts, cleartextConcerts])
    }

    // A page anyone on the network could have altered in flight, feeding a reconcile where a source's
    // silence cancels shows. It is marked, so the row can say so and Dan can see which of his sources are
    // in that category.
    @Test func aPageReadInTheClearIsMarkedAsSuch() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [securedConcerts: URLError(.secureConnectionFailed)]
        PageStubURLProtocol.bodiesByURL = [cleartextConcerts: concertPage()]

        let page = try await SourceFetcher.fetch(concerts, session: stubSession(),
                                                 allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(page.wasReadInsecurely)
    }

    // An ordinary secure read must NOT be marked, or the warning means nothing.
    @Test func anOrdinarySecureReadIsNotMarked() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.bodiesByURL = [securedConcerts: concertPage()]

        let page = try await SourceFetcher.fetch(concerts, session: stubSession(),
                                                 allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(page.wasReadInsecurely == false)
        #expect(PageStubURLProtocol.requestedURLs == [securedConcerts])
    }

    // MARK: - The failure paths

    // BOTH halves broken. This must land on #1543's honest sentence and never on a false success: a
    // fallback that swallowed the second failure would report an empty page as a healthy read, which is
    // the exact lie the whole fetch design exists to prevent.
    @Test func whenBothSchemesFailTheHonestErrorSurvives() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [
            securedConcerts: URLError(.secureConnectionFailed),
            cleartextConcerts: URLError(.cannotConnectToHost),
        ]

        var caught: SourceFetchError?
        do {
            _ = try await SourceFetcher.fetch(concerts, session: stubSession(),
                                              allowTicketLinkHop: false, allowSiblingProbe: false)
        } catch let error as SourceFetchError {
            caught = error
        } catch {}

        #expect(caught == .secureConnectionFailed)
        #expect(PageStubURLProtocol.requestedURLs == [securedConcerts, cleartextConcerts])
    }

    // The cleartext address answering with a 404 is not a success either, and must not be reported as one.
    @Test func aCleartextRetryThatAnswersWithAnErrorIsStillAFailure() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [securedConcerts: URLError(.secureConnectionFailed)]
        PageStubURLProtocol.statusByURL = [cleartextConcerts: 404]

        var caught: SourceFetchError?
        do {
            _ = try await SourceFetcher.fetch(concerts, session: stubSession(),
                                              allowTicketLinkHop: false, allowSiblingProbe: false)
        } catch let error as SourceFetchError {
            caught = error
        } catch {}

        #expect(caught == .http(404))
    }

    // MARK: - The rules that keep this from becoming a general "try harder" path

    // Only a HANDSHAKE failure. A timeout means the site did not answer at all, and retrying it without
    // encryption is a downgrade bought for nothing.
    @Test func aTimeoutNeverTriggersACleartextRetry() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [securedConcerts: URLError(.timedOut)]
        PageStubURLProtocol.bodiesByURL = [cleartextConcerts: concertPage()]

        _ = try? await SourceFetcher.fetch(concerts, session: stubSession(),
                                           allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(PageStubURLProtocol.requestedURLs == [securedConcerts])
    }

    // A host the transport policy does not name cannot be read in the clear anyway (the OS would refuse
    // it), so trying is a wasted request that would also report a misleading second failure. The code gate
    // stops before it, which is what keeps the two gates honest about each other.
    @Test func aHostThatIsNotOnTheListIsNeverRetriedInTheClear() async {
        let other = URL(string: "http://someotherorg.example/events")!
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [
            "https://someotherorg.example/events": URLError(.secureConnectionFailed),
        ]
        PageStubURLProtocol.bodiesByURL = ["http://someotherorg.example/events": concertPage()]

        _ = try? await SourceFetcher.fetch(other, session: stubSession(),
                                           allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(PageStubURLProtocol.requestedURLs == ["https://someotherorg.example/events"])
    }

    // The rule that makes this safe to leave switched on: Overture only ever goes cleartext to an address
    // DAN HIMSELF stored as cleartext. A source he stored as https is never downgraded, whatever happens
    // to its handshake, so a site that quietly breaks its certificate one day cannot be silently demoted
    // to an unencrypted read.
    @Test func anAddressStoredAsHTTPSIsNeverDowngraded() async {
        let secureStored = URL(string: "https://dinumihailescu.com/concerts/")!
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [securedConcerts: URLError(.secureConnectionFailed)]
        PageStubURLProtocol.bodiesByURL = [cleartextConcerts: concertPage()]

        _ = try? await SourceFetcher.fetch(secureStored, session: stubSession(),
                                           allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(PageStubURLProtocol.requestedURLs == [securedConcerts])
    }

    // One retry, never a loop. Proven by the request list: exactly two addresses were ever asked for.
    @Test func theClearTextRetryHappensOnceAndOnlyOnce() async {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.transportErrorsByURL = [
            securedConcerts: URLError(.secureConnectionFailed),
            cleartextConcerts: URLError(.secureConnectionFailed),
        ]

        _ = try? await SourceFetcher.fetch(concerts, session: stubSession(),
                                           allowTicketLinkHop: false, allowSiblingProbe: false)

        #expect(PageStubURLProtocol.requestedURLs.count == 2)
    }

    // MARK: - Dan can see which sources are in this category

    // The flag has to reach the ROW, not just the page. A page fetched in the clear is one anyone on the
    // network could have altered in flight, and it feeds FeedReconcile, where a source's silence cancels
    // shows. Stamped on every successful fetch, including the free daily watch pass that never reads, so
    // it is current rather than frozen at whenever the last paid read happened.
    @MainActor
    @Test func aSourceFetchedInTheClearSaysSoOnItsRow() {
        let source = WatchedSource(sourceId: "dinu", orgName: "Dinu Mihailescu",
                                   listingsURL: cleartextConcerts, kind: .html)
        var page = FetchedPage(normalizedHTML: "<p>Concerts</p>", finalURL: cleartextConcerts,
                               contentHash: "abc")
        page.wasReadInsecurely = true

        _ = SourceCheck.decide(source: source, result: .success(page), depth: .watchOnly, now: Date())

        #expect(source.lastFetchWasInsecure)
        #expect(source.insecureFetchNote != nil)
    }

    // And it CLEARS itself the day the site fixes its certificate, with nobody having to notice. A warning
    // that outlives the thing it warns about teaches Dan to ignore the warnings that are still true.
    @MainActor
    @Test func theWarningClearsOnceTheSiteFixesItsSecureConnection() {
        let source = WatchedSource(sourceId: "dinu", orgName: "Dinu Mihailescu",
                                   listingsURL: cleartextConcerts, kind: .html)
        source.lastFetchWasInsecure = true
        let secure = FetchedPage(normalizedHTML: "<p>Concerts</p>", finalURL: securedConcerts,
                                 contentHash: "def")

        _ = SourceCheck.decide(source: source, result: .success(secure), depth: .watchOnly, now: Date())

        #expect(source.lastFetchWasInsecure == false)
        #expect(source.insecureFetchNote == nil)
    }

    // The guard and its wiring are two claims (#887): the note above is only true on screen if the sheet
    // actually draws it.
    @MainActor
    @Test func theSourcesSheetDrawsTheInsecureFetchNote() {
        let sourcesView = SourceGuardHelper.source("Overture/UI/SourcesView.swift")

        #expect(sourcesView.contains("source.insecureFetchNote"))
    }

    // Dan's call on review, 2026-07-26, and it restores a rule this sheet already had. Gold is the signal
    // colour for a source that has forfeited its ability to say a show is gone: work he can act on. A
    // broken certificate on somebody else's website is not work he can act on, at all. Dressing a fact he
    // can do nothing about as an alarm is exactly how #1428/#1472/#1498 taught the badge and these lines to
    // cry wolf, and a row that cries wolf trains him to skim the line that is genuinely urgent.
    //
    // It shipped gold in #1544 by my mistake, three lines under the comment stating this rule.
    @MainActor
    @Test func theInsecureFetchNoteIsDisclosedNotDressedAsAnAlarm() {
        let sourcesView = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        let block = SourceGuardHelper.propertyBody("if let insecure = source.insecureFetchNote {",
                                                   in: sourcesView)

        #expect(block?.contains("OVColor.ink") == true)
        #expect(block?.contains("OVColor.gold") == false,
                "a fact Dan cannot act on must not wear the colour reserved for work he can")
    }

    // The derived-address rule, tested where it actually bites. A month page inside a stitched calendar is
    // an address the APP built from the landing page's own index, not one Dan supplied, so it must never
    // be read in the clear even on the allowed host. The fallback lives on the entry point only, and this
    // is what proves it did not leak into the shared single-page path the stitch and the ticket hop use.
    @Test func aDerivedMonthPageIsNeverReadInTheClear() async {
        let base = "https://dinumihailescu.com/concerts/"
        let august = "https://dinumihailescu.com/concerts/2026/08/"
        let index = ["2026/08/"]
            .map { "<option value=\"https://dinumihailescu.com/concerts/\($0)\">\($0)</option>" }
            .joined()
        let landing = """
        <html><body><h1>Concerts July 2026</h1><select>\(index)</select>
        <div><a href="/concerts/brahms">Brahms Sonatas</a> July 14, 2026, 7:30 pm</div>
        <p>Recitals and chamber music throughout the season, with programme notes and ticketing
        details for each of the halls listed here across the whole of the coming year.</p>
        </body></html>
        """
        PageStubURLProtocol.reset()
        PageStubURLProtocol.bodiesByURL = [base: landing]
        PageStubURLProtocol.transportErrorsByURL = [august: URLError(.secureConnectionFailed)]

        var july = DateComponents()
        july.year = 2026; july.month = 7; july.day = 13
        july.timeZone = TimeZone(identifier: "America/New_York")
        let now = Calendar(identifier: .gregorian).date(from: july)!

        _ = try? await SourceFetcher.fetch(URL(string: base)!, session: stubSession(),
                                           allowTicketLinkHop: false, allowSiblingProbe: false,
                                           monthHorizon: 4, now: now)

        #expect(PageStubURLProtocol.requestedURLs.contains { $0.hasPrefix("http://") } == false,
                "a month page the app derived must never be fetched in the clear")
    }
}
