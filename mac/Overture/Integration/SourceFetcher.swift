import Foundation
import CryptoKit

// #799 slice 3: the app fetches a source's listings page ITSELF and hands the extract run a pinned
// copy. The split is deliberate.
//
// The listing SET (which shows exist, which are gone) is what re-keys prospects and drives the "did
// this show get cancelled?" reconcile, so it must come from bytes the APP fetched and hashed, never
// from whatever a site happened to serve an agent a second later. The run may still follow each
// event's own detail page for the venue and the exact date (#770 spike, finding 4); that is per-event
// enrichment, and it cannot change what the app thinks the feed contains.
//
// Fetching here also means every failure is a NAMED error rather than an empty result. That is the
// whole ballgame for a watchlist: the spike found that having no upcoming shows is the NORMAL state
// (5 of its 7 real sites, in July), so a source that 404s and a source that is simply between seasons
// look identical unless the failure is named.

enum SourceFetchError: Error, Equatable, LocalizedError {
    case http(Int)                  // 401, 403, 404, 429, 500...
    case notHTML(String?)           // a PDF season, an image, a JSON endpoint
    case redirectedAway(String)     // answered 200, on a different site (see below)
    case unreachable                // timeout, DNS, connection refused
    // #1171: a platform feed adapter (OPERA America, VenueTix) answered with items but parsed NONE of them,
    // so the feed's shape has almost certainly changed. Distinct from a genuinely empty (off-season) feed,
    // which parses to zero from zero and is a normal quiet result. Named so drift reads as broken and is
    // caught on the first bad fetch, rather than looking like an empty calendar and going unnoticed.
    case feedShapeChanged
    // #1543: the site is THERE and answering, and its secure connection is broken, so no client can read
    // it. Split out of `unreachable` because the two ask different things of Dan. A dead domain is his to
    // fix or retire. A broken handshake on a live site is nobody's to fix from here, and re-checking it
    // forever will never clear it, so saying "Couldn't reach that page." sent him to look at a site that
    // was up the whole time.
    //
    // His Dinu Mihailescu row is the live case, and #972 predicted this source by name: the server answers
    // plain http with 200 and 37KB of HTML, and kills the https handshake with a fatal alert the moment a
    // client offers ALPN. Every real HTTP client offers ALPN, so every real client fails; Safari works only
    // because it never tries https on that site. #1544 is the separate question of reading it anyway.
    case secureConnectionFailed
    // #1555: the stored address is not one this feed can be read from at all. OvationTix reads a venue's
    // calendar by the client id embedded in its link, and with no id there nothing can be fetched. That is
    // a WRONG ADDRESS, not a network problem, and it is the one failure where the "Change the page link" button
    // already on the row is exactly the right next step.
    case addressUnusable

    var errorDescription: String? {
        switch self {
        case .http(let code):        return "The page answered with HTTP \(code)."
        case .notHTML(let type):     return "That link isn't a web page (it served \(type ?? "an unknown type"))."
        case .redirectedAway(let h): return "That link redirects to a different site (\(h)). Check the address."
        case .unreachable:           return "Couldn't reach that page."
        case .secureConnectionFailed: return "That site is up, but its secure connection is broken, so the page can't be read. A re-check won't clear this."
        case .addressUnusable:       return "That address is missing the part Overture needs to read this venue's calendar."
        case .feedShapeChanged:      return "That calendar's feed answered but nothing could be read from it, so its format has probably changed."
        }
    }

    // #1543: which transport failure this actually was, read off the error rather than guessed at. Every
    // caller that catches a thrown URLSession error routes through here, so the fetch path and the feed
    // adapters can never end up describing the same failure two different ways.
    //
    // Deliberately narrow. Only the TLS family becomes `secureConnectionFailed`; a timeout, a DNS failure
    // and a dropped connection stay `unreachable`, because for those "Couldn't reach that page." is TRUE
    // and the response Dan owes is a different one. Anything that is not a URLError at all falls back to
    // `unreachable` rather than claiming a TLS problem on no evidence.
    static func transport(_ error: Error) -> SourceFetchError {
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired:
            return .secureConnectionFailed
        default:
            return .unreachable
        }
    }
}

