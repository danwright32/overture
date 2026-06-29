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
        // v1 carries no recipient discriminator; it decodes to nil under the tolerant gate.
        #expect(results.results[0].recipientId == nil)
    }

    // v2 (#392): a per-recipient discriminator ties a reply to the specific recipient it came from,
    // so a presenter reply and an act reply on the same show are classified independently rather than
    // collapsing to the first replier. naturalKey stays the show join key; recipientId is additive.
    @Test func theV2QueueCarriesTheRecipientDiscriminator() throws {
        let queue = try JSONDecoder().decode(ReplyClassifyQueue.self, from: try fixture("queue-v2.json"))
        #expect(queue.version == 2)
        #expect(queue.items[0].recipientId == "pres@presentingorg.example")
        #expect(queue.items[1].recipientId == nil)   // omitted still decodes
    }

    @Test func theV2ResultsCarryTheRecipientDiscriminator() throws {
        let results = try ReplyClassifyResultsDecoder.decode(try fixture("results-v2.json"))
        #expect(results.version == 2)
        #expect(results.results[0].recipientId == "pres@presentingorg.example")
        #expect(results.results[0].replyIntent == .wantsToBook)
    }

    @Test func theBuilderNowStampsVersion3() {
        let q = ReplyClassifyQueueBuilder.build(from: [], generatedAt: "2026-06-26T00:00:00.000Z")
        #expect(q.version == 3)
    }

    // v3 (#420): the queue now populates recipientId on every item (one item per replied recipient),
    // and the results carry an AI-drafted reply (draftSubject/draftBody) per recipient alongside the
    // non-binding intent hint. Two items can share a naturalKey with different recipientIds.
    @Test func theV3QueueHasOneItemPerRecipientWithIds() throws {
        let queue = try JSONDecoder().decode(ReplyClassifyQueue.self, from: try fixture("queue-v3.json"))
        #expect(queue.version == 3)
        let aurora = queue.items.filter { $0.naturalKey == "aurora-strings|2026-03-10|carnegie-hall" }
        #expect(aurora.count == 2)   // presenter + act, distinct recipients on one show
        #expect(Set(aurora.compactMap(\.recipientId)) == ["pres@presentingorg.example", "act@aurorastrings.example"])
        #expect(queue.items.allSatisfy { $0.recipientId != nil })
    }

    @Test func theV3ResultsCarryPerRecipientDraftAndHint() throws {
        let results = try ReplyClassifyResultsDecoder.decode(try fixture("results-v3.json"))
        #expect(results.version == 3)
        let pres = results.results.first { $0.recipientId == "pres@presentingorg.example" }
        #expect(pres?.replyIntent == .wantsToBook)
        #expect(pres?.draftSubject == "Re: Photographing Aurora Strings at Carnegie Hall")
        #expect(pres?.draftBody?.isEmpty == false)
        let act = results.results.first { $0.recipientId == "act@aurorastrings.example" }
        #expect(act?.replyIntent == .declined)
        #expect(act?.draftBody?.isEmpty == false)
    }

    // The tolerant gate still accepts v1/v2 after the v3 bump (no draft fields decode to nil).
    @Test func olderResultsStillDecodeUnderTheV3Gate() throws {
        let v1 = try ReplyClassifyResultsDecoder.decode(try fixture("results.json"))
        #expect(v1.version == 1)
        #expect(v1.results[0].draftSubject == nil)
        let v2 = try ReplyClassifyResultsDecoder.decode(try fixture("results-v2.json"))
        #expect(v2.version == 2)
        #expect(v2.results[0].draftBody == nil)
    }
}
