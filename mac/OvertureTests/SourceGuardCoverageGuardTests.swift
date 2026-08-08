import Testing
import Foundation

// Meta-guard for #629: every other SourceGuard-based regression test hardcodes a source-file
// path string and a function name, with nothing but running that one test to confirm they still
// resolve. When a function moves to a different file, each affected guard test discovers its own
// now-stale reference one at a time, on its own separate build/test failure: moving 19 functions
// out of QueueView.swift turned up 4 separate stale references in 4 separate files, 2 during
// planning and 2 more only after a real build failure and a code review pass, discovered one at a
// time instead of all at once.
//
// This scans every other file in OvertureTests for every source-path and function-name literal
// reachable from a SourceGuard call, and fails loudly, in one place, listing every stale
// reference together, instead of requiring a fix-and-rerun cycle per file.
@Suite("SourceGuard reference coverage (#629)")
struct SourceGuardCoverageGuardTests {

    private static var testsRoot: URL { RepoRoot.mac.appendingPathComponent("OvertureTests") }

    private static var macRoot: URL { RepoRoot.mac }

    private static let ownFileName = URL(fileURLWithPath: #filePath).lastPathComponent

    // Any string literal shaped like a relative path into Overture/, however it reaches
    // SourceGuard: SourceGuardHelper.source("..."), a file-local source(_:) wrapper around it, or
    // a hand-built URL(fileURLWithPath:).appendingPathComponent("...").
    private static let pathLiteral = try! NSRegularExpression(
        pattern: #""([A-Za-z0-9_/]*Overture/[A-Za-z0-9_/]+\.swift)""#)

    // A function name passed directly as a literal: SourceGuard.functionBody(named: "foo", ...).
    private static let namedLiteral = try! NSRegularExpression(pattern: #"named:\s*"([A-Za-z_][A-Za-z0-9_]*)""#)

    // Whether this file ALSO passes named: a non-literal (a loop variable or constant), the
    // pattern several guard-test files use to scan a whole list of handler functions at once.
    private static let namedNonLiteral = try! NSRegularExpression(pattern: #"named:\s*[A-Za-z_][A-Za-z0-9_]*\b"#)

    // Array literals (`= [ "a", "b", ... ]`), the shape those lists of handler names take.
    private static let arrayLiteral = try! NSRegularExpression(
        pattern: #"=\s*\[([^\]]*)\]"#, options: [.dotMatchesLineSeparators])
    private static let identifierStringLiteral = try! NSRegularExpression(pattern: #""([A-Za-z_][A-Za-z0-9_]*)""#)

    private static func matches(_ regex: NSRegularExpression, in text: String, group: Int = 1) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: group))
        }
    }

    private static func hasMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private struct FileReferences {
        let paths: Set<String>
        let names: Set<String>
    }

    // When named: takes a non-literal, we can't always trace exactly which array it came from
    // (it may pass through a helper function's parameter), so instead of chasing that call graph
    // we sweep every array literal in the file. That's coarser than a precise call-site link, but
    // it means a name that has genuinely moved out of every path this file references still gets
    // caught, which is the actual failure mode #629 is about.
    private static func references(in src: String) -> FileReferences {
        let paths = Set(matches(pathLiteral, in: src))
        var names = Set(matches(namedLiteral, in: src))
        if hasMatch(namedNonLiteral, in: src) {
            for arrayBody in matches(arrayLiteral, in: src) {
                names.formUnion(matches(identifierStringLiteral, in: arrayBody))
            }
        }
        return FileReferences(paths: paths, names: names)
    }

    private static func otherTestFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != ownFileName }
    }

    @Test func everyReferencedSourcePathExists() throws {
        var missing: [String] = []
        for file in try Self.otherTestFiles() {
            let src = try String(contentsOf: file, encoding: .utf8)
            for path in Self.references(in: src).paths {
                let full = Self.macRoot.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: full.path) {
                    missing.append("\(file.lastPathComponent) references \(path), which does not exist")
                }
            }
        }
        #expect(missing.isEmpty, "Stale SourceGuard file-path reference(s):\n\(missing.joined(separator: "\n"))")
    }

    @Test func everyReferencedFunctionNameExistsInOneOfItsFilesReferencedPaths() throws {
        var missing: [String] = []
        for file in try Self.otherTestFiles() {
            let src = try String(contentsOf: file, encoding: .utf8)
            guard src.contains("SourceGuard.functionBody(") else { continue }

            let refs = Self.references(in: src)
            guard !refs.paths.isEmpty else {
                missing.append("\(file.lastPathComponent) calls SourceGuard.functionBody but this guard found no " +
                    "referenced source path in it; update this file's regexes for its shape")
                continue
            }
            guard !refs.names.isEmpty else {
                missing.append("\(file.lastPathComponent) calls SourceGuard.functionBody but this guard found no " +
                    "referenced function name in it; update this file's regexes for its shape")
                continue
            }

            var sources: [String: String] = [:]
            for path in refs.paths {
                let full = Self.macRoot.appendingPathComponent(path)
                sources[path] = (try? String(contentsOf: full, encoding: .utf8)) ?? ""
            }
            for name in refs.names {
                let existsSomewhere = sources.values.contains { $0.contains("func \(name)(") }
                if !existsSomewhere {
                    missing.append("\(file.lastPathComponent) references function \"\(name)\" but it doesn't exist " +
                        "in any of this file's referenced paths: \(refs.paths.sorted().joined(separator: ", "))")
                }
            }
        }
        #expect(missing.isEmpty, "Stale SourceGuard function-name reference(s):\n\(missing.joined(separator: "\n"))")
    }
}
