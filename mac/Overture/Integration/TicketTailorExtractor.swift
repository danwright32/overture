import Foundation

// #1280 Phase 2 (#1294): makes a TicketTailor box-office venue (The Cell) a native, free source. The
// widget's embedded event JSON is already parsed by TicketTailorCalendar; this conformer maps it straight
// to ExtractedEvent so the same shows ingest for free instead of a paid AI read, exactly as
// OperaAmericaExtractor / VenueTixExtractor do for their feeds.
//
// The event fetch is injected so the whole extractor is a real unit test with no network. The convenience
// init builds the live two-hop (venue page -> discover widget -> fetch widget -> parse); a source
// discovered to embed a TicketTailor widget is routed to this extractor by the read path (#1295).
final class TicketTailorExtractor: SourceExtractor {
    private let fetchEvents: @Sendable () async throws -> [TicketTailorCalendar.TTEvent]
    private let venueName: String
    private let location: String?

    init(fetchEvents: @escaping @Sendable () async throws -> [TicketTailorCalendar.TTEvent],
         venueName: String, location: String?) {
        self.fetchEvents = fetchEvents
        self.venueName = venueName
        self.location = location
    }

    // The live reader over the two-hop. A failed fetch, or a venue page whose widget embed has vanished,
    // THROWS (never an empty list, which reconcile would read as every show cancelled), so an empty read
    // can never strike real shows.
    convenience init(pageURL: URL, venueName: String, location: String?,
                     now: Date = Date(), session: URLSession = .shared) {
        self.init(fetchEvents: { try await TicketTailorCalendar.liveEvents(pageURL: pageURL, now: now,
                                                                           session: session) },
                  venueName: venueName, location: location)
    }

    // A structured feed can only ever be "here are the upcoming events" or "there are none", so the verdict
    // is derived, never guessed (ExtractedListing.fromStructuredFeed): it can never be .allPast (it reads a
    // forward window) or .unreadable (it parses JSON, not a rendered page).
    func extract() async throws -> ExtractedListing {
        ExtractedListing.fromStructuredFeed(
            TicketTailorCalendar.extractedEvents(from: try await fetchEvents(),
                                                 venueName: venueName, location: location))
    }
}
