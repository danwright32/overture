import Foundation

// #2656: a listing page pays for its own navigation menu several times over.
//
// Measured across the archived prep runs on Dan's Mac, 54 Below's listing text is 49% site chrome before
// the show block begins, because the same menu appears four times in one page for the mobile and toggle
// variants. Every 54 Below listing ever read has hit `ShowListingReader.textLimit`, and on the show that
// prompted the issue the producer credit survived the cut by roughly 900 characters purely by luck of
// where the menu ended. The budget is not too small; it is being spent on a menu.
//
// WHAT THIS IS NOT. It is not a chrome DETECTOR and does not know what a navigation menu is. It removes
// verbatim repetition, which is a fact about the page rather than a guess about its meaning, and the
// difference matters: a rule that tried to recognise chrome would have to be right about somebody else's
// markup, while this one can only ever delete a second copy of something already present.
//
// THE INVARIANT, and the reason it is safe to run on text nobody has read. The FIRST occurrence of every
// run of words is kept and only later copies go, so no distinct word the page published can be lost.
// Asserted over all eight archived venues in `RepeatedBlockStripperTests`, not merely intended here.
//
// DELIBERATELY NOT PART OF `PageNormalizer.visibleText`. The scout's extract stage reads its pages through
// that same normalisation (`RenderedPage`, #806), and changing what the scout sees is a separate question
// needing its own measurement against its own corpus (the issue says so explicitly). This is applied by
// `ShowListingReader` alone, so the scout is untouched by construction rather than by care.
enum RepeatedBlockStripper {

    // Twelve words. Long enough that a verbatim repeat is chrome rather than coincidence, and short enough
    // to catch the shortest real menu measured (54 Below's is 63 words). Ordinary English repeats itself
    // constantly at three or four words, so a lower threshold would start rewriting the listing: an act's
    // name, a date and a venue all recur inside one page legitimately.
    static let minimumRepeatedWords = 12

    // The text with every repeated run of `minimumRepeatedWords` or more words after its first appearance
    // removed. Single pass over the words, so the cost is linear in the page rather than in the square of
    // it: this runs on the full page BEFORE the cap is applied, and #1056 is the reminder that a page here
    // can be 82KB.
    static func strip(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let n = words.count
        guard n > minimumRepeatedWords else { return text }

        // Where each distinct opening window was first seen. The window is the KEY, so a repeat is found
        // by one lookup rather than by scanning what came before.
        var firstSeen: [String: Int] = [:]
        var dropped = [Bool](repeating: false, count: n)
        var i = 0
        while i + minimumRepeatedWords <= n {
            let window = words[i..<(i + minimumRepeatedWords)].joined(separator: " ")
            guard let start = firstSeen[window] else {
                firstSeen[window] = i
                i += 1
                continue
            }
            // Extend the match as far as the two copies agree, so a long menu is removed in one run
            // rather than twelve words at a time. `start + length < i` keeps the two copies from
            // overlapping, which is what stops a page of one word repeated from eating itself.
            var length = minimumRepeatedWords
            while i + length < n, start + length < i, words[i + length] == words[start + length] {
                length += 1
            }
            for k in i..<(i + length) { dropped[k] = true }
            i += length
        }

        guard dropped.contains(true) else { return text }
        return words.enumerated().filter { !dropped[$0.offset] }.map(\.element)
            .joined(separator: " ")
    }
}