struct FetchedPage: Equatable, Sendable {
    var normalizedHTML: String
    var finalURL: String
    var contentHash: String
    // #806: true when the plain download carried nothing readable and we had to load the page the way a
    // browser does. Worth knowing per source: rendering is seconds and a whole WebKit instance, so a
    // source that always needs it is a source that costs more.
    var wasRendered: Bool = false
    // #1544: this page came back over an UNENCRYPTED connection, because the site's https handshake is
    // broken and Dan's stored address was cleartext. Anyone on the network between here and that server
    // could have altered it in flight, and it feeds FeedReconcile, where a source's silence cancels shows.
    // So it is carried rather than shrugged off, and said out loud on the source's row.
    var wasReadInsecurely: Bool = false
    // Set when the page Dan gave us had nothing readable on it and we followed its TICKET LINK to the
    // page that did. Dan must be told: he pasted his ensemble's site and got a listing off Lincoln
    // Center's, and silently swapping the page under him would be exactly the kind of quiet cleverness
    // that makes a tool untrustworthy.
    var followedTicketLinkFrom: String? = nil
    // #1295: the RAW (un-normalized) TicketTailor widget HTML, set only when the ticket-link hop landed on
    // a tickettailor all-tickets-calendar widget. It carries the `selectableDates` JSON the native parser
    // reads, which `normalizedHTML` cannot: PageNormalizer strips <script> blocks. Its presence is the
    // signal the scout uses to parse this page natively (free) instead of sending it to the paid read.
    // Deliberately NOT part of the content hash (that stays on `normalizedHTML`, whose event-filter options
    // change when the event set changes, so the "skip unchanged" gate still fires when events appear/go).
    var ticketTailorWidgetHTML: String? = nil
    // #1529: the single-venue ticketing feed (OvationTix, VenueTix) this document was synthesized FROM, and
    // the raw feed body it was synthesized from. Their presence is the signal the scout parses this source
    // natively (free) instead of paying for a read of a document it wrote itself, exactly as
    // `ticketTailorWidgetHTML` does. The body travels rather than being re-fetched so the events ingested
    // are the ones this page's hash covers: a second request could answer with a different calendar, and
    // the set it returned would then be reconciled against a hash taken from bytes nobody ingested.
    // Deliberately NOT part of the content hash, which stays on `normalizedHTML` (synthesized from these
    // same bytes, so it still moves whenever the calendar does).
    var ticketingFeedURL: String? = nil
    var ticketingFeedJSON: Data? = nil
    // #1056: set when the watched page itself came back unreadable (a JavaScript shell that even a full
    // browser render could not read) and the listings were found on a sibling calendar path of the SAME
    // site instead (the watched page rendered empty, but /events/ is plain HTML). Holds the watched URL
    // we fell back FROM, so the swap is recorded rather than silent.
    var readableSiblingOf: String? = nil
    // WHO the lead is about, read from the page Dan actually pasted. Only set when we had to leave that
    // page: a venue page is a page about MANY organizations, and without this we hand him the hall's
    // other tenants (which is exactly what happened).
    var onlyForOrg: String? = nil
    // #858: which months of a calendar this document actually contains ("2026-07", "2026-08", ...), and
    // which ones we tried to read and could not.
    //
    // `monthsUnread` is the important one, and it is a list rather than a count on purpose. A month we
    // failed to fetch means FEWER shows came back, and "fewer shows" is precisely what the reconcile
    // reads as "those shows were cancelled". So the shortfall has to be able to say its own name. A
    // silently shorter sweep is the one failure this feature could add that destroys real data.
    var monthsRead: [String] = []
    var monthsUnread: [String] = []
    // #900. Months the calendar NAMES and whose links we cannot follow at all, so there was never a page
    // to fetch or fail. Distinct from `monthsUnread`, which is a month we had a URL for and could not
    // read: that one may work tomorrow, this one never will until the app learns the shape. Dan can act
    // on this (paste that month's own link), which he cannot on a 404.
    var monthsUnreachable: [String] = []
}

enum SourceFetcher {
    // `render` is injected so the fallback is a real unit test with no WebKit. It defaults to the real
    // hidden browser (RenderedPage).
    //
    // `monthHorizon` is #858, and its DEFAULT OF 1 (no pagination) is what a caller gets when it names no
    // horizon. Both real callers now name one: the paste-a-lead path and, as of #1210, the reconciling
    // scout (which passes `CalendarMonthIndex.defaultHorizon`, four months).
    //
    // Paging forward on the scout was once unsafe, and the reason is worth keeping. The watchlist feeds
    // `FeedReconcile`, where a source's SILENCE about a show marks that show gone (`goneThreshold = 2`),
    // and a red-team pass found the stitched page opens a hole none of those gates can see: if the AI
    // reads three of four stitched months it simply returns fewer shows; nothing failed, nothing was
    // rejected, so `rejectedIsWithinTolerance` is happy and 16 of 30 events still clears
    // `feedIsTrustworthy`'s 50% bar, and two such runs strike fourteen live October concerts with no error
    // anywhere. What closed the hole (#897) is a per-page completeness verdict in the handoff contract:
    // the run echoes which stitched months it actually covered (`monthsCovered`), `SweepCoverage.isComplete`
    // compares that against the months the pin stitched, and a short read is DOWNGRADED to
    // `incompleteExtraction`, which can add and update but can cancel nothing (a missing/absent
    // `monthsCovered` fails safe as incomplete). That guard is wired end to end and proven in
    // `StitchedSweepIngestWiringTests`, which is why #1210 could turn scout pagination on.
    // #972: Overture ships with no App Transport Security exception, so macOS refuses a cleartext http
    // request before it leaves the process, and the source lands on `unreachable`. That sentence is a lie
    // in the case that actually happens: the site is up, it simply got stored with an http address. Two of
    // the three sources failing after the #359 backfill (Rainer Crosett, The Cell Theatre) were exactly
    // this, and both answer https with a 200; the third (Dinu Mihailescu) has a genuinely broken TLS
    // handshake, which no scheme fixes and which SHOULD keep failing.
    //
    // Asking for https instead cannot regress anything: a cleartext fetch cannot succeed today, so no
    // source that works now is affected. It also catches the next http link Dan pastes as a lead, which
    // would otherwise fail the same misleading way.
    // #1544: the hosts Overture may read over an UNENCRYPTED connection, and only after its https
    // handshake has actually failed (see `fetch`). Dan's decision, 2026-07-26, taken deliberately over the
    // alternative of opening cleartext everywhere and letting the code below be the only gate: macOS keeps
    // enforcing encryption for every other source on the watchlist, so a bug here cannot expose them.
    //
    // This list is HALF of the permission. The other half is the matching NSExceptionDomains entry in
    // Info.plist, without which the OS refuses the request whatever this says. Adding a host means editing
    // both, and `CleartextFallbackTests` fails if the two ever name different sets, because a permission
    // granted in two places that can drift is exactly the trap #887 named.
    //
    // dinumihailescu.com: answers plain http with 200 and 37KB of HTML; its https endpoint sends a fatal
    // TLS alert as soon as a client offers ALPN, which every real client does (evidence in #1543).
    static let cleartextFallbackHosts: Set<String> = ["dinumihailescu.com"]

