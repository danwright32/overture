import Testing
import Foundation
import SwiftData

// #3654 Phase 4: a card is built for a show something is about to draw, and for no other show.
//
// WHAT THIS IS ABOUT. A card costs the send grouping, the recipient snapshots and a draft lint pass over
// every pending contact's body; the queue built one for every show in scope on every redraw and then used
// all of it for the eight rows on screen. #3653 gave every whole-scope sweep a cheap row instead, which is
// what made narrowing the cards legal. This is the narrowing.
//
// THE ORDERING CONTRACT, because "zero misses" is false by construction and pretending otherwise would
// make the guard fire on the ordinary case (L93). The card map is computed BEFORE the body renders; which
// rows a `LazyVStack` realizes is discovered DURING it. So the first frame of a newly drawn or newly
// scrolled surface asks for keys nobody predicted. Those build on the spot, so the render is always
// correct, and they are counted SEPARATELY from a request for a key the pass believed it had built, which
// is a real defect and is pinned at zero (L11).
@MainActor
@Suite("Cards are built for the rows that render, and misses are told apart (#3654)")
struct CardsOnlyForWhatRendersTests {
    private static let corpusSize = 60

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// A corpus shaped like the live store rather than a uniform one: `LiveContactShape` records that 962
    /// of the live store's 1,224 rows carry no contact at all, and the contact-derived fields are exactly
    /// the expensive half a narrowed build stops paying for (L102, L48).
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: "Room \(n % 5)",
                             performanceDate: "2099-01-\(String(format: "%02d", n % 28 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: n % 2 == 0 ? "high" : "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            ctx.insert(p)
            if n % 4 == 0 {
                let r = Recipient(id: "c\(n)@example.invalid", email: "c\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = .pending
                p.recipients.append(r)
            }
            out.append(p)
        }
        return out
    }

    private func inputs(_ rows: [Prospect], cardKeys: Set<String>? = nil,
                        registry: QueueModel.CardKeyRegistry? = nil) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: StageContext(now: Date(timeIntervalSince1970: 4_070_908_800),
                                  geo: .none, clients: .none),
            requestedCardKeys: cardKeys, cardKeyRegistry: registry)
    }

    // THE phase. A pass asked for three shows builds three cards, not sixty.
    @Test func aNarrowedPassBuildsCardsOnlyForTheKeysItWasAsked() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let wanted: Set<String> = ["k1", "k2", "k3"]

        let work = QueueRenderPass.WorkTally.measure {
            let data = QueueRenderPass.make(inputs(shows, cardKeys: wanted))
            #expect(data.rows.count == Self.corpusSize, "the rows are still every show in scope")
            #expect(data.cards.builtCount == wanted.count)
            for key in wanted { #expect(data.cards.alreadyBuilt(key) != nil) }
            #expect(data.cards.alreadyBuilt("k9") == nil)
        }

        #expect(work.queueItems == wanted.count)
        #expect(work.queueRows == Self.corpusSize)
        // THE CLAIM THAT MATTERS MOST, and the one a narrowing could quietly break: the contacts are
        // still read exactly once per show in scope. A build that read them again to make a card would
        // have moved the cost rather than removed it, and every count above would still look right.
        #expect(work.recipientReaches == Self.corpusSize)
    }

    // The unnarrowed arm is unchanged, which is what `items(from:)` and Archive still take.
    @Test func aPassAskedForNothingInParticularStillBuildsEveryCard() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure {
            let data = QueueRenderPass.make(inputs(shows))
            #expect(data.cards.builtCount == Self.corpusSize)
        }

        #expect(work.queueItems == Self.corpusSize)
        #expect(work.recipientReaches == Self.corpusSize)
    }

    // 4b, the accounting identity, over a pass and the frame that follows it.
    @Test func theAccountingIdentityHoldsAcrossAFrame() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let wanted: Set<String> = ["k1", "k2", "k3"]
        let data = QueueRenderPass.make(inputs(shows, cardKeys: wanted))

        // The frame draws the three it was asked for and one it was not, which is what a scroll does.
        let drawn = data.rows.filter { wanted.contains($0.id) || $0.id == "k9" }
        for row in drawn { _ = data.cards.card(for: row) }

        #expect(data.rows.count == Self.corpusSize)
        #expect(data.cards.builtCount == wanted.count + data.cards.expectedFirstFrameMisses)
        #expect(data.cards.expectedFirstFrameMisses == 1)
        #expect(data.cards.unexpectedCardMisses == 0)
    }

    // A row the pass was not asked for still DRAWS, and correctly. Fail-safe as well as fail-loud: never
    // an empty card, never a placeholder standing in for a value the row needs (L67).
    @Test func aRowThePassWasNotAskedForBuildsOnTheSpot() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let data = QueueRenderPass.make(inputs(shows, cardKeys: ["k1"]))
        let unasked = try #require(data.rows.first { $0.id == "k9" })

        let built = data.cards.card(for: unasked)

        #expect(built.id == "k9")
        // The same card the pass would have made, not a thinner one: the whole-corpus tables it is
        // decorated from are the pass's own, which is why they are kept on the store.
        let full = try #require(QueueRenderPass.make(inputs(shows)).cards.alreadyBuilt("k9"))
        #expect(built == full)
        #expect(data.cards.expectedFirstFrameMisses == 1)
        #expect(data.cards.unexpectedCardMisses == 0)
    }

    // The other kind. A request for a key the pass BELIEVED it had built is a defect in the key set, and
    // it must not read as an ordinary scroll arriving early.
    @Test func aRowThePassBelievedItHadBuiltIsAnUnexpectedMiss() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let data = QueueRenderPass.make(inputs(shows, cardKeys: ["k1"]))
        let row = try #require(data.rows.first { $0.id == "k1" })
        // A store that was asked for k1 and holds no card for it, which is the state the identity pins
        // against. Built directly, because a pass cannot produce it: that is the point of pinning it.
        let broken = QueueModel.CardStore(cards: [:], shows: shows, contactsByKey: [:],
                                          preamble: QueueModel.CardPreamble(
                                            linked: [:], inherited: [:],
                                            venueBrands: ProducerGate.VenueBrands(shows: [],
                                                                                  overrides: .none),
                                            rowCounts: [:], calendarBySourceId: [:], overrides: .none,
                                            clients: .none, now: Date(), day: "2099-01-01"),
                                          requestedKeys: ["k1"])

        _ = broken.card(for: row)

        #expect(broken.unexpectedCardMisses == 1)
        #expect(broken.expectedFirstFrameMisses == 0)
        _ = data
    }

    // The registry is what carries frame N's keys to frame N+1, and it is EMPTIED by the reading. Left to
    // accumulate it would hold every key Dan has scrolled past since launch, so the set the next pass
    // prebuilt would grow back into the whole stage and the saving would disappear with nothing saying so
    // (L289).
    @Test func theRegistryRecordsWhatWasDrawnAndIsEmptiedByReadingIt() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let registry = QueueModel.CardKeyRegistry()
        let data = QueueRenderPass.make(inputs(shows, cardKeys: [], registry: registry))

        for row in data.rows.prefix(4) { _ = data.cards.card(for: row) }

        #expect(registry.keys == Set(data.rows.prefix(4).map(\.id)))
        #expect(registry.takeKeys().count == 4)
        #expect(registry.keys.isEmpty, "a second pass would prebuild what the frame before it drew twice")
    }

    // A HIT records the key exactly as a miss does, and that is the whole mechanism rather than a detail.
    // Recording only on the miss path would empty the request set the moment the prebuild started
    // working: the next pass would prebuild nothing, every row would miss, and the two states would
    // alternate forever while every counter looked reasonable.
    @Test func aHitRecordsTheKeyJustAsAMissDoes() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let registry = QueueModel.CardKeyRegistry()
        let data = QueueRenderPass.make(inputs(shows, cardKeys: ["k1"], registry: registry))
        let hit = try #require(data.rows.first { $0.id == "k1" })

        _ = data.cards.card(for: hit)

        #expect(data.cards.expectedFirstFrameMisses == 0, "k1 was prebuilt, so this was a hit")
        #expect(registry.keys == ["k1"])
    }
}
