import Testing
import Foundation
import SwiftData

// #2998: notice a run card whose nights are all already covered by separate cards.
//
// A weekly series can be stored BOTH as one run carrying every night AND as separate cards for single
// nights, so a run card can be wholly redundant with cards that already exist. `dropNight` already
// discovers this, but only when Dan drops a night, and then only to refuse or close: nothing looks.
//
// The DIRECTION was adjusted on 2026-09-20 after a re-check found ZERO fully covered runs in the store:
// build the detection and a live store report now, and hold the card control until the count is not
// zero, since a control built for a state nobody is in ships inert (L543).
//
// ONE mechanism detail decides the whole predicate, and it is easy to get wrong. A run card HOLDS its
// own opening night under its own natural key, and `keyAvailability` deliberately answers `.free` for a
// row's own key (`holder === self`). So "is every night of this run taken" can never be true, and a check
// written that way ships silently inert even on the day a real covered run exists. The question is the
// one `dropNight` already asks: is every night OTHER THAN THE OPENING held by another card. Asked here
// through the same `keyAvailability`, so the detector and the drop cannot disagree about what "another
// card holds this night" means (L16).
@MainActor
@Suite("A run whose other nights are all on other cards is noticed (#2998)")
struct FullyCoveredRunTests {

    private static let venue = "The Players Theatre"
    private static let title = "Fresh Out The Box"

    private func key(_ night: String) -> String {
        Prospect.makeNaturalKey(groupName: Self.title, performanceDate: night, venue: Self.venue)
    }

    private func run(nights: [String]) -> Prospect {
        let p = Prospect(naturalKey: key(nights.first!), groupName: Self.title, discipline: "comedy",
                         venue: Self.venue, performanceDate: nights.first, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runNights = nights
        return p
    }

    private struct StoreIsDown: Error {}

    // THE CASE. Every night past the opening has its own card, so the run carries nothing of its own.
    @Test func arunWhoseOtherNightsAreAllOnOtherCardsIsFullyCovered() {
        let r = run(nights: ["2026-11-14", "2026-11-21", "2026-11-28"])
        let twin = run(nights: ["2026-11-21"])
        let held: Set<String> = [key("2026-11-21"), key("2026-11-28")]

        #expect(r.coverageOfItsOtherNights(lookup: { held.contains($0) ? twin : nil }) == .fullyCovered)
    }

    // THE TRAP, pinned so it cannot come back. The opening night is the run's OWN key, and a lookup
    // returning the run itself for it must read as "not another card". A predicate that asked about the
    // opening would answer this run as uncovered for ever.
    @Test func therunsOwnOpeningNightIsNeverCountedAsCoverOrAsAGap() {
        let r = run(nights: ["2026-11-14", "2026-11-21"])
        let twin = run(nights: ["2026-11-21"])

        let answer = r.coverageOfItsOtherNights(lookup: { k in
            k == self.key("2026-11-14") ? r : (k == self.key("2026-11-21") ? twin : nil)
        })
        #expect(answer == .fullyCovered,
                "the run's own opening night was treated as a night another card must hold")
    }

    // Partial is its own answer. 14 runs are in this state today and it is NOT this issue: the run still
    // carries nights of its own, so retiring it would lose them.
    @Test func arunWithOneNightOfItsOwnIsOnlyPartiallyCovered() {
        let r = run(nights: ["2026-11-14", "2026-11-21", "2026-11-28"])
        let twin = run(nights: ["2026-11-21"])

        let answer = r.coverageOfItsOtherNights(lookup: { $0 == self.key("2026-11-21") ? twin : nil })
        #expect(answer == .partiallyCovered(covered: 1, of: 2))
    }

    // A single night is not a run and has no other nights to be covered, so it must never read as
    // "fully covered" merely because the set of other nights is empty (L159: a vacuous ALL is true).
    @Test func asingleNightIsNotARun() {
        let r = run(nights: ["2026-11-14"])
        #expect(r.coverageOfItsOtherNights(lookup: { _ in nil }) == .notARun)
    }

    // MARK: which covered runs may be RETIRED (Dan's call on #2998, 2026-09-21)
    //
    // A pair of runs that cover each other is a DUPLICATE, and gets no retire control. The live store's
    // only two fully covered runs on 2026-09-21 were exactly such a pair (one show stored twice), and a
    // retire offered on every fully covered run would have offered it on both, losing the show entirely.
    // So a run is retirable only where every other night is on a separate SINGLE NIGHT card.

    // THE CASE the issue was written about: a run made redundant by single night cards.
    @Test func arunCoveredBySingleNightCardsIsRetirable() {
        let r = run(nights: ["2026-11-14", "2026-11-21", "2026-11-28"])
        let single21 = run(nights: ["2026-11-21"])
        let single28 = run(nights: ["2026-11-28"])

        let answer = r.isRetirable(lookup: { k in
            k == self.key("2026-11-21") ? single21 : (k == self.key("2026-11-28") ? single28 : nil)
        })
        #expect(answer == true)
    }

    // THE HAZARD the report turned up. Two runs, each holding the other's nights. Both are fully covered,
    // and NEITHER may be offered a retire, because retiring either leans on a card that is itself a run.
    @Test func arunCoveredByAnotherRunIsNeverRetirable() {
        let a = run(nights: ["2026-11-14", "2026-11-21"])
        let b = run(nights: ["2026-11-21", "2026-11-14"])

        #expect(a.coverageOfItsOtherNights(lookup: { $0 == self.key("2026-11-21") ? b : nil })
                    == .fullyCovered,
                "the fixture must be the fully covered case, or the refusal below proves nothing (L159)")
        #expect(a.isRetirable(lookup: { $0 == self.key("2026-11-21") ? b : nil }) == false,
                "a run whose cover is itself a run was offered a retire, which can lose the show")
    }

    // A partial run carries nights of its own, so it is never retirable whatever covers the rest.
    @Test func apartiallyCoveredRunIsNeverRetirable() {
        let r = run(nights: ["2026-11-14", "2026-11-21", "2026-11-28"])
        let single21 = run(nights: ["2026-11-21"])
        #expect(r.isRetirable(lookup: { $0 == self.key("2026-11-21") ? single21 : nil }) == false)
    }

    // Unreadable is not "yes": offering a retire on a store that could not answer would act on a cover
    // nobody saw (L42).
    @Test func anunreadableStoreIsNeverRetirable() {
        let r = run(nights: ["2026-11-14", "2026-11-21"])
        #expect(r.isRetirable(lookup: { _ in throw StoreIsDown() }) == false)
    }

    // A read that FAILED says so rather than answering. Reporting a run as covered on a hiccup would
    // name cards that were never seen, and reporting it uncovered would hide one (L11, L42).
    @Test func anunreadableStoreCannotCheck() {
        let r = run(nights: ["2026-11-14", "2026-11-21"])
        #expect(r.coverageOfItsOtherNights(lookup: { _ in throw StoreIsDown() }) == .cannotCheck)
    }
}