    static func secured(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = "https"
        return parts.url ?? url
    }

    static func fetch(_ url: URL,
                      session: URLSession = .shared,
                      render: ((URL) async throws -> String)? = nil,
                      allowTicketLinkHop: Bool = true,
                      allowSiblingProbe: Bool = true,
                      monthHorizon: Int = 1,
                      now: Date = Date(),
                      sourceName: String? = nil,
                      sourceLocation: String? = nil,
                      operaFeed: ((URL) async throws -> FetchedPage)? = nil,
                      venuetixFeed: ((URL, String?, String?) async throws -> FetchedPage)? = nil,
                      ovationtixFeed: ((URL, String?, String?) async throws -> FetchedPage)? = nil) async throws -> FetchedPage {
        // #1127: some watched calendars are JS apps a plain fetch cannot read; route each to the adapter
        // that reads its public event feed directly (deterministic, hashable, safe for the reconcile).
        let target = secured(url)
        if OperaAmericaCalendar.handles(target) {
            let feed = operaFeed ?? { try await OperaAmericaCalendar.liveFetch(url: $0, now: now) }
            return try await feed(target)
        }
        if VenueTixCalendar.handles(target) {
            // The venue NAME is not in the feed, so it is threaded from the source's orgName.
            //
            // #1529: and from NOTHING else. This used to fall back to the request's host when no name came
            // down, which happens on exactly one path (the ticket-link hop below re-enters this function
            // with no source), and the result was 149 real shows at The Players Theatre synthesized as
            // "2026-07-26 at web.ovationtix.com". A hostname is not a room: the read that met it correctly
            // refused to treat it as a venue and every row was dropped. With no name the document simply
            // states no place, and the venue is supplied at ingest from Dan's own assertion instead.
            // #1175: the venue's location (nil unless Dan supplied one) rides along too, so a single-venue
            // feed with no city in its own data still places in-region.
            let feed = venuetixFeed ?? { u, n, loc in
                try await VenueTixCalendar.liveFetch(url: u, venueName: n, location: loc, now: now)
            }
            return try await feed(target, sourceName, sourceLocation)
        }
        if OvationTixCalendar.handles(target) {
            // Same as VenueTix: the feed carries no venue name, so it is threaded from the source's orgName
            // when there is one and never invented when there is not (#1529, above), and Dan's supplied
            // location rides along so a single-venue feed with no city in its own data still places in-region.
            let feed = ovationtixFeed ?? { u, n, loc in
                try await OvationTixCalendar.liveFetch(url: u, venueName: n, location: loc, now: now)
            }
            return try await feed(target, sourceName, sourceLocation)
        }

        // #1544: the cleartext fallback, and it lives HERE rather than inside fetchSinglePage on purpose.
        // Everything below this line (the month stitch) and inside that function (the ticket-link hop, the
        // sibling probe) follows an address the APP derived from a page, not one Dan supplied. Those must
        // never go out unencrypted, and putting the fallback on the entry point is what makes that
        // structural rather than a rule somebody has to remember.
        // #2213: everything a ticket-link hop needs to know about the source it is acting on behalf of,
        // built once here so every path below hands the hop the same thing.
        let hopContext = SourceContext(name: sourceName, location: sourceLocation,
                                       monthHorizon: monthHorizon, now: now,
                                       operaFeed: operaFeed, venuetixFeed: venuetixFeed,
                                       ovationtixFeed: ovationtixFeed)
        let landing: FetchedPage
        do {
            landing = try await fetchSinglePage(secured(url), session: session, render: render,
                                                allowTicketLinkHop: allowTicketLinkHop,
                                                allowSiblingProbe: allowSiblingProbe,
                                                source: hopContext)
        } catch let tlsFailure as SourceFetchError where mayReadInTheClear(tlsFailure, storedAt: url) {
            landing = try await readInTheClear(url, after: tlsFailure, session: session, render: render,
                                               allowTicketLinkHop: allowTicketLinkHop,
                                               allowSiblingProbe: allowSiblingProbe,
                                               source: hopContext)
        }

        // Not asked to paginate, or we are no longer on the page Dan gave us. A ticket-link hop means we
        // are reading somebody else's page (a venue's) on behalf of one org's lead, and walking THAT
        // site's calendar would hand back the hall's other tenants, which is the exact confusion the hop
        // already carries `onlyForOrg` to prevent.
        guard monthHorizon > 1, landing.followedTicketLinkFrom == nil,
              let finalURL = URL(string: landing.finalURL)
        else { return landing }

        let index = CalendarMonthIndex.index(in: landing.normalizedHTML, at: finalURL,
                                             now: now, horizon: monthHorizon)
        // Not a month calendar. The overwhelmingly common case (a show page, an org's homepage), and it
        // must cost exactly nothing: no extra fetch, no change to the document or its hash.
        //
        // `monthsUnreachable` rides along even here, and this is the case it exists for (#900): a calendar
        // whose month links we cannot follow yields NO pages, comes straight down this path, and is read
        // one month deep. It is only metadata, so it moves neither the document nor the hash.
        guard index.pages.count > 1 else {
            var out = landing
            out.monthsUnreachable = index.unreachableMonths
            return out
        }

        var out = await stitch(months: index.pages, landing: landing, landingURL: finalURL,
                               session: session, render: render, now: now)
        out.monthsUnreachable = index.unreachableMonths
        return out
    }

