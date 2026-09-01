import Foundation

// One pass over a file's text for a whole vocabulary of identifiers (#3405).
//
// `TestOnlyReachableDomainCodeTests` asked, for each of about 4,100 names declared in the Domain, whether
// any of about 1,440 files mentions it, by compiling a fresh `NSRegularExpression` per name and running it
// over every line of the file it was handed. That is names times files, and it measured 68.15s of a 404s
// serial suite on 2026-08-31: the single most expensive suite in the run, growing quadratically as either
// half of the tree grows.
//
// This is the same move `ForbiddenTextScanner` (#3235) made one level down, where about 150 searches over
// one body of text became a single pass and a suite went from 216s to 44.6s. Here the pass is a tokeniser:
// split the text into whole words once and count only the words the caller asked about, so the work is the
// size of the text rather than the size of the text times the size of the question.
//
// WHAT MUST NOT CHANGE is the meaning, which is `\bname\b`. A tokeniser that disagrees with that regex by
// one character class silently widens or narrows every finding, so the boundary rule here is ICU's own
// definition of a word character rather than an ASCII approximation of it:
//
//     \w  ==  [\p{Alphabetic}\p{M}\p{Nd}\p{Pc}‌‍]
//
// and `\bname\b`, for a name made only of word characters, matches exactly where `name` occurs as a
// MAXIMAL run of them. So counting maximal runs equal to the name is the same measurement, not an
// approximation of it. `IdentifierIndexTests` holds that claim against the regex itself, over shapes
// chosen to sit either side of the line (an accented letter, which suppresses a boundary, and a non-ASCII
// dash, which does not) and over the repository's own source.
enum IdentifierIndex {

    // How often each WANTED name occurs as a whole word in `lines`. A name that never occurs is absent
    // rather than zero, so a caller reading `?? 0` and one reading `!= nil` agree.
    //
    // The vocabulary is a parameter rather than "every word in the file" deliberately: the question is
    // always about a known set of names, and counting the rest would make the index the size of the tree
    // instead of the size of the question.
    static func counts(in lines: [(line: Int, code: String)], wanted: Set<String>) -> [String: Int] {
        guard !wanted.isEmpty else { return [:] }

        // The cheapest thing that can rule a token out before it is hashed. Most tokens in a Swift file
        // are not in the vocabulary, and building the dictionary lookup for every one of them was the
        // whole remaining cost once the regex was gone.
        var wantedFirstScalar = Set<UInt32>()
        var shortest = Int.max
        var longest = 0
        for name in wanted {
            if let first = name.unicodeScalars.first { wantedFirstScalar.insert(first.value) }
            let count = name.unicodeScalars.count
            shortest = min(shortest, count)
            longest = max(longest, count)
        }

        var out: [String: Int] = [:]
        var token = String.UnicodeScalarView()
        var length = 0
        var firstValue: UInt32 = 0

        func finish() {
            defer {
                token.removeAll(keepingCapacity: true)
                length = 0
            }
            guard length >= shortest, length <= longest, wantedFirstScalar.contains(firstValue) else { return }
            let word = String(token)
            guard wanted.contains(word) else { return }
            out[word, default: 0] += 1
        }

        for entry in lines {
            for scalar in entry.code.unicodeScalars {
                if isWordScalar(scalar) {
                    if length == 0 { firstValue = scalar.value }
                    token.append(scalar)
                    length += 1
                } else if length > 0 {
                    finish()
                }
            }
            // A token running to the end of a line ends there: a line break is not a word character, so
            // the regex would see a boundary here too.
            if length > 0 { finish() }
        }
        return out
    }

    // ICU's `\w`, which is what `\b` is defined in terms of. ASCII is answered by four comparisons because
    // that is nearly every character in this tree; anything else pays a property lookup.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return (value >= 48 && value <= 57)      // 0-9
                || (value >= 65 && value <= 90)      // A-Z
                || (value >= 97 && value <= 122)     // a-z
                || value == 95                       // _
        }
        if value == 0x200C || value == 0x200D { return true }  // ZWNJ, ZWJ
        let properties = scalar.properties
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark, .connectorPunctuation:
            return true
        default:
            return false
        }
    }
}
