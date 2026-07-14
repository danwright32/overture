import Testing
import Foundation
@testable import Overture

// #885: the guard. A rule computed inside a SwiftUI view is a rule no test can reach.
//
// Three times this has cost real damage: a count that promised rows it did not deliver (#863), a
// sentence about what the app would do next that no test could read (#876), and an off-by-one written
// twice so the row and the email could disagree (#885 itself). Every time, the suite was green and the
// defect was real, and every time the only detector was somebody happening to look.
//
// So: the pattern, not the instance. This scans the app's own views and fails when a USER-FACING string
// is COMPUTED there, pointing at the established pattern instead (decide beside the data, keep the row
// dumb: PrepRunSummary, DraftReviewNotes, EmptyState, Plural, QueueModel).
//
// What counts as computed, and deliberately not more:
//
//   Words plus a value: "\(n) new leads while you were away". The words make a claim; the value makes it
//   specific; together they can be wrong in a way no test can see.
//
//   A ternary choosing between two wordings: `isKept ? "pending Prep run" : "keep to prep"`. The CHOICE
//   is the rule.
//
// What is deliberately NOT flagged, because flagging it would be noise, and a guard that cries wolf is a
// guard somebody eventually turns off:
//
//   A static literal: Text("Sources"). No logic, nothing to drift.
//   A bare value: Text("\(item.fitScore)"). Displaying a number a model already computed is not a rule.
//     (The RULE behind such a number belongs in a model, and #863's did; this guard cannot see that, and
//     does not pretend to.)
@Suite("No user-facing copy computed inside a view (#885)")
struct ViewCopyGuardTests {

    // Where a string in a view actually becomes something Dan reads. Anchoring on these rather than on
    // "any literal" is what keeps the guard quiet about identifiers, symbol names, defaults keys and
    // URLs, which are strings in views too, and none of them are copy.
    private static let userFacingSinks = [
        "Text(", "Label(", "Button(", ".help(", ".alert(", ".confirmationDialog(",
        "acknowledge(", "statusMessage =", "errorMessage =", "warningMessage =",
        "addMessage =", "scoutSummary =", "status =", "message:",
    ]