    // #1544: may this failure, on this address, be retried without encryption? Three conditions, and all
    // three have to hold.
    //
    //   1. The failure was the HANDSHAKE, nothing else. A timeout or a dead domain means the site did not
    //      answer at all, so dropping encryption buys nothing and would make this a general "try harder"
    //      path, which is how a safety valve becomes a habit.
    //   2. Dan STORED this address as cleartext. Overture never downgrades an https address he saved,
    //      whatever happens to its certificate, so a site that quietly breaks its TLS one day cannot be
    //      silently demoted to an unencrypted read. The only cleartext requests it ever makes are to
    //      addresses he typed as cleartext himself.
    //   3. The host is named in the app's transport policy. Without the matching Info.plist entry macOS
    //      refuses the request anyway, so checking here is not belt-and-braces: it stops a pointless
    //      request whose OS-level refusal would then be reported as a second, misleading failure.
    //
    // Subdomains match, mirroring NSIncludesSubdomains in the plist, so the two gates agree on what a
    // named host covers rather than one being quietly broader than the other.
    private static func mayReadInTheClear(_ failure: SourceFetchError, storedAt url: URL) -> Bool {
        guard failure == .secureConnectionFailed,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased()
        else { return false }
        return cleartextFallbackHosts.contains(host)
            || cleartextFallbackHosts.contains { host.hasSuffix(".\($0)") }
    }

    // The one retry. Never a loop: this calls fetchSinglePage directly, which has no fallback of its own.
    //
    // When the retry ALSO fails, which error survives is deliberate. A transport failure on the cleartext
    // attempt says nothing the handshake failure did not already say, so the original (#1543's honest
    // "the site is up, its secure connection is broken") is what Dan reads. Anything else means the server
    // actually ANSWERED, and a 404 or a PDF is real news about the address, so that wins instead. What
    // must never happen either way is a silent success: a fallback that swallowed the second failure would
    // report an empty page as a healthy read, which is the lie this whole file is built to prevent.
    private static func readInTheClear(_ url: URL, after tlsFailure: SourceFetchError,
                                       session: URLSession, render: ((URL) async throws -> String)?,
                                       allowTicketLinkHop: Bool,
                                       allowSiblingProbe: Bool,
                                       source: SourceContext = SourceContext()) async throws -> FetchedPage {
        do {
            var page = try await fetchSinglePage(url, session: session, render: render,
                                                 allowTicketLinkHop: allowTicketLinkHop,
                                                 allowSiblingProbe: allowSiblingProbe,
                                                 source: source)
            page.wasReadInsecurely = true
            return page
        } catch let retryFailure as SourceFetchError {
            switch retryFailure {
            case .unreachable, .secureConnectionFailed: throw tlsFailure
            default: throw retryFailure
            }
        }
    }

    // Reads each month of the calendar and joins them into ONE document with ONE hash.
    //
    // One document because that is what keeps this safe: the listing SET has to come from bytes the APP
    // fetched and hashed (see the note at the top of this file). Four pages the app fetched and hashed
    // together preserve that property exactly, and the handoff contract (one source, one pinned page,
    // one verdict) does not have to change at all.
    private static func stitch(months: [URL], landing: FetchedPage, landingURL: URL,
                               session: URLSession,
                               render: ((URL) async throws -> String)?,
                               now: Date) async -> FetchedPage {
        var sections: [String] = []
        var read: [String] = []
        var unread: [String] = []

        for month in months {
            let label = CalendarMonthIndex.Month(pathOf: month)?.label ?? month.absoluteString

            // The month page we are already holding. Re-fetching it would be a wasted request and, on a
            // site that rotates a token per request, would not even return the same bytes.
            if sameMonthPage(month, as: landingURL, now: now) {
                sections.append(section(label: label, url: month, html: landing.normalizedHTML))
                read.append(label)
                continue
            }

            guard let page = try? await fetchSinglePage(month, session: session, render: render,
                                                        // No context: this call cannot hop
                                                        // (allowTicketLinkHop is false), so it has
                                                        // nothing to hand one to.
                                                        allowTicketLinkHop: false,
                                                        allowSiblingProbe: false) else {
                // NAMED, never merely absent. A month we could not read means fewer shows came back, and
                // fewer shows is what the reconcile reads as "these were cancelled". A shortfall that
                // cannot say its own name is the one way this feature destroys data.
                unread.append(label)
                continue
            }
            sections.append(section(label: label, url: month, html: page.normalizedHTML))
            read.append(label)
        }

        let combined = sections.joined(separator: "\n")
        var out = landing
        out.normalizedHTML = combined
        out.contentHash = PageNormalizer.contentHash(combined)
        out.monthsRead = read
        out.monthsUnread = unread
        return out
    }

    // Each month is announced in the pinned page, so the run reading it can tell which month a listing
    // belongs to. Bargemusic's lesson applies with force here: a calendar cell's date is often implied by
    // WHICH grid it sits in, and four grids in one file with no headings would make every date ambiguous.
    private static func section(label: String, url: URL, html: String) -> String {
        "<!-- overture-month \(label) \(url.absoluteString) -->\n<section title=\"\(label)\">\(html)</section>"
    }

