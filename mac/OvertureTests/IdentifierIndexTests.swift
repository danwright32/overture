import Foundation
import Testing

// #3405: the index that replaced a fresh NSRegularExpression per name per file.
//
// The claim it has to keep is not "it is fast", it is "it counts exactly what `\bname\b` counted".
// A tokeniser that disagrees with the regex silently widens or narrows every guard built on it, so
// the central test here is a CROSS CHECK against the regex itself over the awkward shapes, rather
// than a list of cases somebody thought of.
@Suite("Identifier index (#3405)")
struct IdentifierIndexTests {

    private static func regexCount(_ name: String, in lines: [(line: Int, code: String)]) -> Int {
        let re = try! NSRegularExpression(
            pattern: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
        return lines.reduce(0) { total, entry in
            total + re.numberOfMatches(
                in: entry.code, range: NSRange(entry.code.startIndex..., in: entry.code))
        }
    }

    // Every shape that can separate a whole-word match from a substring one, including the two the
    // ASCII fast path cannot answer on its own: a letter with an accent (a word character, so it
    // suppresses the boundary) and a punctuation mark outside ASCII (not a word character, so it does
    // not).
    private static let awkward: [String] = [
        "let list = 1",
        "listing.append(list)",
        "prelist(list)",
        "list_of_things",
        "list2 = list",
        "self.list = list",
        "\"list\"",
        "// list",
        "café.list",
        "listé",
        "élist",
        "list\u{2014}next",
        "list…next",
        "(list),[list],{list}",
        "list.list.list",
        "",
        "listlist",
        "_list",
        "list_",
        "0list",
        "list0",
    ]

    @Test func agreesWithTheRegexItReplacedOnEveryAwkwardShape() {
        let lines = Self.awkward.enumerated().map { (line: $0.offset + 1, code: $0.element) }
        for name in ["list", "listing", "café", "list2"] {
            #expect(
                IdentifierIndex.counts(in: lines, wanted: [name])[name] ?? 0
                    == Self.regexCount(name, in: lines),
                "the index and the regex disagree about \(name)")
        }
    }

    // The same claim over the repository's own source rather than over lines chosen by hand, because a
    // hand-written corpus only ever contains the cases somebody remembered (L48).
    @Test func agreesWithTheRegexOverRealSource() throws {
        let files = AppSourceWalk.files(
            under: RepoRoot.mac.appendingPathComponent("Overture/Domain"), floor: 60)
        let sample = Array(files.prefix(6))
        #expect(sample.count == 6, "the sample came back short, so nothing below compared anything")
        for file in sample {
            let lines = SwiftSource.scannableLines(in: file.text, skipping: [])
            let names = Set(
                TestOnlyReachableDomainCodeTests.declaredNames(in: lines).prefix(20))
            #expect(!names.isEmpty, "\(file.name) declared no names, so nothing was compared")
            let counted = IdentifierIndex.counts(in: lines, wanted: names)
            for name in names {
                #expect(
                    counted[name] ?? 0 == Self.regexCount(name, in: lines),
                    "the index and the regex disagree about \(name) in \(file.name)")
            }
        }
    }

    // The vocabulary is the whole point: a name nobody asked about is not counted, which is what keeps
    // the index the size of the question rather than the size of the tree.
    @Test func countsNothingForANameOutsideTheVocabulary() {
        let lines = [(line: 1, code: "let list = other")]
        let counted = IdentifierIndex.counts(in: lines, wanted: ["list"])
        #expect(counted["list"] == 1)
        #expect(counted["other"] == nil)
    }

    @Test func anEmptyVocabularyCountsNothingAndReadsNoLines() {
        let lines = [(line: 1, code: "let list = other")]
        #expect(IdentifierIndex.counts(in: lines, wanted: []).isEmpty)
    }

    // A name occurring twice on ONE line is two mentions, which the guard's "used elsewhere in its own
    // file" test depends on: it compares a count against 1, not a presence against false.
    @Test func countsEveryOccurrenceNotEveryLine() {
        let lines = [(line: 1, code: "list = list + list")]
        #expect(IdentifierIndex.counts(in: lines, wanted: ["list"])["list"] == 3)
    }
}
