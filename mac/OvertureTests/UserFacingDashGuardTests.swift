import Testing
import Foundation

// #343: brand voice forbids em/en dashes in user-facing copy, and they read as an AI tell. This
// scans the app's own Swift source for forbidden dashes that sit inside string literals (not
// comments, where the codebase uses them as a convention) and fails if any appear. Complements
// DraftCheck, which catches em dashes in generated email bodies at runtime.
@Suite("No em/en dashes in user-facing string literals")
struct UserFacingDashGuardTests {
    // Legitimate, non-copy uses of the dash characters: an HTML-entity decode map that must map
    // mdash/ndash to the real characters (Prospect.swift), a parsing regex with a dash character
    // class (GroupNameMatch.swift), and the definition of the forbidden dashes themselves
    // (Typography.swift), which this guard reuses.
    private let allowlistedFiles: Set<String> = ["Prospect.swift", "GroupNameMatch.swift", "Typography.swift"]

    @Test func appSourceHasNoForbiddenDashInStringLiterals() throws {
        let appDir = Self.appSourceDirectory()
        let files = AppSourceWalk.urls(under: appDir)
        #expect(!files.isEmpty)   // guard against a wrong path silently passing

        var offenders: [String] = []
        for file in files where !allowlistedFiles.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for hit in Self.dashesInStringLiterals(text) {
                offenders.append("\(file.lastPathComponent):\(hit.line)  …\(hit.context)…")
            }
        }
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, "Forbidden em/en dash in user-facing string(s):\n\(report)")
    }

    // #380: Dan's writing rule bans dashes in code comments too, not just string literals.
    // Typography.swift's own definition is the sole exception, since it has to show the literal
    // character it names.
    @Test func appSourceHasNoForbiddenDashInComments() throws {
        let allowlistedLines: Set<String> = ["Typography.swift:8", "Typography.swift:9"]
        let appDir = Self.appSourceDirectory()
        let files = AppSourceWalk.urls(under: appDir)
        #expect(!files.isEmpty)

        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for hit in Self.dashesInComments(text) {
                let key = "\(file.lastPathComponent):\(hit.line)"
                guard !allowlistedLines.contains(key) else { continue }
                offenders.append("\(file.lastPathComponent):\(hit.line)  …\(hit.context)…")
            }
        }
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, "Forbidden em/en dash in comment(s):\n\(report)")
    }

    // MARK: - Source location

    private static func appSourceDirectory(file: StaticString = #filePath) -> URL {
        // #1993: searched for, not counted to. A wrong path here yields no files to walk, so the
        // guard passes over everything it exists to check and reports a clean app. #2311 moved the
        // refusal into AppSourceWalk, so this guard inherits it rather than remembering it.
        RepoRoot.app
    }

    // MARK: - Scanner

    struct Hit { let line: Int; let context: String }
    private enum DashLocation { case stringLiteral, comment }

    static func dashesInStringLiterals(_ source: String) -> [Hit] {
        allDashHits(source).filter { $0.location == .stringLiteral }.map { $0.hit }
    }

    static func dashesInComments(_ source: String) -> [Hit] {
        allDashHits(source).filter { $0.location == .comment }.map { $0.hit }
    }

    // A small state machine: walk the source character by character, tracking whether we're in code,
    // a // or /* */ comment, or a "…" / """…""" string literal, and tag any forbidden dash by which
    // of the two it sits in. Tracking string vs comment state is what keeps a URL's // inside a
    // string from ever being mistaken for the start of a comment.
    private static func allDashHits(_ source: String) -> [(location: DashLocation, hit: Hit)] {
        enum State { case code, line, block, string, multiline }
        let chars = Array(source)
        var state: State = .code
        var i = 0, lineNo = 1
        var hits: [(location: DashLocation, hit: Hit)] = []
        func starts(_ s: String, at idx: Int) -> Bool {
            let t = Array(s)
            guard idx + t.count <= chars.count else { return false }
            return Array(chars[idx..<idx + t.count]) == t
        }
        func record(_ location: DashLocation) {
            let lo = max(0, i - 12), hi = min(chars.count, i + 13)
            hits.append((location, Hit(line: lineNo, context: String(chars[lo..<hi]))))
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { lineNo += 1 }
            switch state {
            case .code:
                if starts("//", at: i) { state = .line; i += 2 }
                else if starts("/*", at: i) { state = .block; i += 2 }
                else if starts("\"\"\"", at: i) { state = .multiline; i += 3 }
                else if c == "\"" { state = .string; i += 1 }
                else { i += 1 }
            case .line:
                if c == "\n" { state = .code; i += 1 }
                else { if Typography.forbiddenDashes.contains(c) { record(.comment) }; i += 1 }
            case .block:
                if starts("*/", at: i) { state = .code; i += 2 }
                else { if Typography.forbiddenDashes.contains(c) { record(.comment) }; i += 1 }
            case .string:
                if starts("\\u{2014}", at: i) || starts("\\u{2013}", at: i) { record(.stringLiteral); i += 8 }
                else if c == "\\" { i += 2 }                  // skip an escaped character
                else if c == "\"" { state = .code; i += 1 }
                else { if Typography.forbiddenDashes.contains(c) { record(.stringLiteral) }; i += 1 }
            case .multiline:
                if starts("\"\"\"", at: i) { state = .code; i += 3 }
                else if starts("\\u{2014}", at: i) || starts("\\u{2013}", at: i) { record(.stringLiteral); i += 8 }
                else { if Typography.forbiddenDashes.contains(c) { record(.stringLiteral) }; i += 1 }
            }
        }
        return hits
    }
}
