import Foundation

// #3886: where the app compiles a regular expression ON EVERY CALL.
//
// Two spellings, one defect. `replacingOccurrences(of:options:.regularExpression)` and
// `range(of:options:.regularExpression)` take the pattern as a STRING, so it is parsed and compiled on
// every invocation; and `NSRegularExpression(...)` built inside a function body is the same thing wearing
// different clothes. #3432 found three sites in one file by looking only for the first spelling and
// missing the second (L247), so this reads both.
//
// The classification lives here rather than inside the guard that uses it, so it can be exercised against
// source the test wrote itself: a scanner is the one part of a source guard that can be wrong in the
// silent direction, where it finds nothing and the guard reports a clean app (L98).
enum PerCallPattern {

    enum Form: String, Equatable {
        // `.regularExpression` passed as a String-search option: unambiguous, because that API's only
        // input is a pattern string.
        case stringForm
        // `NSRegularExpression(` on a line that is not a static declaration, so it is built per call.
        case constructedPerCall
    }

    struct Site: Equatable {
        var line: Int
        var form: Form
        var code: String
    }

    // A static declaration compiles once for the life of the process, which is the whole fix, so a line
    // carrying one is not a finding. Matched on the line the construction sits on, which is where this
    // codebase writes it (`private static let x = try! NSRegularExpression(`, possibly wrapping onto the
    // next line for its arguments).
    //
    // What that deliberately does NOT catch is a construction several lines below its static declaration,
    // as in `static let all = [...].compactMap { try? NSRegularExpression(pattern: $0) }` written across
    // lines. Such a file reads as a finding and belongs on the guard's allow list with that as its reason,
    // rather than this rule being loosened until it stops asking the question: "somewhere above me there
    // was a static" is true inside every method of a type that has one.
    private static func isStaticDeclaration(_ code: String) -> Bool {
        code.contains("static let") || code.contains("static var")
    }

    static func sites(in source: String) -> [Site] {
        // `skipping: []` rather than the usual `.all`, and it is load bearing. Comments are stripped
        // either way, which is the part this needs; what `.all` ADDS is blanking `#if DEBUG` blocks,
        // previews and copy-inventory marked regions, and a pattern compiled per call inside one of
        // those is still compiled per call. It was measured rather than reasoned about: with `.all` this
        // scanner reported CompiledPattern.swift and GmailMessage.swift as holding none, because the one
        // construction in each sits inside a marked region, and a scanner that finds nothing is how a
        // guard comes to report a clean app (L98).
        SwiftSource.scannableLines(in: source, skipping: []).compactMap { line in
            let code = line.code
            // `.regularExpression` rather than `options: .regularExpression`, because the option can
            // travel in an ARRAY with another one (`options: [.regularExpression, .caseInsensitive]`)
            // and the narrower spelling walked straight past such a site in SourceFetcher (L247).
            if code.contains(".regularExpression") {
                return Site(line: line.line, form: .stringForm,
                            code: code.trimmingCharacters(in: .whitespaces))
            }
            if code.contains("NSRegularExpression("), !isStaticDeclaration(code) {
                return Site(line: line.line, form: .constructedPerCall,
                            code: code.trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }
}
