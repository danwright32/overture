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

    var errorDescription: String? {
        switch self {
        case .http(let code):        return "The page answered with HTTP \(code)."
        case .notHTML(let type):     return "That link isn't a web page (it served \(type ?? "an unknown type"))."
        case .redirectedAway(let h): return "That link redirects to a different site (\(h)). Check the address."
        case .unreachable:           return "Couldn't reach that page."
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
    // Set when the page Dan gave us had nothing readable on it and we followed its TICKET LINK to the
    // page that did. Dan must be told: he pasted his ensemble's site and got a listing off Lincoln
    // Center's, and silently swapping the page under him would be exactly the kind of quiet cleverness
    // that makes a tool untrustworthy.
    var followedTicketLinkFrom: String? = nil
    // WHO the lead is about, read from the page Dan actually pasted. Only set when we had to leave that
    // page: a venue page is a page about MANY organizations, and without this we hand him the hall's
    // other tenants (which is exactly what happened).
    var onlyForOrg: String? = nil
}

enum SourceFetcher {
    // `render` is injected so the fallback is a real unit test with no WebKit. It defaults to the real
    // hidden browser (RenderedPage).
    static func fetch(_ url: URL,
                      session: URLSession = .shared,
                      render: ((URL) async throws -> String)? = nil,
                      allowTicketLinkHop: Bool = true) async throws -> FetchedPage {
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
            throw SourceFetchError.unreachable
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
        let normalized = PageNormalizer.normalize(html)

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
            if var followed = try? await fetch(ticket, session: session, render: render,
                                               allowTicketLinkHop: false),
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
    private static let meaningfulAttributes = ["href", "datetime", "content", "title"]

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
        s = s.replacingOccurrences(
            of: "(?s)<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", with: " ",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        s = stripAttributes(from: s)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    @discardableResult
    static func write(_ page: FetchedPage, forSourceId sourceId: String) throws -> URL {
        let target = url(forSourceId: sourceId)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(page.normalizedHTML.utf8).write(to: target, options: .atomic)
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
