import Foundation

// What the scout-extract run hands back (#799): per source, the events it read off the pinned listings
// page, and its VERDICT on that page.
//
// The verdict is the reason this file exists in this shape rather than as a bare list of events. An
// empty event list is ambiguous, and the #770 spike found all three readings live in the wild:
// a healthy calendar with nothing on until autumn (5 of its 7 sites, in July), a page that is simply
// the WRONG one (HTTP 200, full of 2021 dates), and a page whose calendar is drawn by JavaScript so
// the bytes carry no events at all. They need opposite responses, and `[]` cannot tell them apart.
// Without the verdict, "the source is quiet" and "the source is broken" look identical to Dan, which
// is the single thing he said must never happen.
//
// `note` is the run's own one-liner about what made a page hard. It is for Dan to read, never parsed.
struct ScoutExtractResults: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var results: [ScoutExtractResult]

    // Only the events the run actually attributed to THIS source. An id the app never queued (a key
    // the run rebuilt instead of echoing) resolves to nothing at all, rather than to somebody else's
    // events: a silent mismatch must read as absence, never as the wrong show.
    func events(for sourceId: String) -> [ExtractedEvent] {
        results.first { $0.sourceId == sourceId }?.events.map(\.asExtractedEvent) ?? []
    }

    func verdict(for sourceId: String) -> PageVerdict? {
        results.first { $0.sourceId == sourceId }?.verdict
    }
}

struct ScoutExtractResult: Codable, Equatable, Sendable {
    var sourceId: String          // echoed verbatim from the queue
    var verdict: PageVerdict
    var events: [ScoutExtractEvent]
    var note: String?             // for Dan to read, never parsed
}

// The wire shape of one event. Deliberately mirrors `ExtractedEvent` field for field, and converts
// straight across: the whole point of #799 is ONE pipeline, so an agent-read event and a Carnegie-read
// event must be the same thing by the time anything downstream sees it. If this ever needs a real
// translation layer, the contract has drifted and the two pipelines have started to grow apart.
struct ScoutExtractEvent: Codable, Equatable, Sendable {
    var title: String
    var presenter: String?
    var venue: String?
    var performanceDate: String?
    var sourceUrl: String?

    var asExtractedEvent: ExtractedEvent {
        ExtractedEvent(title: title, presenter: presenter, venue: venue,
                       performanceDate: performanceDate, sourceUrl: sourceUrl)
    }
}

enum ScoutExtractResultsDecoder {
    static func decode(_ data: Data) throws -> ScoutExtractResults {
        try JSONDecoder().decode(ScoutExtractResults.self, from: data)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-scout-extract-results.json")
    }
}
