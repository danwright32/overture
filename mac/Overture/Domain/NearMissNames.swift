import Foundation

// #1768: two spellings of one name are two organisations to every rule that reads one. The venue key
// feeds the producer gate's venue count, the house list handed to the prep run, the natural key and the
// venue history, and every one of them computes against half the picture when a name is split, without
// any of them being able to notice.
//
// This FINDS the candidates and never merges them. That is the whole design, and it comes from the
// measurement: the live store holds exactly three pairs one character apart, and one of them is
// `the artist` against `the artists`, which may genuinely be two different organisations. Any automatic
// rule that fixes the first two silently merges that one, and a wrong merge puts one company's contact on
// another company's shows, which is far more expensive than the duplicate it removes. So Dan decides.
enum NearMissNames {

    struct Pair: Equatable, Sendable, Identifiable, Comparable {
        let a: String
        let b: String
        var id: String { "\(a)|\(b)" }
        static func < (lhs: Pair, rhs: Pair) -> Bool { lhs.id < rhs.id }
    }

    // Below this, a single character apart says nothing. "The Cell" and "The Bell" are two real rooms and
    // "Bard" and "Barn" two real names; the shorter the string, the likelier a one-character gap is simply
    // a different word. Measured against the FOLDED form, which is what is compared: the store's three
    // real pairs fold to "greeley square"/"greely square" (14), "she nyc arts"/"shenyc arts" (12) and
    // "artist"/"artists" (6), while the false positives to keep out fold to four characters.
    static let shortestComparableName = 6

    // Pairs of names that are one character apart after the fold the app already applies. Deliberately a
    // small, strict rule rather than a general fuzzy match: this list is only worth reading while it stays
    // short enough that Dan believes it.
    static func pairs(in names: [String]) -> [Pair] {
        // Fold FIRST, through the same reduction every other name question uses, and compare the folded
        // forms. Two names that already fold together are not a near miss at all: the app has no problem
        // with them, and reporting them would be inventing one.
        var byKey: [String: String] = [:]
        for name in names {
            guard let key = ProducerGate.key(name), key.count >= shortestComparableName else { continue }
            if byKey[key] == nil { byKey[key] = name }
        }
        let keys = byKey.keys.sorted()

        var found: [Pair] = []
        for i in keys.indices {
            for j in keys.index(after: i)..<keys.endIndex {
                let (x, y) = (keys[i], keys[j])
                // A name that CONTAINS another is usually a different relationship (a parent and its
                // room, a company and its fuller name), which the gate's containment arm already handles.
                // But ONLY when the two differ by more than a character: a trailing "s" makes the longer
                // name contain the shorter, and "artist" against "artists" is exactly the near miss this
                // list exists to show. Guarding on containment alone silently dropped it.
                let lengthGap = abs(x.count - y.count)
                if lengthGap > 1, x.contains(y) || y.contains(x) { continue }
                guard isOneEditApart(x, y) else { continue }
                let names = [byKey[x] ?? x, byKey[y] ?? y].sorted()
                found.append(Pair(a: names[0], b: names[1]))
            }
        }
        return found.sorted()
    }

    // Exactly one insertion, deletion or substitution apart. Written out rather than a general edit
    // distance because only "one" is ever the answer here, which lets it stop early and keeps the rule
    // impossible to loosen by accident.
    static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        if a == b { return false }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }

        if x.count == y.count {
            var differences = 0
            for i in x.indices where x[i] != y[i] {
                differences += 1
                if differences > 1 { return false }
            }
            return differences == 1
        }

        // One is exactly one character longer: it is a near miss when deleting a single character from
        // the longer one yields the shorter.
        let (longer, shorter) = x.count > y.count ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < longer.count && j < shorter.count {
            if longer[i] == shorter[j] {
                i += 1; j += 1
            } else {
                if skipped { return false }
                skipped = true
                i += 1
            }
        }
        return true
    }
}
