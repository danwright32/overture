import Foundation

// #1237: makes any *.venuetix.com single-venue feed (Green Room 42, ...) a native, free source. The feed
// adapter already parses the venue's complete upcoming list (VenueTixCalendar); before this, that structure
// was thrown away by synthesizing HTML for a paid AI read. This conformer maps the already-parsed events
// straight to ExtractedEvent, attributing each show to the venue by name and carrying Dan's supplied
// location, so the same shows ingest on every run for free.
//
// The event fetch is injected so the whole extractor is a real unit test with no network. The registry
// builds the live variant from the source row; the tests build one over an in-memory list.
final class VenueTixExtractor: SourceExtractor {
    private let fetchEvents: @Sendable () async throws -> [VenueTixCalendar.VTEvent]
    private let presenter: String
    // #1529: nil when nobody with the standing to say so has named the room these shows play in. Those rows
    // reach the guard with no venue and are left out of the queue, which is the honest outcome: this feed
    // publishes no venue anywhere, and the org's own name is not proof its shows are in its own room.
    private let venue: String?
    private let location: String?

    init(fetchEvents: @escaping @Sendable () async throws -> [VenueTixCalendar.VTEvent],
         presenter: String, venue: String?, location: String?) {
        self.fetchEvents = fetchEvents
        self.presenter = presenter
        self.venue = venue
        self.location = location
    }

    // The live reader. A failed fetch throws (never an empty list, which the reconcile would read as "every
    // show was cancelled"), so an empty read can never strike real shows.
    convenience init(url: URL, presenter: String, venue: String?, location: String?,
                     now: Date = Date(), session: URLSession = .shared) {
        self.init(fetchEvents: { try await VenueTixCalendar.liveEvents(url: url, now: now, session: session) },
                  presenter: presenter, venue: venue, location: location)
    }

    // A structured feed can only ever be "here are the upcoming events" or "there are none", so the verdict
    // is derived, never guessed (ExtractedListing.fromStructuredFeed).
    func extract() async throws -> ExtractedListing {
        let events = try await fetchEvents()
        return ExtractedListing.fromStructuredFeed(
            VenueTixCalendar.extractedEvents(from: events, presenter: presenter, venue: venue, location: location))
    }
}
