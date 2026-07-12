import Foundation

// When a page has nothing readable on it, look at where its LINKS go.
//
// This is Dan's own first lead, and it is the reason this exists. secondendingensemble.com is a Wix site
// whose show page is a poster IMAGE and a "BUY TIX HERE" button: there is no text to read even after a
// browser renders it (#806 does not rescue it). But that button points at lincolncenter.org, which is
// perfectly readable and carries the entire listing: Alice Tully Hall, the date, "Second Ending Ensemble
// - Mahler 1 'Titan'".
//
// The information was never on the ensemble's own site at all. THE LINK IS THE LEAD.
//
// And this is not one site's quirk. "A poster and a buy button" is how a great many small ensembles
// publish a show: the venue or the ticketing platform holds the real listing, and the ensemble's site
// just points at it.
enum TicketLink {
    // Sites that essentially only exist to sell or host a listing. A link here is worth following even
    // when the org gave it no useful words at all (plenty of pages just show a venue's logo).
    private static let ticketingHosts = [
        "eventbrite.com", "ticketmaster.com", "ticketleap.com", "tickettailor.com", "showclix.com",
        "brownpapertickets.com", "ovationtix.com", "ci.ovationtix.com", "seetickets.com", "dice.fm",
        "universe.com", "ticketweb.com", "seatgeek.com", "eventzilla.net", "simpletix.com",
        // NYC venues that publish the real listing for shows their renters merely link to.
        "lincolncenter.org", "carnegiehall.org", "symphonyspace.org", "kaufmanmusiccenter.org",
        "roulette.org", "nationalsawdust.org", "bargemusic.org", "themetopera.org", "bam.org",
    ]

    // What a buy button actually says, in the wild. The org's own words are the strongest signal we get:
    // they are its statement of what the link is FOR.
    private static let buyWords = [
        "ticket", "tix", "buy", "book now", "booking", "reserve", "rsvp", "get seats", "purchase",
    ]

    // Never worth following: a social profile is not a lead, and the org's OWN site is the page we just
    // failed to read, so following it back would be a circle that solves nothing.
    private static let neverFollow = [
        "facebook.com", "instagram.com", "twitter.com", "x.com", "youtube.com", "tiktok.com",
        "linkedin.com", "wix.com", "squarespace.com", "spotify.com", "apple.com", "patreon.com",
        "paypal.com", "venmo.com", "gofundme.com",
    ]

    static func candidate(in html: String, from pageURL: URL) -> URL? {
        let links = anchors(in: html, base: pageURL)
            .filter { $0.url.scheme?.hasPrefix("http") == true }
            .filter { !isSameSite($0.url, as: pageURL) }      // the page we already cannot read
            .filter { !isNeverFollow($0.url) }

        // An explicit buy button beats a link merely hosted somewhere ticket-ish: the words are the org
        // telling us what the link is for, and a "follow us on Eventbrite" link sells nothing.
        if let stated = links.first(where: { saysItSellsTickets($0.text) }) { return stated.url }
        return links.first(where: { isTicketingHost($0.url) })?.url
    }

    private struct Anchor { var text: String; var url: URL }

    private static func anchors(in html: String, base: URL) -> [Anchor] {
        guard let re = try? NSRegularExpression(
            pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let href = ns.substring(with: m.range(at: 1))
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }
            let inner = ns.substring(with: m.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Anchor(text: inner, url: url)
        }
    }

    private static func saysItSellsTickets(_ text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        return buyWords.contains { t.contains($0) }
    }

    private static func isTicketingHost(_ url: URL) -> Bool { matches(url, ticketingHosts) }
    private static func isNeverFollow(_ url: URL) -> Bool { matches(url, neverFollow) }

    private static func matches(_ url: URL, _ hosts: [String]) -> Bool {
        guard let host = canonicalHost(url) else { return false }
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func isSameSite(_ url: URL, as other: URL) -> Bool {
        guard let a = canonicalHost(url), let b = canonicalHost(other) else { return false }
        return a == b
    }

    private static func canonicalHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
