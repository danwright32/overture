import Testing
import Foundation
@testable import Overture

// #1965, measured with `sample` against the live Release build on 2026-08-01: of 4,588 main-thread
// samples inside QueueView.body over 30 seconds, `OrgAnswerLedger.inherited` took 487 and the
// `ProducerGate.venueKeys` work it drives took a further 389.
//
// Deciding whether an organisation is a producer asks two questions of the whole corpus, whether its
// name is really the building's, and how many distinct rooms it plays. Both were answered by walking
// every show again, once per organisation, inside a pass that already walks every show.
//
// Both are now computed once for the whole corpus and asked per organisation. The rule is unchanged, and
// these compare it against the walk it replaces rather than asserting that it is.
@Suite("The producer questions are answered from one pass over the corpus (#1965)")
struct ProducerGateCorpusTests {

    // The rooms this presenter plays, worked out by walking every show, which is what the corpus value
    // replaces. The reference the precomputed one has to agree with.
    private func walkedDistinctVenues(_ presenterKey: String, among shows: [ProducerGate.Show]) -> Set<String> {
        Set(shows.compactMap { show -> String? in
            guard ProducerGate.key(show.presenter) == presenterKey else { return nil }
            return ProducerGate.key(show.venue)
        })
    }

    // The verdict as the per-question walk expressed it: the venue keys rebuilt for this question, and
    // the rooms counted by walking every show again. Written out here rather than called, because the
    // entry point that used to do this now asks the precomputed corpus, so comparing the two shapes of
    // the shipping code would be comparing it against itself.
    private func walkedQualifies(_ presenter: String, among shows: [ProducerGate.Show],
                                 overrides: ProducerOverrides = .none) -> Bool {
        guard let presenterKey = ProducerGate.key(presenter) else { return false }
        guard !ProducerGate.isVenueBrand(presenterKey, venueKeys: ProducerGate.venueKeys(of: shows),
                                         overrides: overrides) else { return false }
        if overrides.promoted.contains(presenterKey) { return true }
        return walkedDistinctVenues(presenterKey, among: shows).count >= 2
    }

    private let shows: [ProducerGate.Show] = [
        // One company, three rooms: a producer by the venue count.
        .init(presenter: "Heartbeat Opera", venue: "Baruch Performing Arts Center"),
        .init(presenter: "Heartbeat Opera", venue: "Roulette Intermedium"),
        .init(presenter: "Heartbeat Opera", venue: "The Green Room 42"),
        // One company, one room, twice: not a producer by the count.
        .init(presenter: "Aurora Strings", venue: "SoHo Playhouse"),
        .init(presenter: "Aurora Strings", venue: "SoHo Playhouse"),
        // The house's own presenting brand, in three of its rooms: refused whatever the count says.
        .init(presenter: "Carnegie Hall Presents", venue: "Carnegie Hall"),
        .init(presenter: "Carnegie Hall Presents", venue: "Zankel Hall"),
        .init(presenter: "Carnegie Hall Presents", venue: "Merkin Hall"),
        // A presenter spelled exactly like a room.
        .init(presenter: "Bargemusic", venue: "Bargemusic"),
        // A show naming no presenter at all, and one naming no venue.
        .init(presenter: nil, venue: "The Tank"),
        .init(presenter: "Spit&Vigor", venue: nil),
    ]

    private var presenters: [String] {
        Array(Set(shows.compactMap { $0.presenter }))
    }

    @Test func theRoomCountMatchesWalkingEveryShow() {
        let corpus = ProducerGate.Corpus(shows)
        for presenter in presenters {
            guard let key = ProducerGate.key(presenter) else { continue }
            #expect(corpus.distinctVenueCount(key) == walkedDistinctVenues(key, among: shows).count,
                    "disagreed about \(presenter)")
        }
        // The corpus really does hold a company playing several rooms, so the agreement above is not
        // every answer being zero.
        #expect(corpus.distinctVenueCount(ProducerGate.key("Heartbeat Opera") ?? "") == 3)
    }

    // A presenter whose only show names no venue has no rooms to count, and must not read as one room.
    @Test func aPresenterWithNoReadableRoomCountsNone() {
        let corpus = ProducerGate.Corpus(shows)
        #expect(corpus.distinctVenueCount(ProducerGate.key("Spit&Vigor") ?? "") == 0)
    }

    // A name nobody in the corpus presents is not an error and not a producer.
    @Test func aPresenterTheCorpusNeverSawCountsNone() {
        let corpus = ProducerGate.Corpus(shows)
        #expect(corpus.distinctVenueCount("a name nobody presents") == 0)
    }

    @Test func theVerdictMatchesTheOnePerQuestionWalk() {
        let corpus = ProducerGate.Corpus(shows)
        for presenter in presenters {
            #expect(ProducerGate.qualifies(presenter, in: corpus)
                    == walkedQualifies(presenter, among: shows),
                    "disagreed about \(presenter)")
        }
        // Both arms fire somewhere in this corpus, so neither is being agreed about vacuously.
        #expect(ProducerGate.qualifies("Heartbeat Opera", in: corpus))
        #expect(!ProducerGate.qualifies("Aurora Strings", in: corpus))
        #expect(!ProducerGate.qualifies("Carnegie Hall Presents", in: corpus))
        #expect(!ProducerGate.qualifies("Bargemusic", in: corpus))
    }

    // Dan's corrections read the same from either shape, including the one that only he can move: a
    // promotion clears the containment arm and the venue count, and never the equality arm.
    @Test func theVerdictMatchesUnderCorrections() {
        let corpus = ProducerGate.Corpus(shows)
        let overrides = ProducerOverrides(promoted: [ProducerGate.key("Carnegie Hall Presents") ?? "",
                                                     ProducerGate.key("Bargemusic") ?? "",
                                                     ProducerGate.key("Aurora Strings") ?? ""],
                                          demoted: [ProducerGate.key("Heartbeat Opera") ?? ""])
        for presenter in presenters {
            #expect(ProducerGate.qualifies(presenter, in: corpus, overrides: overrides)
                    == walkedQualifies(presenter, among: shows, overrides: overrides),
                    "disagreed about \(presenter)")
        }
        // A promotion moves the count arm, and cannot move the equality arm.
        #expect(ProducerGate.qualifies("Aurora Strings", in: corpus, overrides: overrides))
        #expect(!ProducerGate.qualifies("Bargemusic", in: corpus, overrides: overrides))
    }
}
