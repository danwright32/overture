import Foundation

// #1237: which native extractor reads a given source. The scout used to inject ONE extractor for every
// native source, which worked only because Carnegie was the only one. Now that the two host-routed feed
// adapters ingest natively too, runNative asks this registry per source and falls back to the injected
// extractor (Carnegie, or a test stub) for anything it does not own.
//
// It returns nil for Carnegie's .algolia and for .html sources on purpose: those are not this registry's to
// build. Carnegie stays the injected fallback (its extractor carries app id / api key), and an .html source
// is not native at all (it is fetched, hashed, and read by the paid extract run).
enum SourceExtractorRegistry {
    static func extractor(for source: WatchedSource?) -> (any SourceExtractor)? {
        guard let source else { return nil }   // nil == Carnegie's implicit row: use the injected fallback
        switch source.kind {
        case .algolia, .html:
            return nil
        case .operaAmericaFeed:
            // A native feed row always carries a routable URL (SourceKind.forListingURL only assigns this
            // kind to a matching host). Should that invariant ever break, the extractor throws on read
            // rather than the source silently falling back to Carnegie's feed, so the failure is loud.
            let url = source.listingsURL.flatMap { URL(string: $0) }
            return OperaAmericaExtractor {
                guard let url else { throw SourceFetchError.unreachable }
                return try await OperaAmericaCalendar.liveEvents(url: url)
            }
        case .venueTixFeed:
            let url = source.listingsURL.flatMap { URL(string: $0) }
            // #1529: Dan is watching this venue AT ITS OWN TICKETING FEED, an address he pasted himself, so
            // the org name on the row is his own answer to "which room is this?" and stays the venue. Only a
            // source whose page had to be LEFT (the ticket-link hop) loses that standing, and it asks for
            // `venueName` instead of assuming.
            let venue = source.venueName ?? source.orgName
            let location = source.venueLocation
            return VenueTixExtractor(
                fetchEvents: {
                    guard let url else { throw SourceFetchError.unreachable }
                    return try await VenueTixCalendar.liveEvents(url: url)
                },
                presenter: source.orgName, venue: venue, location: location)
        case .squarespaceFeed:
            // #1503: the org's own events page, read from its JSON view. The org presents; each show
            // keeps whichever venue the feed names, so nothing is threaded in here but the org name and
            // Dan's supplied location.
            let url = source.listingsURL.flatMap { URL(string: $0) }
            let orgName = source.orgName
            let location = source.venueLocation
            return SquarespaceExtractor(
                fetchEvents: {
                    guard let url else { throw SourceFetchError.unreachable }
                    return try await SquarespaceCalendar.liveEvents(url: url)
                },
                orgName: orgName, location: location)
        case .ovationTixFeed:
            let url = source.listingsURL.flatMap { URL(string: $0) }
            // Same as VenueTix above (#1529): this address IS the venue's own feed, pasted by Dan.
            let venue = source.venueName ?? source.orgName
            let location = source.venueLocation
            return OvationTixExtractor(
                fetchEvents: {
                    guard let url else { throw SourceFetchError.unreachable }
                    return try await OvationTixCalendar.liveEvents(url: url)
                },
                presenter: source.orgName, venue: venue, location: location)
        }
    }
}
