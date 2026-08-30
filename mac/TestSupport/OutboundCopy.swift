import Foundation

// #2650: every sentence that leaves the building under Dan's name.
//
// `docs/copy-inventory.md` is the app's own voice to Dan, and outbound email is deliberately excluded
// from it, correctly: a recipient is not Dan and the two are not one list. The consequence was that the
// copy going to strangers became the ONLY copy in the product with no reader at all.
//
// #2643 is the proof. A closing note told people who had never replied "it was good to be in touch", and
// it survived #2615 rewriting the first sentence of that same paragraph three days earlier, because
// nothing ever put those sentences in front of a person. The exclusion was right; what was missing was
// naming what would review them instead (L129).
//
// So this is the second document, built the same way and kept fresh the same way, from the ignore
// regions that are TAGGED as outbound email rather than from a hand-kept list of files (L96).
enum OutboundCopy {

    // The tag an ignore region carries to say a recipient reads this. A leading token, not prose: the
    // sentence after it is for a person and gets reworded, and a match on prose stops finding the region
    // the day somebody improves it (L103).
    static let tag = "outbound-email:"

    // The wordings that mean "somebody outside READS THIS SENTENCE" without saying the tag. A region
    // matching one of these and not carrying the tag is a region with no reader, which is the whole
    // defect, so the guard names it rather than trusting everyone to remember (L96).
    //
    // Deliberately narrow, and narrowed after it fired on the ordinary case. "outbound email" was in this
    // list first and matched two regions that hold the HTML and CSS an email is DISPLAYED with
    // (`DraftSignaturePreview`, `GmailMessage`), which nobody reads as words. A guard that fires on the
    // common case gets switched off within a day (L93), so it matches the phrase that means a person is
    // reading, not the phrase that mentions email.
    //
    // This is a net for the obvious wording, not a proof of completeness: what actually makes the
    // convention hold is the tag being written down (AGENTS.md) and this document existing to be read.
    static let outboundSoundingPhrases = [
        "a recipient reads",
        "contact-facing email copy",
    ]

    struct Line: Equatable {
        var text: String
        var file: String
    }

    struct Document {
        var lines: [Line] = []
        var filesScanned = 0

        var sentences: [String] { Array(Set(lines.map(\.text))).sorted() }
        func sources(of sentence: String) -> [String] {
            Array(Set(lines.filter { $0.text == sentence }.map(\.file))).sorted()
        }
    }

    // #3235: built once per process for the default root, on CopyInventory's reasoning and with its
    // refusals.
    private static let defaultMemo = BuildMemo<Document>()

    static var buildsPerformed: Int { defaultMemo.buildsPerformed }

    static func build(root: URL = CopyInventory.appRoot, floor: Int = 50) throws -> Document {
        guard root == CopyInventory.appRoot, floor == 50 else {
            return try buildUncached(root: root, floor: floor)
        }
        return try defaultMemo.value(keepIf: { $0.filesScanned > 0 }) {
            try buildUncached(root: CopyInventory.appRoot, floor: 50)
        }
    }

    private static func buildUncached(root: URL, floor: Int) throws -> Document {
        var document = Document()
        let files = AppSourceWalk.urls(under: root, floor: floor)
        document.filesScanned = files.count
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = CopyInventory.relativePath(of: file, under: root)
            for literal in SwiftSource.literalsInTaggedRegions(in: source, tag: tag)
            where CopyInventory.isCopy(literal) {
                document.lines.append(Line(text: literal.text, file: name))
            }
        }
        return document
    }

    // A region that reads like outbound email but carries no tag. Reported with its line so the fix is
    // obvious, and returning the empty array is the ONLY clean answer: there is no "probably fine".
    static func untaggedOutboundRegions(root: URL = CopyInventory.appRoot,
                                        floor: Int = 50) throws -> [String] {
        var offenders: [String] = []
        for file in AppSourceWalk.urls(under: root, floor: floor) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = CopyInventory.relativePath(of: file, under: root)
            for region in SwiftSource.ignoredReasonsWithLines(in: source) {
                guard !region.reason.hasPrefix(tag) else { continue }
                let lowered = region.reason.lowercased()
                // The debug stand-ins say "contact-facing email copy" and are compiled out of the app Dan
                // ships, so they are not copy that can reach anybody. Excluded by FILE rather than by
                // rewording their reason, so the exclusion is visible here rather than hidden in a comment.
                guard !name.hasSuffix("DebugStaging.swift") else { continue }
                if outboundSoundingPhrases.contains(where: { lowered.contains($0) }) {
                    offenders.append("\(name):\(region.line)  \(region.reason)")
                }
            }
        }
        return offenders.sorted()
    }

    static var documentPath: String { "docs/outbound-copy.md" }

    static var checkedInURL: URL {
        RepoRoot.url.appendingPathComponent(documentPath)
    }
}

extension OutboundCopy.Document {

    func render() -> String {
        var out: [String] = []
        out.append("# Outbound copy")
        out.append("")
        out.append("Every sentence Overture sends OUT under Dan's name: **\(sentences.count) sentences**.")
        out.append("")
        out.append("""
            Generated, do not edit by hand. The test suite regenerates it and fails when it is stale, the
            same way `docs/copy-inventory.md` does.

            This is the OTHER list, and the difference is the point. The copy inventory is what Overture
            says to Dan. This is what Dan's name says to somebody else, drawn from the
            `copy-inventory:ignore-start  \(OutboundCopy.tag) ...` regions, which are kept out of that
            inventory deliberately because a recipient is not Dan.

            Read these cold before shipping a change to them, and ask the question this list exists for,
            which is not the one the inventory asks: **what state is this sentence ONLY ever sent in, and
            is every clause true of that state?** #2643 is why: a closing note told people who had never
            replied that it was good to be in touch, and it survived a rewrite of the sentence beside it
            three days earlier, because nothing ever put it in front of a person.
            """)
        out.append("")
        for sentence in sentences {
            out.append(quoted(sentence))
            for file in sources(of: sentence) {
                out.append("    `\(file)`")
            }
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    private func quoted(_ sentence: String) -> String {
        "\"\(sentence)\""
    }
}
