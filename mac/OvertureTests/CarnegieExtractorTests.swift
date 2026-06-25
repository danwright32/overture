import Testing
import Foundation
@testable import Overture

// Serves canned Algolia responses in sequence so the extractor's fetch + pagination can be
// tested without the network. One response per call, indexed by a call counter.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, body: Data)] = []
    nonisolated(unsafe) static var callCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let idx = min(Self.callCount, Self.responses.count - 1)
        let (status, body) = Self.responses.isEmpty ? (500, Data()) : Self.responses[idx]
        Self.callCount += 1
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func pageJSON(title: String, url: String, nbPages: Int) -> Data {
    Data("{\"results\":[{\"nbPages\":\(nbPages),\"hits\":[{\"title\":\"\(title)\",\"url\":\"\(url)\"}]}]}".utf8)
}

@Suite("Carnegie extractor", .serialized)
struct CarnegieExtractorTests {
    @Test func paginatesAndMapsEvents() async throws {
        StubURLProtocol.callCount = 0
        StubURLProtocol.responses = [
            (200, pageJSON(title: "Event 0", url: "/calendar/2026/07/01/a", nbPages: 2)),
            (200, pageJSON(title: "Event 1", url: "/calendar/2026/07/02/b", nbPages: 2)),
        ]
        let extractor = CarnegieExtractor(session: stubSession())
        let events = try await extractor.extract(now: Date(timeIntervalSince1970: 1782356400))
        #expect(events.map(\.title) == ["Event 0", "Event 1"])
        #expect(events[0].performanceDate == "2026-07-01")
        #expect(StubURLProtocol.callCount == 2)
    }

    @Test func throwsOnHTTPError() async {
        StubURLProtocol.callCount = 0
        StubURLProtocol.responses = [(500, Data())]
        let extractor = CarnegieExtractor(session: stubSession())
        await #expect(throws: CarnegieExtractorError.self) {
            _ = try await extractor.extract(now: Date(timeIntervalSince1970: 1782356400))
        }
    }
}
