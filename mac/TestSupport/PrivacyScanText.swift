import Foundation

// #3549: the haystack a privacy guard should actually search.
//
// `ForbiddenTextScanner` looks for a literal needle, and a person's name is written with a SPACE in
// it. Prose wraps, so the same name in a document is routinely written with a newline and some
// indentation where that space is, and the two never meet. That is not a hypothetical: one of the real
// people #2839 scrubbed sat in `docs/prep-runbook.md` in this PUBLIC repository from commit 4e0cfef3
// until 2026-09-05, wrapped across two lines the whole time. It was found only because
// an unrelated edit reflowed the paragraph, put the name back on one line, and the guard fired
// immediately, which is the guard working on a haystack it could finally see.
//
// Flattening the haystack ONCE is deliberately preferred to scanning it twice. This guard is the most
// expensive test in the suite (#3235 measured it at 216 seconds of 705), and a second full pass over
// every file in the tree would give back what that work bought. A name is never written with a tab or
// a newline inside it, so a run of whitespace can only ever be one space as far as a name is concerned.
//
// What it gives up, stated rather than left to be discovered: two unrelated words either side of a
// break can now be joined into a forbidden name. For a privacy guard that is the safe direction, since
// the cost is a false alarm somebody reads and the alternative is a real person going unnoticed.
enum PrivacyScanText {

    // A line's leading continuation marker, which a wrapped comment or quoted block puts between the
    // two halves of a name. Ordered longest first so `///` is not read as `//` with a stray slash left
    // behind. Only ever stripped at the START of a continuation line, never mid-line, so a name is
    // rejoined without any other text being altered.
    private static let continuationMarkers = ["///", "//", "*", "#", ">", "--"]

    // Every run of whitespace as one space, with each continuation line's leading comment marker
    // removed and the ends trimmed. Pure, so it can be exercised directly rather than only through
    // the guard that uses it.
    static func flattened(_ text: String) -> String {
        var pieces: [String] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)
            if index > 0 {
                line = String(line.drop(while: { $0.isWhitespace }))
                for marker in continuationMarkers where line.hasPrefix(marker) {
                    line = String(line.dropFirst(marker.count))
                    break
                }
            }
            pieces.append(line)
        }
        // One space between what is left, and every remaining run of whitespace (tabs, a carriage
        // return, runs of spaces) collapsed the same way, so no separator survives inside a name.
        let joined = pieces.joined(separator: " ")
        var out: [UInt8] = []
        out.reserveCapacity(joined.utf8.count)
        var pendingSpace = false
        for byte in joined.utf8 {
            let isSpace = byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
            if isSpace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(0x20)
                pendingSpace = false
            }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
