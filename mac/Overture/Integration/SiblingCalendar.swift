import Foundation

// #1056: a small, BOUNDED set of sibling calendar URLs to try when a watched source's own page comes
// back as an unreadable JavaScript shell. Several times a "drawn by JavaScript" verdict was really a
// wrong-URL misdiagnosis: the org keeps a plain-HTML calendar at a sibling path. The known real case is
// NYYS, whose watched URL rendered as a JS shell while /events/ is plain HTML.
//
// This is deliberately path guessing off the site ROOT, not crawling. The issue's constraint is "a
// bounded, small list of candidate paths, no crawling", so we never follow links or walk the site. The
// set is exactly the handful of paths small arts orgs actually use for a plain-HTML calendar: The Events
// Calendar (WordPress) lives at /events/, and many other sites use /calendar/. Both slashed and
// unslashed forms are tried because some sites serve one and 404 the other.
//
// A raw wp-json endpoint is left out on purpose: it serves JSON, which the fetcher rejects as notHTML,
// and the readability gate is built for HTML. The site root's own calendar link is left out because
// following it would be crawling, which this stays clear of.
enum SiblingCalendar {
    // Ordered most likely first. The first candidate that reads wins, so order is a cost choice (fewer
    // requests when the common path works), never a correctness one.
    static let paths = ["/events/", "/calendar/", "/events", "/calendar"]

    // The candidate URLs for a watched page, in order, with query and fragment dropped and the watched
    // page's own path excluded so we never re-try the page we already failed to read. Empty when the URL
    // has no host to build against.
    static func candidates(for url: URL) -> [URL] {
        guard let host = url.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [] }
        components.query = nil
        components.fragment = nil

        let ownPath = canonicalPath(url.path)
        var seen = Set<String>()
        var out: [URL] = []
        for path in paths {
            // Never re-try the page we already failed to read. "/events" and "/events/" canonicalize the
            // same, so a watched page at either form skips both candidate forms.
            if canonicalPath(path) == ownPath { continue }
            components.path = path
            guard let candidate = components.url, candidate.host == host else { continue }
            if seen.insert(candidate.absoluteString).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    private static func canonicalPath(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.lowercased()
    }
}
