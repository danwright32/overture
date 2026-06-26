import Testing
import Foundation
@testable import Overture

// The two reply-classification handoff contracts (#183), guarded by committed fixtures like the
// #157 files. The app WRITES overture-reply-classify-queue.json (ReplyClassifyQueueBuilder) and the
// Claude Code classify workflow WRITES overture-reply-classify-results.json, which the app READS
// (ReplyClassifyResultsDecoder). The workflow is the counterpart with no automated test, so these
// fixtures are its spec; the contract tests pin the Swift side and that naturalKey is echoed verbatim.
@Suite("Reply classify contract fixtures")
struct ReplyClassifyContractTests {
    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/reply-classify/\(name)"))
    }

    @Test func replyIntentMapsToConversationState() {
        #expect(ReplyIntent.interested.conversationState == .interested)
        #expect(ReplyIntent.wantsToBook.conversationState == .wantsToBook)
        #expect(ReplyIntent.hasQuestion.conversationState == .hasQuestion)
        #expect(ReplyIntent.declined.conversationState == .declined)
    }

    // The exact model the queue fixture encodes: one item with a venue, one with it omitted.
    private let expectedQueue = ReplyClassifyQueue(
        version: 1,
        generatedAt: "2026-06-26T00:00:00.000Z",
        items: [
            ReplyClassifyItem(naturalKey: "aurora-strings|2026-03-10|carnegie-hall",
                              groupName: "Aurora Strings", venue: "Carnegie Hall",
                              replyText: "Yes, we'd like to book."),
            ReplyClassifyItem(naturalKey: "lumen-dance|undated|none",
                              groupName: "Lumen Dance", venue: nil,
                              replyText: "Could you send your rate?"),
        ]
    )

    @Test func theQueueFixtureMatchesWhatTheBuilderEncodes() throws {
        let decoded = try JSONDecoder().decode(ReplyClassifyQueue.self, from: try fixture("queue.json"))
        #expect(decoded == expectedQueue)
    }

    @Test func theQueueBuilderRoundTrips() throws {
        let data = try ReplyClassifyQueueBuilder.encode(expectedQueue)
        #expect(try JSONDecoder().decode(ReplyClassifyQueue.self, from: data) == expectedQueue)
    }

    @Test func theResultsFixtureDecodesToTheAgreedShape() throws {
        let results = try ReplyClassifyResultsDecoder.decode(try fixture("results.json"))
        #expect(results.version == 1)
        #expect(results.results.count == 2)
        #expect(results.results[0].naturalKey == "aurora-strings|2026-03-10|carnegie-hall")
        #expect(results.results[0].replyIntent == .wantsToBook)
        #expect(results.results[1].naturalKey == "lumen-dance|undated|none")
        #expect(results.results[1].replyIntent == .hasQuestion)
    }
}
