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
            let venueName = source.orgName
            let location = source.venueLocation
            return VenueTixExtractor(
                fetchEvents: {
                    guard let url else { throw SourceFetchError.unreachable }
                    return try await VenueTixCalendar.liveEvents(url: url)
                },
                venueName: venueName, location: location)
        case .ovationTixFeed:
            let url = source.listingsURL.flatMap { URL(string: $0) }
            let venueName = source.orgName
            let location = source.venueLocation
            return OvationTixExtractor(
                fetchEvents: {
                    guard let url else { throw SourceFetchError.unreachable }
                    return try await OvationTixCalendar.liveEvents(url: url)
                },
                venueName: venueName, location: location)
        }
    }
}
