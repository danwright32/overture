import Testing
import Foundation

// #3310: every prep queue version the code declares is DESCRIBED in `docs/contracts.md`.
//
// `PrepQueueBuilder.version` was 13. The document described 2, 3, 5, 7, 8 and 10, and said nothing about 9,
// 11, 12 or 13. It read as complete, because every version it did describe was described well, so
// nothing signalled that four were missing. On 2026-08-30 a planning brief was written from it stating
// the contract was at v7 and that the change in hand would be v8. It was wrong by six versions, and
// three separate agents reading the actual source had to correct it.
//
// A confidently incomplete reference is worse than an obviously incomplete one, which is why the class
// is closed here rather than only the instance (L30): the next bump cannot ship undocumented.
//
// What it does NOT claim: that the paragraph is any good. It can only see that the version is spoken
// about, which is what a source-text guard can measure, and the cold read is what judges the words
// (L11).
@Suite("Every prep queue version is documented (#3310)")
struct PrepQueueVersionsAreDocumentedTests {
    private static var contracts: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/contracts.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // A version is described when the document says "Queue version N" about it, which is the phrasing
    // every existing paragraph already uses. Matched with the boundary, so "version 1" does not answer
    // for 11, 12 or 13, which is exactly the family this guard is about.
    static func describedQueueVersions(in document: String) -> Set<Int> {
        var found: Set<Int> = []
        for line in document.components(separatedBy: "\n") {
            guard let range = line.range(of: "Queue version ") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { continue }
            // The next character must not be a digit, which `prefix(while:)` already guarantees, nor a
            // decimal point that would make this a different number entirely.
            found.insert(n)
        }
        return found
    }

    @Test func everyVersionUpToTheCurrentOneIsDescribed() {
        let document = Self.contracts
        #expect(!document.isEmpty,
                "docs/contracts.md could not be read, so this checked nothing (L98)")
        let described = Self.describedQueueVersions(in: document)
        #expect(!described.isEmpty, """
            no 'Queue version N' paragraph was found at all, so the phrasing this reads by has changed             and it is measuring nothing (L98).
            """)

        // Version 1 is the original shape and has no "adds" paragraph of its own, which is why the
        // range starts at 2.
        let missing = (2...PrepQueueBuilder.version).filter { !described.contains($0) }
        #expect(missing.isEmpty, """
            PrepQueueBuilder.version is \(PrepQueueBuilder.version) and docs/contracts.md describes no \
            "Queue version N" paragraph for \(missing.map(String.init).joined(separator: ", ")). That \
            document is what anyone is told to read before changing a cross-boundary file shape, and it \
            reads as complete whether or not it is: on 2026-08-30 a brief written from it was wrong by \
            six versions (#3310).
            """)
    }

    // The reader itself, driven both ways, because a guard that can only ever say "all present" is one
    // nobody has seen work (L1). Also pins the boundary: a document naming only version 1 must not be
    // read as describing 11.
    @Test func theReaderFindsWhatIsThereAndNotWhatIsNot() {
        #expect(Self.describedQueueVersions(in: "Queue version 2 (#586) adds a thing.") == [2])
        #expect(Self.describedQueueVersions(in: "Queue version 1 adds nothing.") == [1])
        #expect(Self.describedQueueVersions(in: "Queue version 13 (#2983) adds a name.") == [13])
        #expect(Self.describedQueueVersions(in: "Results version 11 (#2895) is a different file.").isEmpty)
        #expect(Self.describedQueueVersions(in: "nothing here").isEmpty)
    }
}
