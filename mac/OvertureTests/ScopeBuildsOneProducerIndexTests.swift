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

    // MARK: - #3742: each distinct NAME is folded once, not once per show

    // `ProducerGate.key` runs a regex plus a Unicode fold plus several trims. The index asked it twice
    // per show, and a venue hosts many shows while a presenter presents many, so on the live store that
    // was about 2,460 calls over roughly 514 distinct strings. Measured after the memo: the index falls
    // from 27.9 ms to 12.1 ms.
    //
    // Pinned as FOLDS rather than as index builds, because #3743's count cannot see this at all: a build
    // that folds every show's name and one that folds every distinct name are the same number of builds
    // and five times the work (L63).
    @Test("building the index folds each distinct name once, not once per show")
    func eachNameIsFoldedOnce() {
        // Few names over many shows, deliberately: a fixture where every show carries a distinct
        // presenter cannot tell the two behaviours apart at all, because then the counts coincide (L101).
        let venues = ["Weill Recital Hall", "Zankel Hall", "Merkin Hall", "Roulette"]
        let presenters = ["Roaming Presenters Co", "Carnegie Hall Presents", "Downtown Music Inc"]
        let shows = (0..<60).map {
            ProducerGate.Show(presenter: presenters[$0 % presenters.count],
                              venue: venues[$0 % venues.count])
        }
        let distinctNames = Set(venues + presenters).count

        let work = QueueRenderPass.WorkTally.measure { _ = ProducerGate.Corpus(shows) }

        #expect(work.producerKeyFolds == distinctNames,
                Comment(rawValue: "building the index folded \(work.producerKeyFolds) names over "
                        + "\(shows.count) shows carrying \(distinctNames) distinct names. Two per show "
                        + "would be \(shows.count * 2), and each fold is a regex plus a Unicode fold "
                        + "(#3742)."))
    }

    // And the cost does not grow with the number of SHOWS, which is the claim one fixture size cannot
    // make (L354).
    @Test("the fold count does not grow with the number of shows")
    func theFoldCountIsFlatInTheShowCount() {
        func folds(showCount: Int) -> Int {
            let shows = (0..<showCount).map {
                ProducerGate.Show(presenter: $0 % 2 == 0 ? "Roaming Presenters Co" : "Downtown Music Inc",
                                  venue: "Weill Recital Hall")
            }
            return QueueRenderPass.WorkTally.measure { _ = ProducerGate.Corpus(shows) }.producerKeyFolds
        }

        #expect(folds(showCount: 4) == folds(showCount: 400),
                Comment(rawValue: "4 shows folded \(folds(showCount: 4)) names and 400 folded "
                        + "\(folds(showCount: 400)). The cost is a function of how many shows there are "
                        + "rather than how many names (#3742)."))
    }

    // The memo must not change the ANSWER, which the count above cannot see. Asserted over a corpus
    // holding two spellings that fold to ONE key, which is the case a memo keyed on the raw string has to
    // get right: two different strings, one key, and the second must not read the first's cache entry.
    @Test("folding once gives the same index as folding every time")
    func theMemoDoesNotChangeTheAnswer() {
        let shows = [
            ProducerGate.Show(presenter: "The Roaming Presenters Co", venue: "Weill Recital Hall"),
            ProducerGate.Show(presenter: "Roaming Presenters Co", venue: "Zankel Hall"),
            ProducerGate.Show(presenter: "Roaming Presenters Co (touring)", venue: "Merkin Hall"),
            ProducerGate.Show(presenter: nil, venue: "Roulette"),
            ProducerGate.Show(presenter: "Downtown Music Inc", venue: nil),
        ]
        let corpus = ProducerGate.Corpus(shows)

        // All three spellings fold to one key, so the presenter plays three rooms rather than one each.
        let key = try! #require(ProducerGate.key("Roaming Presenters Co"))
        #expect(corpus.distinctVenueCount(key) == 3,
                Comment(rawValue: "the three spellings resolved to \(corpus.distinctVenueCount(key)) "
                        + "rooms. They fold to one key, so they are one presenter playing three."))
        // A presenter whose shows name no readable room is present with no rooms, never absent, which is
        // this type's own documented rule and the one a memo returning a stale nil would break.
        let noRooms = try! #require(ProducerGate.key("Downtown Music Inc"))
        #expect(corpus.distinctVenueCount(noRooms) == 0)
        // And a name the corpus never saw is also zero, so the line above is not simply the default.
        #expect(corpus.distinctVenueCount("nobodyatall") == 0)
        #expect(corpus.presenterKeys.count == 2,
                Comment(rawValue: "the index holds \(corpus.presenterKeys.count) presenters; three "
                        + "spellings of one plus one other is two"))
    }

    // #3742: the same fold-per-row shape, in the OTHER whole-corpus function that counts by organisation.
    //
    // `QueueModel.organisationRowCounts` is handed one entry per show in the store and folded every one,
    // where an organisation presents many of them. It is a third of the size of the index's version of
    // this (10.0 ms against 27.9) and is the same defect, so it is guarded the same way.
    @Test("counting an organisation's rows folds each distinct name once")
    func organisationRowCountsFoldsEachNameOnce() {
        // Few names over many rows, for the reason the index's own test gives: where every row carries a
        // distinct presenter the two behaviours produce the same count and the test proves nothing (L101).
        let presenters = ["Roaming Presenters Co", "Downtown Music Inc", "Carnegie Hall Presents"]
        let rows: [String?] = (0..<120).map { presenters[$0 % presenters.count] }

        let work = QueueRenderPass.WorkTally.measure { _ = QueueModel.organisationRowCounts(rows) }

        #expect(work.producerKeyFolds == presenters.count,
                Comment(rawValue: "counting folded \(work.producerKeyFolds) names over \(rows.count) rows "
                        + "carrying \(presenters.count) distinct ones. One per row would be \(rows.count), "
                        + "and each fold is a regex plus a Unicode fold (#3742)."))
    }

    // The count it returns is unchanged, which the fold count cannot see. Asserted over rows where two
    // spellings fold to ONE key, which is the case a memo keyed on the raw string has to get right: they
    // must be counted together, and the second must not read the first's cache entry.
    @Test("counting is unchanged by folding once")
    func organisationRowCountsGivesTheSameAnswer() {
        let rows: [String?] = ["The Roaming Presenters Co", "Roaming Presenters Co",
                               "Roaming Presenters Co (touring)", "Downtown Music Inc", nil, ""]

        let counts = QueueModel.organisationRowCounts(rows)

        let key = try! #require(ProducerGate.key("Roaming Presenters Co"))
        #expect(counts[key] == 3,
                Comment(rawValue: "the three spellings counted as \(counts[key] ?? 0) rows; they fold to "
                        + "one key, so they are one organisation with three"))
        let other = try! #require(ProducerGate.key("Downtown Music Inc"))
        #expect(counts[other] == 1)
        // A nil and an empty presenter are counted under no key at all, never under an empty one, which
        // is what `ProducerGate.key` returning nil means and what a memo could quietly turn into a "" key.
        #expect(counts[""] == nil)
        #expect(counts.count == 2,
                Comment(rawValue: "the table holds \(counts.count) organisations; three spellings of one "
                        + "plus one other is two"))
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