    private static func sameMonthPage(_ a: URL, as b: URL, now: Date) -> Bool {
        guard let ha = a.host, let hb = b.host, sameSite(ha, hb) else { return false }
        func canon(_ p: String) -> String { p.hasSuffix("/") ? p : p + "/" }
        if canon(a.path) == canon(b.path) { return true }
        // The landing page (/mch/calendar/) IS a month page: it serves whichever month we are in, which
        // is the first month of the window. Its path does not carry the month, so compare what it MEANS
        // rather than what it says, or we would fetch the current month twice.
        guard let ma = CalendarMonthIndex.Month(pathOf: a) else { return false }
        return CalendarMonthIndex.Month(pathOf: b) == nil && ma == CalendarMonthIndex.Month(now)
    }

    // #2213: what a hop needs to know about the source it is acting ON BEHALF OF. One value rather than
    // six more parameters at four call sites, and it carries the injected feed adapters for the same
    // reason it carries the name: without them a hop onto a feed URL calls the real network, which no test
    // may do (L2).
    struct SourceContext {
        var name: String?
        var location: String?
        var monthHorizon: Int = 1
        var now: Date = Date()
        var operaFeed: ((URL) async throws -> FetchedPage)?
        var venuetixFeed: ((URL, String?, String?) async throws -> FetchedPage)?
        var ovationtixFeed: ((URL, String?, String?) async throws -> FetchedPage)?
    }

    private static func fetchSinglePage(_ url: URL,
                                        session: URLSession,
                                        render: ((URL) async throws -> String)?,
                                        allowTicketLinkHop: Bool,
                                        allowSiblingProbe: Bool = true,
                                        source: SourceContext = SourceContext()) async throws -> FetchedPage {
        let (html, normalized, finalURL) = try await plainFetch(url, session: session)

        // #1127: a tickettailor box-office embed's events live in its widget URL, not this shell (which
        // reads as "readable" but carries no events). Follow it once to the server-rendered widget and read
        // THAT instead. Plain and deterministic (browser headers, no render). Recorded transparently via
        // followedTicketLinkFrom, and gated like the ticket-link hop so a sub-fetch never wanders.
        if allowTicketLinkHop, let widget = TicketTailor.widgetURL(inPage: html) {
            var page = try await TicketTailor.fetchWidget(widget) { try await session.data(for: $0) }
            page.followedTicketLinkFrom = finalURL.absoluteString
            return page
        }

        // #806. If the download carried something to read, we are done, and the browser is never touched.
        // That matters: rendering costs seconds and a whole WebKit instance per source, and the watchlist
        // re-checks dozens of sources on a schedule, so "just render everything" would quietly make the
        // daily run an order of magnitude slower for no gain on the sources that work fine.
        if PageNormalizer.carriesReadableContent(normalized) {
            return FetchedPage(normalizedHTML: normalized,
                               finalURL: finalURL.absoluteString,
                               contentHash: PageNormalizer.contentHash(normalized))
        }

        // Nothing readable came down the wire. The page is probably drawn by JavaScript (Wix,
        // Squarespace, and most of the small arts orgs Dan pitches), so load it the way a browser does,
        // let its scripts run, and read the finished page instead.
        let renderer = render ?? { try await RenderedPage.html(for: $0) }
        var best = normalized
        var rendered = false
        if let renderedHTML = try? await renderer(finalURL) {
            best = PageNormalizer.normalize(renderedHTML)
            rendered = true
            if PageNormalizer.carriesReadableContent(best) {
                return FetchedPage(normalizedHTML: best, finalURL: finalURL.absoluteString,
                                   contentHash: PageNormalizer.contentHash(best), wasRendered: true)
            }
        }
        // A browser that hangs, crashes or is unavailable must not take the whole fetch down with it:
        // `best` stays the raw page, and the honest "I can't read this" path can still run.

        // #1056: before we conclude this source is JavaScript-drawn and unreadable, try a small, bounded
        // set of sibling calendar paths on the SAME site (/events/, /calendar/, ...). NYYS is the case
        // this exists for: its watched URL renders as a JS shell, yet it keeps a plain-HTML calendar at
        // /events/, so the "drawn by JavaScript" verdict was really a wrong-URL misdiagnosis. The watched
        // URL still gets BOTH of its own chances first (a plain download, then a full browser render):
        // only when neither reads do we look sideways, so a working JS calendar is never displaced by a
        // guess. Same site, and tried before the off-site ticket hop below.
        if allowSiblingProbe, let sibling = await readableSibling(of: finalURL, session: session) {
            return sibling
        }

        // Still nothing. Now look at where the page's LINKS go. Dan's own first lead is exactly this: his
        // ensemble's show page is a poster IMAGE and a "BUY TIX HERE" button, and the button points at
        // lincolncenter.org, which carries the whole listing (Alice Tully Hall, the date, the programme).
        // The information was never on the ensemble's site at all: THE LINK IS THE LEAD. "A poster and a
        // buy button" is how a great many small ensembles publish a show.
        //
        // One hop only, and never back to the site we just failed to read (TicketLink), so this cannot
        // wander or loop.
        // Look in the RENDERED page first (it is the fuller one), but fall back to the raw page, because
        // a render that half-succeeds can drop the very link we need. A test caught exactly that: the
        // rendered page came back as an image and nothing else, and the "BUY TIX HERE" link that was
        // sitting in the raw HTML all along would have been thrown away with it.
        let ticketCandidate = TicketLink.candidate(in: best, from: finalURL)
            ?? TicketLink.candidate(in: normalized, from: finalURL)

        if allowTicketLinkHop, let ticket = ticketCandidate {
            // #2213: the source's own name and location go WITH the hop, and so do the injected feed
            // adapters. The hop is performed on behalf of a known source, so that source's name is exactly
            // the assertion the OvationTix and VenueTix adapters need: neither feed carries a venue name of
            // its own, and a calendar reached by the hop therefore named no place at all, so
            // `ExtractedEventGuard` dropped every show it found.
            //
            // Measured 2026-08-06: theplayerstheatre.com/show-schedule.html carries 328 characters and no
            // dates, so the hop fires; web.ovationtix.com/trs/cal/277 returns 108KB of shows running from
            // that night into September; and the scout reported the source as having come back with
            // nothing. This is the "exactly one path" the note at the VenueTix branch above names, and
            // #1529 was right to take away the hostname fallback while leaving the hop with nothing to put
            // in its place.
            //
            // The feed closures ride along for a separate reason: without them a hop onto a feed URL calls
            // the real network, which no test may do (L2).
            if var followed = try? await fetch(ticket, session: session, render: render,
                                               allowTicketLinkHop: false, allowSiblingProbe: false,
                                               monthHorizon: source.monthHorizon, now: source.now,
                                               sourceName: source.name, sourceLocation: source.location,
                                               operaFeed: source.operaFeed,
                                               venuetixFeed: source.venuetixFeed,
                                               ovationtixFeed: source.ovationtixFeed),
               PageNormalizer.carriesReadableContent(followed.normalizedHTML) {
                followed.followedTicketLinkFrom = finalURL.absoluteString
                // We are now reading somebody else's page (a venue's). Remember whose lead this is, or
                // the venue's whole calendar comes back as if it belonged to the org Dan pasted.
                followed.onlyForOrg = OrgIdentity.name(inPage: html, url: finalURL)
                return followed
            }
        }

        return FetchedPage(normalizedHTML: best, finalURL: finalURL.absoluteString,
                           contentHash: PageNormalizer.contentHash(best), wasRendered: rendered)
    }

