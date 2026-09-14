import Testing
import Foundation

// #3235: the #2839 privacy guard's search, rewritten as one pass per file. The rewrite is only worth
// having if it finds exactly what the old one found, so the last test here is a DIFFERENTIAL against
// the implementation it replaces rather than a list of cases somebody thought of.
@Suite("The forbidden-name scan finds what the search it replaced found (#3235)")
struct ForbiddenTextScannerTests {

    // The implementation being replaced, kept here as the reference the rewrite is judged against.
    private func naive(_ needles: [String], in text: String) -> [String] {
        let lowered = text.lowercased()
        return needles.filter { lowered.contains($0) }.sorted()
    }

    @Test func itFindsANameAnywhereInTheText() {
        let scanner = ForbiddenTextScanner(needles: ["brix tanager", "olm ferrister"])
        #expect(scanner.matches(in: "the producer was brix tanager that season") == ["brix tanager"])
        #expect(scanner.matches(in: "brix tanager") == ["brix tanager"])
        #expect(scanner.matches(in: "credited to brix tanager") == ["brix tanager"])
    }

    @Test func itIsNotFooledByANearMiss() {
        let scanner = ForbiddenTextScanner(needles: ["olm ferrister"])
        #expect(scanner.matches(in: "olm ferristerson").isEmpty == false, "a longer word still contains it")
        #expect(scanner.matches(in: "olm  ferrister").isEmpty, "two spaces is a different string")
        #expect(scanner.matches(in: "olmferrister").isEmpty)
    }

    @Test func itIgnoresCaseInTheTextItSearches() {
        let scanner = ForbiddenTextScanner(needles: ["brix tanager"])
        #expect(scanner.matches(in: "BRIX TANAGER") == ["brix tanager"])
        #expect(scanner.matches(in: "Brix Tanager") == ["brix tanager"])
    }

    @Test func itNamesEachHitOnceHoweverOftenItOccurs() {
        let scanner = ForbiddenTextScanner(needles: ["wren halloway"])
        #expect(scanner.matches(in: "wren halloway, wren halloway, and wren halloway again") == ["wren halloway"])
    }

    // The accented needle is the reason this is not a plain byte search. Swift treats canonically
    // equivalent spellings as equal, so a name written with a combining accent matches one written
    // with a precomposed character. A byte comparison does not, and for a privacy guard that
    // difference goes the wrong way: it lets a real person through.
    @Test func itStillMatchesAnAccentedNameWrittenEitherWay() {
        let precomposed = "z\u{00E9}lie marchbank"
        let decomposed = "ze\u{0301}lie marchbank"
        let scanner = ForbiddenTextScanner(needles: [precomposed])
        #expect(scanner.matches(in: "the note names \(precomposed) as producer") == [precomposed])
        #expect(scanner.matches(in: "the note names \(decomposed) as producer") == [precomposed],
                "a decomposed spelling is the same name and must not slip past")
    }

    @Test func anEmptyTextAndAnEmptyNeedleListAreBothSafe() {
        #expect(ForbiddenTextScanner(needles: ["a name"]).matches(in: "").isEmpty)
        #expect(ForbiddenTextScanner(needles: []).matches(in: "some text").isEmpty)
        #expect(ForbiddenTextScanner(needles: [""]).matches(in: "some text").isEmpty,
                "an empty needle matches everything and must be dropped, not reported on every file")
    }

    // THE test. Every case above is one somebody thought of; this one runs both implementations over
    // a corpus built to break them and asserts they never disagree (L52, L26). The corpus deliberately
    // holds overlapping prefixes, needles at the very start and very end, one needle inside another,
    // multi-byte characters beside a match, and text with no match at all.
    @Test func itAgreesWithTheSearchItReplacesOnEveryShapeThatCouldSeparateThem() {
        let needles = [
            "wren halloway", "wren hallowayne", "halloway", "brix tanager", "tanager", "olm ferrister", "olmferrister",
            "a", "ab", "abc", "quill okonjo", "quillokonjo", "z\u{00E9}lie marchbank", "pellman.ardsley",
        ]
        let scanner = ForbiddenTextScanner(needles: needles)

        var corpus = [
            "", "a", "ab", "abc", "abcd", "xabc", "abcx",
            "wren halloway", "wren hallowayne", "wren hallowayside", "halloway wren", "HALLOWAY",
            "brix tanagertanager", "tanagerbrix tanager", "olm ferrister olmferrister",
            "quill okonjo and quillokonjo and quill okonjox",
            "z\u{00E9}lie marchbank", "ze\u{0301}lie marchbank", "Z\u{00C9}LIE MARCHBANK",
            "pellman.ardsley", "pellman ardsley", "pellman-ardsley",
            "nothing forbidden in this line at all",
            "\u{1F600} wren halloway \u{1F600}", "\u{4F60}\u{597D} brix tanager",
            String(repeating: "x", count: 500) + "olm ferrister",
            "olm ferrister" + String(repeating: "y", count: 500),
        ]
        // Every needle on its own, and every needle padded, derived rather than listed again so a
        // needle added above cannot quietly stop being covered here.
        corpus += needles.map { $0 }
        corpus += needles.map { "before \($0) after" }
        corpus += needles.map { $0.uppercased() }

        for text in corpus {
            #expect(scanner.matches(in: text) == naive(needles, in: text),
                    "the two implementations disagreed on: \(text.debugDescription)")
        }
    }
}

