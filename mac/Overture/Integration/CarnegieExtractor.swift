import Foundation

enum CarnegieExtractorError: Error { case badResponse }

// Pulls the next ~90 days of Carnegie performances by querying the venue's public Algolia
// calendar index directly (see AlgoliaCalendar). Replaces the old hidden-WebKit DOM scrape,
// which only ever saw the ~3 days the /events page renders at once. Keeps the same async
// `extract()` surface so ScoutService is unchanged.
final class CarnegieExtractor {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func extract(now: Date = Date()) async throws -> [ExtractedEvent] {
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
