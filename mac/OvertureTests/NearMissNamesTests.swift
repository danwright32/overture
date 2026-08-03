import Testing
import Foundation

// #1768: two spellings of one name are two organisations to every rule that reads one, and the store
// holds real instances. This finds the candidates; it never merges them, because the same rule that
// catches the typos also catches a pair that may genuinely be two different organisations.
@Suite("Names that look like the same organisation twice (#1768)")
struct NearMissNamesTests {

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="distinct first-clause presenter and venue names that are one character apart"
    // The three real pairs, measured over the whole store: a typo in a park's name, a missing space in a
    // company's, and one that is probably two different organisations. All three must SURFACE, because
    // deciding between them is Dan's job and the whole point of not folding them automatically.
    @Test func theRealPairsInTheStoreAllSurface() {
        let names = ["Greeley Square", "Greely Square", "She NYC Arts", "SheNYC Arts",
                     "The Artist", "The Artists", "Merkin Hall", "The Cutting Room"]
        let pairs = NearMissNames.pairs(in: names)
        let found = Set(pairs.map { [$0.a, $0.b].sorted().joined(separator: " | ") })
        #expect(found.contains("Greeley Square | Greely Square"))
        #expect(found.contains("She NYC Arts | SheNYC Arts"))
        #expect(found.contains("The Artist | The Artists"))
        // And nothing else: two unrelated rooms are not a near miss.
        #expect(pairs.count == 3)
    }

    // The guard against the obvious false positive. Short names differ by one character all the time
    // ("The Cell" against "The Bell"), and folding those together would put one company's contact on
    // another's shows, which is far more expensive than the duplicate it removes.
    @Test func shortNamesAreNeverCalledANearMiss() {
        #expect(NearMissNames.pairs(in: ["The Cell", "The Bell"]).isEmpty)
        #expect(NearMissNames.pairs(in: ["Bard", "Barn"]).isEmpty)
    }

    // Two characters apart is not a near miss either: the further apart two names are, the more likely
    // they are simply different, and this list is only worth reading while it stays short and credible.
    @Test func namesTwoOrMoreCharactersApartAreNotPaired() {
        #expect(NearMissNames.pairs(in: ["Greeley Square", "Grealey Squire"]).isEmpty)
    }

    // A name that merely CONTAINS another is a different relationship, already handled by the producer
    // gate's containment arm, and pairing them here would fill the list with real parent/child names
    // ("Jalopy Theatre" inside "Jalopy Theatre and School of Music").
    @Test func aLongerNameContainingAShorterOneIsNotANearMiss() {
        #expect(NearMissNames.pairs(in: ["Jalopy Theatre", "Jalopy Theatre and School of Music"]).isEmpty)
    }

    // Case and punctuation alone are not a near miss: those already fold to one key, so reporting them
    // would be telling Dan about a problem the app does not have.
    @Test func namesThatAlreadyFoldTogetherAreNotReported() {
        #expect(NearMissNames.pairs(in: ["STAGE WEST Theatre", "Stage West Theatre"]).isEmpty)
    }

    // Deterministic: one pair per unordered couple, ordered so the sheet reads the same on every redraw.
    @Test func eachPairIsReportedOnceAndInAStableOrder() {
        let once = NearMissNames.pairs(in: ["Greely Square", "Greeley Square"])
        let other = NearMissNames.pairs(in: ["Greeley Square", "Greely Square"])
        #expect(once.count == 1)
        #expect(once == other)
    }
}