    // The plain download half of a fetch, shared by the primary page and by the #1056 sibling probe so
    // the two can never diverge on the content-type, redirect, or decoding rules. Returns the raw HTML
    // (the ticket hop's OrgIdentity read needs it), the normalized HTML, and the resolved final URL.
    // Throws a TYPED SourceFetchError on any HTTP, content-type, redirect, or transport failure.
    private static func plainFetch(_ url: URL, session: URLSession)
        async throws -> (html: String, normalized: String, finalURL: URL) {
        let (data, response): (Data, URLResponse)
        do {
            var request = URLRequest(url: url)
            // Some org sites serve a stripped page (or nothing) to an unrecognized client.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
                forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            (data, response) = try await session.data(for: request)
        } catch {
            // #1543: named, not flattened. This catch used to swallow every transport failure into
            // `unreachable`, which is how a live site with a broken handshake read as a dead link.
            throw SourceFetchError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw SourceFetchError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw SourceFetchError.http(http.statusCode) }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        if let contentType, !contentType.lowercased().contains("html") {
            throw SourceFetchError.notHTML(contentType.components(separatedBy: ";").first)
        }

        // The #770 spike's real trap: thirdstreetmusicschool.org/events answers 200 on a DIFFERENT
        // domain (thirdstreet.nyc), serving a homepage. That reads as a healthy fetch of an events page
        // that happens to have no events, which is exactly the lie this whole design exists to prevent.
        // The recorded URL is simply wrong, and Dan is the one who can fix it.
        //
        // Only a change of SITE counts. Every site redirects for boring reasons (adding www, forcing
        // https, appending a slash, moving /calendar to /calendar-tickets, which Bargemusic really
        // does), and none of those mean anything.
        let finalURL = http.url ?? url
        if let from = url.host, let to = finalURL.host, !sameSite(from, to) {
            throw SourceFetchError.redirectedAway(to)
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return (html, PageNormalizer.normalize(html), finalURL)
    }

    // #1056: try the bounded sibling calendar paths in order and return the first that reads as plain
    // HTML. A sibling that 404s, serves JSON, redirects off site, or comes back empty is EXPECTED (we
    // are guessing paths, not crawling), so each per-candidate failure is swallowed and the next is
    // tried. When none reads, this returns nil and the caller falls through to the honest unreadable
    // verdict, so the whole attempt can only ever RESCUE a source, never mask a real failure with a
    // wrong page. Each candidate is a plain download only: no browser render and no ticket hop, so the
    // probe stays cheap even across all four guesses.
    private static func readableSibling(of url: URL, session: URLSession) async -> FetchedPage? {
        for candidate in SiblingCalendar.candidates(for: url) {
            guard let (_, normalized, finalURL) = try? await plainFetch(candidate, session: session),
                  PageNormalizer.carriesReadableContent(normalized) else { continue }
            return FetchedPage(normalizedHTML: normalized,
                               finalURL: finalURL.absoluteString,
                               contentHash: PageNormalizer.contentHash(normalized),
                               readableSiblingOf: url.absoluteString)
        }
        return nil
    }

    private static func sameSite(_ a: String, _ b: String) -> Bool {
        func canon(_ h: String) -> String {
            var s = h.lowercased()
            if s.hasPrefix("www.") { s.removeFirst(4) }
            return s
        }
        return canon(a) == canon(b)
    }
}

// Cuts a page down to what an extractor actually needs, and to what a content hash should be judged on.
//
// VERIFIED, not assumed (Dan's condition before adopting this): on the real Bargemusic page this cut
// ~17,900 tokens to ~1,500 (92%), and re-running the extraction on the normalized page returned all 6
// concerts, still correctly dating the two trailing grid cells to AUGUST rather than July. Across the
// spike's sample it takes a typical source from ~25k tokens to ~2.4k.
//
// It keeps the TAG STRUCTURE on purpose. Bargemusic prints no dates at all: each concert sits in a
// cell of a month grid and its date is implied by WHICH cell it is in. Strip to plain text and that
// information is destroyed, which would break the single hardest case the spike proved works.
//
// It drops what no extractor needs and what churns on every request: scripts (which are most of the
// bytes), styles, head, SVG paths, comments, and every attribute except the few that carry meaning.
// That last part is also what makes the hash stable: a site that rotates a script nonce or reflows its
// whitespace on every request must NOT look like a page that changed, or the "skip unchanged pages"
// saving quietly becomes zero and every source is re-read by an AI every day forever.
enum PageNormalizer {
    // `value` and `rel` are here because a site's own NAVIGATION is content, and an allow-list that
    // omits them deletes it. On the live Kaufman Music Center calendar the route to its other months is
    // not an `href` at all, it is `<option value="https://.../mch/calendar/2026/10/">`; all twenty-four
    // were being stripped before anything could read them. You cannot follow navigation that is already
    // gone from the bytes you kept, which is what blocked multi-page calendars (#858).
    //
    // Keeping them is free. See `contentProjection`: the hash is taken over visible text plus `href`
    // values, and visible text has every tag stripped out of it, so an attribute reaches neither half.
    // No attribute added here can move the hash or cost a token. That is locked by a test, not assumed.
    private static let meaningfulAttributes = ["href", "datetime", "content", "title", "value", "rel"]

