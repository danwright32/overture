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
