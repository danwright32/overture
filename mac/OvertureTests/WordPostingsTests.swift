import Testing
import Foundation

// #4353 (plan v7 Step W): ONE word candidate function, shared by the producer tables and their patch.
//
// Before this, "which keys share a word with this one" was written three times: `VenueKeyIndex.candidates`
// in the product, and a hand rolled `[word: Set<key>]` map in each of the 0b.1 and 0c.3 patch prototypes.
// Three copies of the superset reasoning is how the product and the patch come to disagree about where
// one word ends (L370). `ProducerGate.WordPostings` is the one copy, and the patch reaches it the same way
// the product does.
//
// Sharing the prefilter means a word splitting fault would reach the product AND the patch, and a test
// comparing only those two would stay green (L70, L721). So the independent side is a brute force over the
// DEFINITION, never the mechanism: `containsAsWords` in either direction against every key, with no
// prefilter at all. `ProducerGateVenueIndexTests` holds the verdict level brute force; this suite holds the
// postings level one.
@Suite("One word candidate function for the producer tables and their patch (#4353)")
struct WordPostingsTests {

    // Invented names only (L155): containment rich, with a name whose room is NOT its first word, one
    // repeated word, and a single word key the rule never matches.
    private let keys = [
        "lantern hall",
        "friends of lantern hall",
        "lantern hall presents",
        "harbor stage at lantern hall",
        "copper room",
        "the copper room collective",
        "tank",
        "think tank theatre",
        "blue blue harbor",
        "harbor",
        "quiet orchard players",
    ]

    // The rule, both directions, no prefilter.
    private func namesTheSameRoom(_ a: String, _ b: String) -> Bool {
        ProducerGate.containsAsWords(a, b) || ProducerGate.containsAsWords(b, a)
    }

    // The property the whole prefilter rests on: a pair the rule matches must be offered, whichever side
    // the postings were built from.
    @Test func everyPairTheRuleMatchesIsOfferedFromEitherSide() {
        let postings = ProducerGate.WordPostings(keys)
        var matched = 0
        for a in keys {
            let offered = postings.keys(sharingAWordWith: a)
            for b in keys where a != b && namesTheSameRoom(a, b) {
                matched += 1
                #expect(offered.contains(b), "a rule match was not offered as a candidate")
            }
        }
        // Positive control: the fixture really holds matches, including "friends of lantern hall", whose
        // shared words are not its first.
        #expect(matched >= 6)
    }

    // A filter that only ever looked at a name's FIRST word would still pass a fixture of names that lead
    // with their room, so this one is asked directly.
    @Test func aWordThatIsNotTheFirstStillFindsItsKeys() {
        let postings = ProducerGate.WordPostings(["lantern hall"])
        #expect(postings.keys(sharingAWordWith: "friends of lantern hall") == ["lantern hall"])
        #expect(postings.keys(sharingAWordWith: "quiet orchard players").isEmpty)
    }

    // The patch builds its postings one key at a time and takes keys away again; the product builds them
    // in one go. Both must reach the same value, or a long run of edits drifts from a cold build.
    @Test func insertingAndRemovingReachesTheSameValueAsAColdBuild() {
        var patched = ProducerGate.WordPostings()
        for k in keys { patched.insert(k) }
        #expect(patched == ProducerGate.WordPostings(keys))

        let kept = Array(keys.prefix(4))
        for k in keys.dropFirst(4) { patched.remove(k) }
        #expect(patched == ProducerGate.WordPostings(kept))
        for k in kept { #expect(!patched.keys(sharingAWordWith: k).isEmpty) }
        #expect(patched.keys(sharingAWordWith: "copper room").isEmpty)

        // Emptied completely, it holds nothing at all, so no empty posting lingers to break equality.
        for k in kept { patched.remove(k) }
        #expect(patched == ProducerGate.WordPostings())
    }

    // Removing a key that shares its words with another leaves the other one reachable.
    @Test func removingOneKeyLeavesItsNeighboursReachable() {
        var postings = ProducerGate.WordPostings(["lantern hall", "lantern hall presents"])
        postings.remove("lantern hall presents")
        #expect(postings.keys(sharingAWordWith: "lantern") == ["lantern hall"])
    }

    // The venue index is these postings, so the product's candidates are exactly this function's answer.
    @Test func theVenueIndexAsksTheSamePostings() {
        let venueKeys = Set(keys)
        let index = ProducerGate.VenueKeyIndex(venueKeys)
        #expect(index.postings == ProducerGate.WordPostings(venueKeys))
        #expect(index.keys == venueKeys)
    }

    // The words a key is indexed under are the words the rule counts: split on a single space, the way
    // `containsAsWords` bounds an occurrence.
    @Test func aKeysWordsAreItsSpaceSeparatedParts() {
        #expect(ProducerGate.WordPostings.words(of: "blue blue harbor") == ["blue", "blue", "harbor"])
        #expect(ProducerGate.WordPostings.words(of: "tank") == ["tank"])
    }
}