// #3549: a name split across a LINE BREAK was invisible to this guard, and that was not hypothetical.
// One of the real people #2839 scrubbed sat in `docs/prep-runbook.md` in this PUBLIC repository from
// commit 4e0cfef3 until 2026-09-05, wrapped across two lines by ordinary prose
// reflow. Nothing was wrong with the scanner: it was asked for a needle with a SPACE in it and the
// file held a newline, so the two never met. It surfaced only because an unrelated edit reflowed the
// paragraph and put the name back on one line, where the guard then caught it immediately.
//
// The remedy is to normalise the HAYSTACK before scanning rather than to scan it twice: a run of
// whitespace becomes one space, so a wrapped name reads as the name it is. Once, not twice, because
// this guard is already the most expensive test in the suite (#3235 measured 216s of 705s), and a
// second full pass over every file in the tree would undo that work.
@Suite("A scrubbed name wrapped across lines is still that name (#3549)")
struct WrappedForbiddenNameTests {

    // Invented people, so this suite can state the problem without putting a real name in the tree.
    private let needles = ["corin hale", "wren halloway"]

    @Test func aNameBrokenByALineWrapIsFound() {
        let scanner = ForbiddenTextScanner(needles: needles)
        let wrapped = "addressing them directly: \"I saw you and Corin\nHale are making your debut\""

        #expect(scanner.matches(in: wrapped).isEmpty,
                "the raw text is exactly what USED to be scanned, and it finds nothing")
        #expect(scanner.matches(in: PrivacyScanText.flattened(wrapped)) == ["corin hale"])
    }

    // Every shape a reflow can leave behind, not just the newline that happened to be found.
    @Test func everyRunOfWhitespaceReadsAsOneSpace() {
        let scanner = ForbiddenTextScanner(needles: needles)
        // The last four are CONTINUATION markers, which is how a wrapped comment or a quoted block
        // puts something between the two halves of a name. Found by this very test on its first run:
        // collapsing whitespace alone left "Wren // Halloway", which is not the name.
        for separator in ["\n", "\r\n", "\n    ", " \n ", "\t", "  ",
                          "\n// ", "\n    /// ", "\n # ", "\n> "] {
            let text = "before Wren\(separator)Halloway after"
            #expect(scanner.matches(in: PrivacyScanText.flattened(text)) == ["wren halloway"],
                    "separator \(separator.debugDescription) hid the name")
        }
    }

    // The normalisation must not INVENT a name that is not there: flattening joins words, so a guard
    // built on it has to be shown not to fire on text where the two halves are genuinely unrelated
    // and nothing but the collapse could have put them together.
    @Test func flatteningDoesNotChangeWhatTheTextSays() {
        #expect(PrivacyScanText.flattened("a\n\nb") == "a b")
        #expect(PrivacyScanText.flattened("  leading and trailing  ") == "leading and trailing")
        #expect(PrivacyScanText.flattened("no change needed") == "no change needed")
    }
}
