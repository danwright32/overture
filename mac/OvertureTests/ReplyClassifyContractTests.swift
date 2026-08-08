import Testing
import Foundation

// The two reply-classification handoff contracts (#183), guarded by committed fixtures like the
// #157 files. The app WRITES overture-reply-classify-queue.json (ReplyClassifyQueueBuilder) and the
// Claude Code classify workflow WRITES overture-reply-classify-results.json, which the app READS
// (ReplyClassifyResultsDecoder). The workflow is the counterpart with no automated test, so these
// fixtures are its spec; the contract tests pin the Swift side and that naturalKey is echoed verbatim.
@Suite("Reply classify contract fixtures")
struct ReplyClassifyContractTests {
    private func fixtureDirectory() -> URL {
        RepoRoot.url
            .appendingPathComponent("fixtures/reply-classify")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491/#744: enumerates whatever is actually committed, so a new fixture file with no
    // matching decode case fails here instead of silently shipping with zero coverage on this side.
    // The directory holds both queue and results fixtures side by side, told apart by filename
    // prefix the way the rest of this suite already does.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names.filter({ $0.hasPrefix("queue") }) {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try JSONDecoder().decode(ReplyClassifyQueue.self, from: data)
            }
        }
        for name in names.filter({ $0.hasPrefix("results") }) {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try ReplyClassifyResultsDecoder.decode(data)
            }
        }
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

    // #438: a draft must never ask for a field Overture already holds. The reply-classify queue carried
    // venue but NOT the performance date, which is why a reply draft asked "let me know the date." v3 now
    // carries performanceDate so the draft can name the actual date; an undated show omits it.
    @Test func theV3QueueCarriesThePerformanceDate() throws {
        let queue = try JSONDecoder().decode(ReplyClassifyQueue.self, from: try fixture("queue-v3.json"))
        let aurora = queue.items.filter { $0.naturalKey == "aurora-strings|2026-03-10|carnegie-hall" }
        #expect(aurora.allSatisfy { $0.performanceDate == "2026-03-10" })
        let lumen = queue.items.first { $0.naturalKey == "lumen-dance|undated|none" }
        #expect(lumen?.performanceDate == nil)   // undated show omits it; still decodes
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

    // MARK: - Negative paths (#747)
    //
    // The enumeration guard only proves every committed fixture decodes. It says nothing about
    // whether a BAD file would be rejected, and a guard that cannot fail is not a guard. Mirrors the
    // rejection cases the TypeScript side has had since #509 (src/lib/fixtureShape.test.ts).

    private func decoding(_ json: String) throws -> ReplyClassifyResults {
        try ReplyClassifyResultsDecoder.decode(Data(json.utf8))
    }

    @Test func aVersionOutsideTheSupportedRangeIsRejected() {
        #expect(throws: ReplyClassifyResultsError.unsupportedVersion(99)) {
            try decoding(#"{"version":99,"generatedAt":"now","results":[]}"#)
        }
        #expect(throws: ReplyClassifyResultsError.unsupportedVersion(0)) {
            try decoding(#"{"version":0,"generatedAt":"now","results":[]}"#)
        }
    }

    @Test func aResultMissingItsNaturalKeyIsRejected() {
        #expect(throws: (any Error).self) {
            try decoding(#"{"version":3,"generatedAt":"now","results":[{"intent":"interested"}]}"#)
        }
    }

    // intent is deliberately a plain String so an UNKNOWN value still decodes (it is a non-binding
    // hint, never an auto-resolution). Its absence is a different matter: the result exists to carry
    // one, so a result without it is malformed, not merely unrecognized.
    @Test func anUnknownIntentStillDecodesButAMissingOneDoesNot() throws {
        let unknown = try decoding(
            #"{"version":3,"generatedAt":"now","results":[{"naturalKey":"k","intent":"who_knows"}]}"#)
        #expect(unknown.results[0].intent == "who_knows")
        #expect(unknown.results[0].replyIntent == nil)   // unrecognized, so no binding intent

        #expect(throws: (any Error).self) {
            try decoding(#"{"version":3,"generatedAt":"now","results":[{"naturalKey":"k"}]}"#)
        }
    }

    @Test func garbageIsRejectedRatherThanReadAsEmpty() {
        #expect(throws: (any Error).self) { try decoding("not json") }
    }
}
