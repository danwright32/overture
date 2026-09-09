import Testing
import Foundation
import SwiftData

// #3743: the presenter-against-venue index is built ONCE per pass, and the two whole-corpus derivations
// that need it share it.
//
// WHAT THIS IS ABOUT. `QueueModel.scope` runs two derivations that each fold every presenter and every
// venue in the store into a `ProducerGate` index: `ProducerGate.VenueBrands`, which decides which
// presenter names are really the building's own brand, and `OrgAnswerLedger.inherited`, which decides
// which shows may take an organisation's reachability answer. They built one each, over the same shows,
// in the same pass. Measured on the live store by #3741 and #3743: the index alone is 27.2 ms, which is
// 75% of the inherited term's 36.5 ms, and the venue walk was paying for an equivalent one inside its
// own 40.1 ms.
//
// COUNTED, NEVER TIMED, and counted as BUILDS rather than as calls to either derivation, because a call
// count reads the same whether the callee builds an index or reads one it was handed (L63). This is the
// same shape as #3737's `nightTimeMapBuilds` and #3738's `stagePlacements`, and the same reason.
@MainActor
@Suite("The producer index is built once per pass (#3743)")
struct ScopeBuildsOneProducerIndexTests {
    private static let corpusSize = 40

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Presenters and venues that really do fold to a range of keys, including a presenter spelled like a
    // room and one that plays several rooms, because a corpus where every presenter is unrelated to every
    // venue would exercise neither arm of the rule the index feeds.
    private static let producer = "Roaming Presenters Co"

