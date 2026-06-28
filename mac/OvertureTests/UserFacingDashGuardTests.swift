import Testing
import Foundation
@testable import Overture

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
        let files = Self.swiftFiles(under: appDir)
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

    // MARK: - Source location

    private static func appSourceDirectory(file: StaticString = #filePath) -> URL {
        // #filePath -> .../mac/OvertureTests/UserFacingDashGuardTests.swift; climb to mac/Overture.
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()        // OvertureTests
            .deletingLastPathComponent()        // mac
            .appendingPathComponent("Overture")
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = e?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    // MARK: - Scanner

    struct Hit { let line: Int; let context: String }

    // A small state machine: walk the source character by character, tracking whether we're in code,
    // a // or /* */ comment, or a "…" / """…""" string literal, and report any forbidden dash that
    // occurs inside a string. Tracking string vs comment state is what keeps URLs (// inside a
    // string) and dash-laden comments from triggering false hits.
    static func dashesInStringLiterals(_ source: String) -> [Hit] {
        enum State { case code, line, block, string, multiline }
        let chars = Array(source)
        var state: State = .code
        var i = 0, lineNo = 1
        var hits: [Hit] = []
        func starts(_ s: String, at idx: Int) -> Bool {
            let t = Array(s)
            guard idx + t.count <= chars.count else { return false }
            return Array(chars[idx..<idx + t.count]) == t
        }
        func record() {
            let lo = max(0, i - 12), hi = min(chars.count, i + 13)
            hits.append(Hit(line: lineNo, context: String(chars[lo..<hi])))
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
                if c == "\n" { state = .code }
                i += 1
            case .block:
                if starts("*/", at: i) { state = .code; i += 2 } else { i += 1 }
            case .string:
                if starts("\\u{2014}", at: i) || starts("\\u{2013}", at: i) { record(); i += 8 }
                else if c == "\\" { i += 2 }                  // skip an escaped character
                else if c == "\"" { state = .code; i += 1 }
                else { if Typography.forbiddenDashes.contains(c) { record() }; i += 1 }
            case .multiline:
                if starts("\"\"\"", at: i) { state = .code; i += 3 }
                else if starts("\\u{2014}", at: i) || starts("\\u{2013}", at: i) { record(); i += 8 }
                else { if Typography.forbiddenDashes.contains(c) { record() }; i += 1 }
            }
        }
        return hits
    }
}
