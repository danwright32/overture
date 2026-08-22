import Foundation

enum CarnegieExtractorError: Error { case badResponse }

// Pulls the next [[AlgoliaCalendar.windowDays]] days of Carnegie performances by querying the venue's
// public Algolia calendar index directly (see AlgoliaCalendar). Replaces the old hidden-WebKit DOM
// scrape, which only ever saw the ~3 days the /events page renders at once.
//
// #2521: that window is deliberately WIDER than the queue's display window rather than equal to it, so
// a show is in the store before Dan can act on it. The reasoning lives at the constant.
//
// #799: now the first conformer of `SourceExtractor`, so the scout iterates sources instead of naming
// this one. It KEEPS its Algolia path rather than being pushed through the generic HTML extractor:
// the index answers for the whole window we ask of it and the rendered page exposes about three days,
// so "removing the special case" for purity would cost nearly all of that lead time. Carnegie needs a
// source ROW, not a shared parser.
final class CarnegieExtractor: SourceExtractor {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // A structured feed can only ever be "here are the upcoming events" or "there are none", so the
    // verdict is derived rather than guessed (ExtractedListing.fromStructuredFeed). It can never
    // report .allPast (it queries a forward window) or .unreadable (it parses JSON, not a rendered
    // page), and it must not pretend otherwise: those verdicts route source health.
    func extract() async throws -> ExtractedListing {
        ExtractedListing.fromStructuredFeed(try await extractEvents())
    }

    func extractEvents(now: Date = Date()) async throws -> [ExtractedEvent] {
        let (start, end) = AlgoliaCalendar.windowBoundsMs(today: now)
        var all: [ExtractedEvent] = []
        var page = 0
        while page < AlgoliaCalendar.maxPages {
            let (events, nbPages) = try await fetchPage(startMs: start, endMs: end, page: page)
            all.append(contentsOf: events)
            page += 1
            if page >= nbPages { break }
        }
        return all
    }

    private func fetchPage(startMs: Int, endMs: Int, page: Int) async throws -> (events: [ExtractedEvent], nbPages: Int) {
        var request = URLRequest(url: AlgoliaCalendar.endpoint)
        request.httpMethod = "POST"
        request.setValue(AlgoliaCalendar.apiKey, forHTTPHeaderField: "x-algolia-api-key")
        request.setValue(AlgoliaCalendar.appID, forHTTPHeaderField: "x-algolia-application-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = AlgoliaCalendar.requestBody(startMs: startMs, endMs: endMs, page: page)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CarnegieExtractorError.badResponse
        }
        return AlgoliaCalendar.parse(data)
    }
}
