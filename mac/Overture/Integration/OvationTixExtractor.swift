import Foundation

// #1344: makes any *.ovationtix.com single-venue calendar (SoHo Playhouse, ...) a native, free source. The
// feed adapter already parses the venue's complete upcoming list (OvationTixCalendar); before this, that
// structure was thrown away by reading the SPA shell through a paid AI extract. This conformer maps the
// already-parsed events straight to ExtractedEvent, attributing each show to the venue by name and carrying
// Dan's supplied location, so the same shows ingest on every run for free, exactly as VenueTixExtractor does.
//
// The event fetch is injected so the whole extractor is a real unit test with no network. The registry builds
// the live variant from the source row; the tests build one over an in-memory list.
final class OvationTixExtractor: SourceExtractor {
    private let fetchEvents: @Sendable () async throws -> [OvationTixCalendar.OTEvent]
    private let venueName: String
    private let location: String?

    init(fetchEvents: @escaping @Sendable () async throws -> [OvationTixCalendar.OTEvent],
         venueName: String, location: String?) {
        self.fetchEvents = fetchEvents
        self.venueName = venueName
        self.location = location
    }

    // The live reader. A failed fetch throws (never an empty list, which the reconcile would read as "every
    // show was cancelled"), so an empty read can never strike real shows.
    convenience init(url: URL, venueName: String, location: String?,
                     now: Date = Date(), session: URLSession = .shared) {
        self.init(fetchEvents: { try await OvationTixCalendar.liveEvents(url: url, now: now, session: session) },
                  venueName: venueName, location: location)
    }

    // A structured feed can only ever be "here are the upcoming events" or "there are none", so the verdict
    // is derived, never guessed (ExtractedListing.fromStructuredFeed).
    func extract() async throws -> ExtractedListing {
        let events = try await fetchEvents()
        return ExtractedListing.fromStructuredFeed(
            OvationTixCalendar.extractedEvents(from: events, venueName: venueName, location: location))
    }
}
