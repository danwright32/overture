import Foundation

// #1503: makes a Squarespace EVENTS collection a native, free source. Its `?format=json` view already
// carries the whole upcoming schedule as data, so the shows ingest on every run for nothing instead of
// costing a paid AI read each time the page changes.
//
// The org PRESENTS and each show keeps the venue the feed names (see SquarespaceCalendar.extractedEvents):
// unlike the single-venue adapters, one org's page routinely lists shows at several different halls.
//
// The event fetch is injected so the whole extractor is a real unit test with no network, matching
// VenueTixExtractor.
final class SquarespaceExtractor: SourceExtractor {
    private let fetchEvents: @Sendable () async throws -> [SquarespaceCalendar.SQEvent]
    private let orgName: String
    private let location: String?

    init(fetchEvents: @escaping @Sendable () async throws -> [SquarespaceCalendar.SQEvent],
         orgName: String, location: String?) {
        self.fetchEvents = fetchEvents
        self.orgName = orgName
        self.location = location
    }

    // The live reader. A failed or drifted read THROWS rather than returning a short list, because a
    // short list reads to the reconcile as "the rest were cancelled" and strikes real performances
    // (#1127's rule, restated in #1503's acceptance).
    convenience init(url: URL, orgName: String, location: String?, session: URLSession = .shared) {
        self.init(fetchEvents: { try await SquarespaceCalendar.liveEvents(url: url, session: session) },
                  orgName: orgName, location: location)
    }

    // A structured feed can only ever be "here are the upcoming events" or "there are none", so the
    // verdict is derived, never guessed. Three of Dan's seven Squarespace events collections have nothing
    // upcoming today, and that is a complete answer rather than a failure.
    func extract() async throws -> ExtractedListing {
        let events = try await fetchEvents()
        return ExtractedListing.fromStructuredFeed(
            SquarespaceCalendar.extractedEvents(from: events, orgName: orgName, location: location))
    }
}