    @Test func noViewComputesItsOwnUserFacingCopy() throws {
        let files = Self.viewFiles()
        #expect(!files.isEmpty)   // a wrong path must not pass silently, the way #887's guard did

        var offenders: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for hit in Self.computedCopy(in: source) {
                offenders.append("\(file.lastPathComponent):\(hit.line)  \(hit.text)")
            }
        }
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, """
            User-facing copy is being computed inside a view, where no test can reach it (#885).
            Move the sentence to a pure type beside the data and let the view render it:
            PrepRunSummary, ScoutRunSummary, DraftReviewNotes, EmptyState, QueueModel, Plural.

            \(report)
            """)
    }

    // MARK: - The scanner
    //
    // Reuses the same idea as the dash guard (#343): walk the source, know whether you are in code, a
    // comment or a string, and never confuse the three. Comments are exempt on purpose, since this
    // codebase deliberately quotes copy in them to explain itself.

    struct Hit: Equatable { let line: Int; let text: String }

    static func computedCopy(in source: String) -> [Hit] {
        var hits: [Hit] = []
        for (offset, raw) in statements(in: source) {
            guard userFacingSinks.contains(where: { raw.contains($0) }) else { continue }
            guard let text = ruleBearingLiteral(in: raw) else { continue }
            hits.append(Hit(line: offset, text: text))
        }
        return hits
    }

    // A ternary that picks between two string literals: the choice of WORDING is the rule.
    //
    // An ICON is not wording. `systemImage: on ? "checkmark.seal.fill" : "checkmark.seal"` picks an SF
    // Symbol, which is a name, not a sentence, and nobody reads it. Those arguments are stripped before
    // the test rather than allowlisted per line, so the exemption is about what the string IS and cannot
    // silently come to cover a real sentence that happens to sit on the same line.
    private static func isWordingTernary(_ s: String) -> Bool {
        let withoutSymbols = s.replacingOccurrences(
            of: "(systemImage|systemName):\\s*[^,)]*", with: "", options: .regularExpression)
        return withoutSymbols.range(of: "\\?\\s*\"[^\"]*\"\\s*:\\s*\"",
                                    options: .regularExpression) != nil
    }

    // A literal that interpolates a value AND carries words of its own.
    private static func ruleBearingLiteral(in statement: String) -> String? {
        if isWordingTernary(statement) { return statement.trimmingCharacters(in: .whitespaces) }
        for literal in stringLiterals(in: statement) where literal.contains("\\(") {
            // Strip the interpolations and see whether any WORDS are left. "\(count)" alone is a value
            // being displayed, not a sentence being built, and is none of this guard's business.
            //
            // Balanced parens, not a lazy regex: an interpolation can contain a call with its own parens
            // ("\(DueWork.counts(prospects: p).total)"), and a naive [^)]* stops at the first one and
            // leaves ".total)" behind, which looks exactly like words. That false positive would have
            // been indistinguishable from a real finding.
            if withoutInterpolations(literal).contains(where: { $0.isLetter }) { return literal }
        }
        return nil
    }

    static func withoutInterpolations(_ literal: String) -> String {
        var out = ""
        var depth = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            if depth == 0, literal[index] == "\\",
               literal.index(after: index) < literal.endIndex,
               literal[literal.index(after: index)] == "(" {
                depth = 1
                index = literal.index(index, offsetBy: 2)
                continue
            }
            if depth > 0 {
                if literal[index] == "(" { depth += 1 }
                if literal[index] == ")" { depth -= 1 }
                index = literal.index(after: index)
                continue
            }
            out.append(literal[index])
            index = literal.index(after: index)
        }
        return out
    }

    private static func stringLiterals(in statement: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for ch in statement {
            if escaped { if inString { current.append(ch) }; escaped = false; continue }
            if ch == "\\" { if inString { current.append(ch) }; escaped = true; continue }
            if ch == "\"" {
                if inString { out.append(current); current = "" }
                inString.toggle()
                continue
            }
            if inString { current.append(ch) }
        }
        return out
    }

    // Source, minus comments, gathered into statements: a line plus any continuation lines, so a Text(…)
    // split across three lines is still seen whole. Line numbers are the statement's first line.
    static func statements(in source: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var pending: String?
        var pendingLine = 0
        // DEBUG-only copy is exempt, and deliberately so: it is compiled out of the app Dan runs, so it
        // can never mislead him. A guard that fires on developer scaffolding is a guard that trains
        // people to ignore it.
        var debugDepth = 0
        for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = stripComment(String(rawLine))
            let trimmedRaw = line.trimmingCharacters(in: .whitespaces)
            if trimmedRaw.hasPrefix("#if DEBUG") { debugDepth += 1; continue }
            if debugDepth > 0 {
                if trimmedRaw.hasPrefix("#if") { debugDepth += 1 }
                if trimmedRaw.hasPrefix("#endif") { debugDepth -= 1 }
                continue
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if var open = pending {
                open += " " + line.trimmingCharacters(in: .whitespaces)
                if balanced(open) {
                    out.append((pendingLine, open))
                    pending = nil
                } else {
                    pending = open
                }
                continue
            }
            if balanced(line) {
                out.append((index + 1, line))
            } else {
                pending = line
                pendingLine = index + 1
            }
        }
        if let pending { out.append((pendingLine, pending)) }
        return out
    }

    private static func balanced(_ s: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for ch in s {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
        }
        return depth <= 0
    }

    // Drops a // comment, but never one that lives inside a string (a URL's //).
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        var previous: Character?
        for ch in line {
            if escaped { out.append(ch); escaped = false; previous = ch; continue }
            if ch == "\\" { out.append(ch); escaped = true; previous = ch; continue }
            if ch == "\"" { inString.toggle(); out.append(ch); previous = ch; continue }
            if !inString, ch == "/", previous == "/" {
                out.removeLast()
                return out
            }
            out.append(ch)
            previous = ch
        }
        return out
    }

    // MARK: - Which files are views

    static func viewFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .appendingPathComponent("Overture")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains(": View") || source.contains(": App") else { continue }
            out.append(url)
        }
        return out
    }
}