    private func seed(_ ctx: ModelContext) -> [Prospect] {
        // "Carnegie Hall" is in the list on purpose: without a venue it can be contained in,
        // "Carnegie Hall Presents" is not a house brand and the non-vacuity floor below correctly refuses
        // the fixture. Both floors fired on the first version of this seed, which is what they are for.
        let venues = ["Weill Recital Hall", "Zankel Hall", "Merkin Hall", "Roulette", "Carnegie Hall"]
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let presenter = n % 5 == 0 ? "Weill Recital Hall"          // spelled exactly like a room
                : n % 5 == 1 ? "Carnegie Hall Presents"                 // the building's own brand
                // A genuine producer: named after no room, and playing two or more distinct ones, which
                // is what `ProducerGate.qualifies` asks. Without one, nothing inherits an answer and the
                // ledger comparison is two empty tables.
                : n % 5 == 2 ? Self.producer
                : "Ensemble \(n)"                                       // an ordinary act
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             // `n / 5` and NOT `n % 5`: the presenter above is chosen by `n % 5`, so any
                             // venue index that is also a function of `n % 5` gives every show of one
                             // presenter the SAME room, and a presenter playing one room is not a
                             // producer. That is what the non-vacuity floor caught.
                             venue: venues[(n / 5) % venues.count],
                             performanceDate: "2099-01-\(String(format: "%02d", n % 28 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            p.presenter = presenter
            ctx.insert(p)
            out.append(p)
        }
        return out
    }

    // The ledger must be NON-EMPTY, or `inheritedAnswers` returns before it would have built an index at
    // all and the count below would be one for the wrong reason (L98).
    private func answers(_ ctx: ModelContext) -> [OrgReachabilityAnswer] {
        let a = OrgReachabilityAnswer(
            // The PRODUCER's key, not a house brand's: a brand does not qualify, so an answer keyed on
            // one is inherited by nothing and the comparison below would compare two empty tables.
            orgKey: OrgKey.stored(for: Self.producer) ?? "roamingpresentersco",
            result: .emailFound, probedAt: Date(),
            sourceNaturalKey: "k2", sourceGroupName: "Show 2",
            presenterName: Self.producer,
            foundEmails: ["someone@example.invalid"])
        ctx.insert(a)
        return [a]
    }

    @Test("one scope builds one producer index")
    func oneScopeBuildsOneIndex() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let ledger = answers(ctx)

        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueModel.scope(from: shows, answers: ledger, corpus: shows, cardKeys: [])
        }

        #expect(work.producerIndexes == 1,
                Comment(rawValue: "one scope folded every presenter and venue in the store "
                        + "\(work.producerIndexes) times. Both the venue-brand table and the inherited "
                        + "answer ledger need this index and there is one of them (#3743)."))
    }

    // The floor. A scope whose ledger is empty skips the inherited answers entirely, so it builds ONE
    // index (for the venue brands) rather than none, and that is a different fact from the one above.
    // Without this, an index that stopped being built at all would satisfy nothing here and the count
    // would read as a fix (L11, L98).
    @Test("a scope with no stored answers still builds the one the venue brands need")
    func anEmptyLedgerStillBuildsTheVenueIndex() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueModel.scope(from: shows, answers: [], corpus: shows, cardKeys: [])
        }

        #expect(work.producerIndexes == 1,
                Comment(rawValue: "built \(work.producerIndexes) indexes with an empty ledger"))
    }

    // MARK: - The two VenueBrands initialisers give one answer

    // A corpus-taking initialiser that disagreed with the shows-taking one would change which presenters
    // the producer gate admits, which changes which shows Dan is offered. That is a product regression no
    // cost test could see, so it is asserted directly rather than argued for (L263).
    @Test("VenueBrands from a corpus agrees with VenueBrands from shows")
    func bothInitialisersAgree() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let gateShows = shows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }

        let fromShows = ProducerGate.VenueBrands(shows: gateShows)
        let fromCorpus = ProducerGate.VenueBrands(corpus: ProducerGate.Corpus(gateShows))

        #expect(fromShows == fromCorpus)

        // And per presenter, so the equality above cannot be satisfied by two empty tables.
        var admitted = 0
        for presenter in Set(shows.compactMap(\.presenter)) {
            #expect(fromShows.contains(presenter) == fromCorpus.contains(presenter),
                    Comment(rawValue: "the two disagree about whether \(presenter) is a venue brand"))
            #expect(fromShows.isRoomName(presenter) == fromCorpus.isRoomName(presenter),
                    Comment(rawValue: "the two disagree about whether \(presenter) is spelled like a room"))
            if fromShows.contains(presenter) { admitted += 1 }
        }
        // Non-vacuous: the corpus really does hold presenters the rule catches, or every comparison above
        // was false against false (L98).
        #expect(admitted >= 2,
                Comment(rawValue: "only \(admitted) presenters are venue brands here, so this compared "
                        + "almost nothing. The fixture must hold a room-name presenter and a house brand."))

        // And with overrides, which is the one input that can change the answer and the one a corpus does
        // not carry: it is passed to the initialiser, so both forms must honour it identically.
        let promoted = ProducerOverrides(promotedRows: [], demotedRows: [])
        #expect(ProducerGate.VenueBrands(shows: gateShows, overrides: promoted)
                == ProducerGate.VenueBrands(corpus: ProducerGate.Corpus(gateShows), overrides: promoted))
    }

    // The ledger's own two forms, for the same reason: a prebuilt corpus must give the answer the
    // freshly built one gives, or a show inherits an address it should not have.
    @Test("the inherited answers are the same with a prebuilt index and without")
    func theLedgerAgreesWithAndWithoutAPrebuiltIndex() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let ledger = answers(ctx)
        let now = Date()

        let withoutIndex = QueueModel.inheritedAnswers(ledger, corpus: shows, overrides: .none,
                                                       refusals: .none, heldKeys: [], now: now)
        let withIndex = QueueModel.inheritedAnswers(
            ledger, corpus: shows, overrides: .none, refusals: .none, heldKeys: [], now: now,
            producerCorpus: ProducerGate.Corpus(shows.map {
                ProducerGate.Show(presenter: $0.presenter, venue: $0.venue)
            }))

        #expect(withoutIndex.keys.sorted() == withIndex.keys.sorted())
        for key in withoutIndex.keys {
            #expect(withoutIndex[key] == withIndex[key],
                    Comment(rawValue: "the two forms give \(key) different inherited answers"))
        }
        // Non-vacuous: something really did inherit, or both were empty and this compared nothing.
        #expect(!withoutIndex.isEmpty,
                "no show inherited an answer, so this compared two empty tables (L98)")
    }
}
