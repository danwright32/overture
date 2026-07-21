import Foundation

// #1237: makes OPERA America's calendar a native, free source. Its feed adapter already parses the
// national opera calendar into clean structured events (OperaAmericaCalendar); before this, that structure
// was thrown away by synthesizing HTML for a paid AI read. This conformer maps the already-parsed events
// straight to ExtractedEvent, so the same shows ingest on every run (including the automatic daily one) for
// free, exactly as Carnegie's Algolia feed does.
//
// The event fetch is injected so the whole extractor is a real unit test with no network. The registry
// builds the live variant; the tests build one over an in-memory list.
final class OperaAmericaExtractor: SourceExtractor {
    private let fetchEvents: @Sendable () async throws -> [OperaAmericaCalendar.OAEvent]

    init(fetchEvents: @escaping @Sendable () async throws -> [OperaAmericaCalendar.OAEvent]) {
        self.fetchEvents = fetchEvents
    }

    // The live reader over the shared calendar horizon. A page that fails throws (never a short "complete"
    // list, which the reconcile would read as cancellations), so an empty read can never strike real shows.
    convenience init(url: URL, now: Date = Date(), session: URLSession = .shared) {
        self.init { try await OperaAmericaCalendar.liveEvents(url: url, now: now, session: session) }
    }

    // A structured feed can only ever be "here are the upcoming events" or "there are none", so the verdict
    // is derived, never guessed (ExtractedListing.fromStructuredFeed): it can never be .allPast (it queries
    // a forward window) or .unreadable (it parses JSON, not a rendered page).
    func extract() async throws -> ExtractedListing {
        ExtractedListing.fromStructuredFeed(OperaAmericaCalendar.extractedEvents(from: try await fetchEvents()))
    }
}