    static func normalize(_ html: String) -> String {
        var s = html
        // `(?s)` is load-bearing, not a flourish: without it `.` does not cross a NEWLINE, so only
        // single-line scripts were stripped. Real scripts span lines. On a real Wix site that left 32
        // script blocks intact (246KB of JavaScript instead of 32KB of page), and the run, handed a
        // quarter-megabyte of code, reasonably reported "no events here". Dan was told his org's page
        // was not an events page. It was. WE were unreadable, not the site.
        //
        // A confident, plausible, WRONG answer from a step that reported success is the worst failure
        // this system can produce, and the tests missed it because every fixture script fit on one line.
        //
        // `head` stays on this list, and #892 asked whether it should. It should. Keeping it looks like
        // the same idea as keeping `rel` (a `<link rel="next">` lives up there), and it is the opposite:
        // the head is full of ASSET hrefs, and `contentProjection` reads every href it can see. Kaufman
        // serves `<link rel="stylesheet" href="/ui/css/main.2026-07-09-13-37-08.css">`, whose URL is a
        // BUILD TIMESTAMP. Keep the head and that timestamp is in the hash, so every CSS redeploy makes
        // an unchanged calendar look changed and buys a full AI re-read of it. A stylesheet is not a
        // listing. Attributes are free (they never reach the hash); the head's hrefs are not.
        s = s.replacingOccurrences(
            of: "(?s)<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", with: " ",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        s = stripAttributes(from: s)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The widest line the pinned page may carry. The detached reader reads with a line-oriented Read tool
    // that cannot page past a single oversized line, so no line may exceed what one read comfortably
    // returns. Kept well under that so a page always fits in whole lines the reader's offset paging covers.
    static let readerLineWidth = 4000

    // Break the pinned page into lines the detached reader can actually page through.
    //
    // `normalize` collapses ALL whitespace (including newlines) so the change hash stays stable through a
    // site's whitespace churn. The cost is that a whole page can end up on ONE line, and the reader's Read
    // tool cannot page past a single oversized line: Chain Theatre's 82KB one-line page was read to ~56%
    // and then looped on `incomplete_extraction` forever, re-read on every scout and never clearing, while
    // spending a paid read each time. This re-introduces line breaks for the ON-DISK PIN ONLY: a newline
    // after each tag, and a hard wrap of any remaining run wider than the reader can take, so a tag-dense
    // page becomes one line per element and the reader's existing offset paging covers the whole thing.
    //
    // It inserts ONLY whitespace, and the content hash is computed from `normalizedHTML` at fetch time, not
    // from these pinned bytes (which are never re-hashed), so this can never make an unchanged page look
    // changed. Applied only where the page is written for the reader, never to the in-memory
    // `normalizedHTML` the month index and readability checks read.
    static func pageableForReading(_ normalized: String) -> String {
        var out = ""
        out.reserveCapacity(normalized.count + normalized.count / 20)
        var lineWidth = 0
        for ch in normalized {
            out.append(ch)
            if ch == ">" {
                out.append("\n")
                lineWidth = 0
            } else if ch == "\n" {
                lineWidth = 0
            } else {
                lineWidth += 1
                if lineWidth >= readerLineWidth {
                    out.append("\n")
                    lineWidth = 0
                }
            }
        }
        return out
    }

    // The hash answers exactly one question: DID THIS PAGE'S CONTENT CHANGE? So it is taken over what
    // the content actually is (the visible text, plus the links, which is how each event is reached),
    // and NOT over the markup that carries it.
    //
    // Hashing the markup looks equivalent and is not. Sites reflow whitespace, reorder attributes and
    // rotate nonces on every request, so a markup hash would move constantly, every source would be
    // re-read by an AI every single day, and the "skip unchanged pages" saving (the entire cost model,
    // ~25k tokens per source per check) would silently be zero. Nothing would look broken; it would
    // just quietly cost 10x forever, which is the worst kind of bug.
    //
    // The PIN keeps the structure (the extractor needs the month grid). Only the HASH ignores it.
    static func contentHash(_ normalized: String) -> String {
        SHA256.hash(data: Data(contentProjection(normalized).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // Does this page actually carry anything to read?
    //
    // Dan's first real lead was a Wix site (secondendingensemble.com). Once the scripts are stripped,
    // what remains is a NAVIGATION SHELL: "Home / Our Story / Prior Performances / Upcoming Events /
    // Contact ... © 2025 ... Proudly created with Wix.com", and nothing else. The shows are drawn by
    // JavaScript and are simply not in the bytes we fetched.
    //
    // The app can see that for itself, and must. Handing a shell to a Claude run spends a minute and an
    // invocation to be told what we already know, and invites the worst possible outcome: a CONFIDENT
    // WRONG ANSWER ("no events on this page") about a page that is full of events we cannot see. That
    // is exactly what happened to Dan, and he was told his org's page was not an events page. It was.
    //
    // The rule is deliberately NOT "the text is short". A first cut used a length floor and a test
    // caught it immediately: a small org with three concerts on its page has less visible text than a
    // Wix shell has boilerplate, so a length rule would declare REAL sources unreadable. Wrongly
    // refusing a real page is far worse than wasting a run on a shell.
    //
    // A page is only refused when it is BOTH too thin to hold listings AND carries no date of any kind.
    // Any genuine events page mentions a date somewhere: a month heading, a year, an ISO timestamp. A
    // JS-drawn shell mentions none, because its content is not there at all. Both conditions together
    // mean there is simply nothing here to read.
    static let thinTextFloor = 800

    static func carriesReadableContent(_ normalized: String) -> Bool {
        let text = visibleText(normalized)
        if text.count >= thinTextFloor { return true }
        return mentionsADate(text)
    }

    private static func mentionsADate(_ text: String) -> Bool {
        let patterns = [
            "(?i)\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+\\d{1,2}\\b",  // "Oct 3"
            "(?i)\\b(january|february|march|april|may|june|july|august|september|october|november|december)\\b",
            "\\b20\\d{2}-\\d{2}-\\d{2}\\b",                                                       // ISO
            "(?i)\\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*day\\b",                                   // "Saturday"
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func visibleText(_ normalized: String) -> String {
        normalized
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Text plus link targets, whitespace-collapsed: the two things a change to the actual listings
    // would move, and the two things markup churn does not.
    static func contentProjection(_ normalized: String) -> String {
        let hrefs = (try? NSRegularExpression(pattern: "href=\"([^\"]*)\""))
            .map { re -> [String] in
                let ns = normalized as NSString
                return re.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range(at: 1)) }
            } ?? []
        let text = normalized
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text + "\n" + hrefs.joined(separator: "\n")
    }

    private static func stripAttributes(from html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<([a-zA-Z0-9]+)((?:\\s[^>]*)?)>") else { return html }
        let ns = html as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let attrs = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            let kept = keptAttributes(from: attrs)
            out += kept.isEmpty ? "<\(name)>" : "<\(name) \(kept)>"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func keptAttributes(from attrs: String) -> String {
        guard !attrs.isEmpty,
              let re = try? NSRegularExpression(pattern: "\\b([a-zA-Z-]+)\\s*=\\s*\"([^\"]{0,300})\"")
        else { return "" }
        let ns = attrs as NSString
        var kept: [String] = []
        for m in re.matches(in: attrs, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            guard meaningfulAttributes.contains(name) else { continue }
            kept.append("\(name)=\"\(ns.substring(with: m.range(at: 2)))\"")
        }
        return kept.joined(separator: " ")
    }
}

// The pinned page: the exact file the extract run reads. Flat in the handoff directory, per the #321
// guard, and named from a SANITIZED source id: an id ultimately traces back to a URL Dan pasted, and
// data must never be able to write itself outside the folder it belongs in.
enum ScoutPagePin {
    static func url(forSourceId sourceId: String) -> URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-scout-page-\(safeName(sourceId)).html")
    }

    // #849: a test writing a real pinned page into the live handoff directory is how a stale file ended
    // up there and later hung the Add-a-lead sheet on a source it had never asked about. Refused at the
    // source, so no future test can leave one behind by forgetting to inject the seam.
    enum PinError: Error, Equatable { case refusedUnderTest }

    @discardableResult
    static func write(_ page: FetchedPage, forSourceId sourceId: String) throws -> URL {
        guard !AppEnvironment.isRunningUnderTests else { throw PinError.refusedUnderTest }
        let target = url(forSourceId: sourceId)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Broken into reader-sized lines so the detached reader's offset paging can cover the whole page.
        // The pinned bytes are never re-hashed, and this adds only whitespace, so it cannot affect change
        // detection (PageNormalizer.pageableForReading).
        let pinned = PageNormalizer.pageableForReading(page.normalizedHTML)
        try Data(pinned.utf8).write(to: target, options: .atomic)
        return target
    }

    // Anything that is not a plain identifier character becomes a dash, so no id can carry a path
    // separator, a traversal, or a space into a filename. Distinct ids stay distinct because the
    // mapping only collapses characters, never whole ids: an empty result still gets a stable stand-in.
    static func safeName(_ sourceId: String) -> String {
        let cleaned = sourceId.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        let joined = String(cleaned)
        return joined.isEmpty ? "unnamed" : joined
    }
}
