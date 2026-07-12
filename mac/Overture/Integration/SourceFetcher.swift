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
}

enum SourceFetcher {
    static func fetch(_ url: URL, session: URLSession = .shared) async throws -> FetchedPage {
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
        return FetchedPage(normalizedHTML: normalized,
                           finalURL: finalURL.absoluteString,
                           contentHash: PageNormalizer.contentHash(normalized))
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
        s = s.replacingOccurrences(
            of: "<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", with: " ",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<!--.*?-->", with: " ", options: .regularExpression)
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
