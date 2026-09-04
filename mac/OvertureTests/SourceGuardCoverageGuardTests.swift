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

    // #2974: the body between `= [` and its MATCHING `]`, with nesting kept.
    //
    // `arrayLiteral`'s pattern is `=\s*\[([^\]]*)\]`, which ends at the FIRST `]`, so an array whose
    // first element is itself a dictionary (`[["a": 1], ["b": 2]]`) came back as `["a": 1` and the
    // dictionary test above never saw the closing bracket that would have excused it. That shape appears
    // nowhere in the suite today, which is why #2953 left it; it is closed here because the extraction is
    // the same few lines either way and a guard that reads fixture data as function names is what
    // teaches people to ignore the whole check (L36).
    //
    // String contents are skipped, so a bracket inside a literal cannot close the body.
    static func arrayLiteralBodies(in source: String) -> [String] {
        var bodies: [String] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            guard chars[i] == "=" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" { j += 1 }
            guard j < chars.count, chars[j] == "[" else { i += 1; continue }
            var depth = 0
            var inString = false
            var escaped = false
            var k = j
            var closed = false
            while k < chars.count {
                let c = chars[k]
                if escaped { escaped = false; k += 1; continue }
                if inString {
                    if c == "\\" { escaped = true }
                    if c == "\"" { inString = false }
                    k += 1
                    continue
                }
                if c == "\"" { inString = true; k += 1; continue }
                if c == "[" { depth += 1 }
                if c == "]" {
                    depth -= 1
                    if depth == 0 { closed = true; break }
                }
                k += 1
            }
            // An UNCLOSED bracket is not an array literal this can read, so it is skipped rather than
            // read to the end of the file, which would swallow everything after it (L98).
            if closed { bodies.append(String(chars[(j + 1)..<k])) }
            i = closed ? k + 1 : j + 1
        }
        return bodies
    }

    // #2974: does this array body hold key/value pairs ANYWHERE, not only at its own top level?
    //
    // `isDictionaryLiteral` asks about depth ZERO, which is the right question for `["a": 1]` and the
    // wrong one for `[["a": 1], ["b": 2]]`: that outer body is an array OF dictionaries, so its colons
    // sit at depth one and it read as a plain list, handing "a" and "b" to the name sweep as functions
    // that had gone missing. Now that the bodies come back with their nesting intact, this is the
    // question worth asking of them.
    //
    // A plain list of function names contains no colon outside a string. A Swift selector-style name
    // does (`"foo(bar:)"`), and it is inside a string, which the scan below skips.
    static func holdsKeyValuePairs(_ body: String) -> Bool {
        var inString = false
        var escaped = false
        for character in body {
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == ":" { return true }
        }
        return false
    }

    // #2974: is this path present ONLY in prose?
    //
    // Asked at the point of ACCUSATION rather than over the corpus, which is the whole reason it is
    // affordable. Stripping comments from every one of the 946 test files costs about 2.2 seconds of
    // every suite run and finds exactly the same 517 path literals (measured 2026-09-04). Asked only of
    // the paths that are about to be reported missing, it costs nothing at all today, because there are
    // none.
    //
    // A path in BOTH prose and code is judged as CODE: one comment must not excuse a genuinely stale
    // reference sitting beside it.
    static func pathIsOnlyInProse(_ path: String, in src: String) -> Bool {
        let quoted = "\"\(path)\""
        guard src.contains(quoted) else { return false }
        let code = SwiftSource.scannableLines(in: src, skipping: []).map(\.code).joined(separator: "\n")
        return !code.contains(quoted)
    }

    // #2953: is what sits between those brackets a DICTIONARY rather than a list of names?
    //
    // The bracket pattern above cannot tell the two apart, and an equality is an equals sign, so an
    // ordinary `#expect(table == ["hall": "https://..."])` read as a list of function names and named a
    // fixture KEY as a function that had gone missing. That cost #2816 real time chasing a fault that was
    // not there, and left it splitting a file to get out of the way of a guard. A check that cries wolf
    // is one people learn to ignore (L36).
    //
    // Judged by a colon at DEPTH ZERO, with string contents skipped, which is what separates a key from
    // the two colons that are not one: an argument label inside a call (`[Fixture(named: "pushOut")]`,
    // still a list) and a colon inside a string. Nesting is where this stops: the pattern above ends the
    // body at the first "]", so an array whose FIRST element is itself a dictionary is still read as a
    // list. That shape appears nowhere in the suite today and would need bracket-balanced extraction to
    // reach, which is a bigger change than the false alarm justifies.
    static func isDictionaryLiteral(_ body: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for character in body {
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case ":" where depth == 0: return true
            default: break
            }
        }
        return false
    }

    // #2953: the sweep reads CODE, never prose. A guard file's comments quote the very shapes these
    // patterns look for, and #2816 could not write the sentence explaining this defect down, because
    // writing the example out made the guard fail on its own explanation. A pattern that reads comments
    // is a pattern that fires on its own documentation (L103), which `SourceGuardMarkerIntegrityTests`
    // already had to learn; this is the same reading, spelled the same way.
    //
    // `skipping: []` on purpose: a DEBUG branch or a marked region inside a test file still holds real
    // references, and this is asking what the file references, not what the app says.
    private static func code(of text: String) -> String {
        SwiftSource.scannableLines(in: text, skipping: []).map(\.code).joined(separator: "\n")
    }

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
    //
    // Coarse is not the same as indiscriminate, which is what #2953 corrected: the sweep reads the file's
    // CODE, and a bracketed literal that is a DICTIONARY is fixture data rather than a list of names.
    private static func references(in src: String) -> FileReferences {
        let source = code(of: src)
        var names = Set(matches(namedLiteral, in: source))
        if hasMatch(namedNonLiteral, in: source) {
            for arrayBody in Self.arrayLiteralBodies(in: source)
                where !isDictionaryLiteral(arrayBody) && !Self.holdsKeyValuePairs(arrayBody) {
                names.formUnion(matches(identifierStringLiteral, in: arrayBody))
            }
        }
        return FileReferences(paths: referencedPaths(in: src), names: names)
    }

    // The path half, kept off the lexer deliberately. It is asked of every one of the 800-odd files in
    // OvertureTests, where the name sweep above only ever runs on the couple of dozen that call
    // SourceGuard.functionBody, and stripping comments from 8MB of Swift to reach a difference measured
    // at ZERO files (2026-08-18, over every test file in the repo) would cost the suite real time for
    // nothing. A source path quoted in a comment and since deleted is a false alarm of the same family
    // and is NOT covered here: nobody has hit one, and the day somebody does the fix is one line.
    private static func referencedPaths(in src: String) -> Set<String> {
        Set(matches(pathLiteral, in: src))
    }

    // #2311: through the shared walk, which refuses out loud on an empty result. This guard exists to
    // find stale references across every other test file, so a walk that finds none of them reports
    // that nothing is stale, which is the same sentence as "everything is fine".
    private static func otherTestFiles() throws -> [URL] {
        AppSourceWalk.urls(under: testsRoot).filter { $0.lastPathComponent != ownFileName }
    }

    // #2974: the decision, as a pure function over values, so BOTH its branches can be reached.
    //
    // The prose exemption below is unreachable on the real tree, because nothing there references a
    // path that is gone: a mutation removing it left the suite green, which is the wiring being
    // untested rather than the exemption being wrong (L3). `exists` is injected for the same reason the
    // files are: a fixture can then say a path is missing without anybody deleting a real file.
    static func staleReferences(in files: [(name: String, text: String)],
                                exists: (String) -> Bool) -> [String] {
        var missing: [String] = []
        for file in files {
            for path in referencedPaths(in: file.text) where !exists(path) {
                // A path quoted only in a COMMENT is prose about a file, not a reference to it, so a
                // deleted file it merely mentions is not a stale reference. Asked HERE, on the paths
                // about to be accused, rather than over the corpus: stripping comments from all 946 test
                // files costs about 2.2 seconds of every run and finds the same 517 paths (measured
                // 2026-09-04), while asking it of the accusations costs nothing on an ordinary run.
                guard !pathIsOnlyInProse(path, in: file.text) else { continue }
                missing.append("\(file.name) references \(path), which does not exist")
            }
        }
        return missing
    }

    @Test func everyReferencedSourcePathExists() throws {
        let files = try Self.otherTestFiles().map {
            (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8))
        }
        let missing = Self.staleReferences(in: files) {
            FileManager.default.fileExists(atPath: Self.macRoot.appendingPathComponent($0).path)
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

    // MARK: - What the sweep is allowed to read (#2953)

    // A file in the exact shape this sweep reads: it passes `named:` a non-literal, so its array
    // literals are swept for function names, and it also holds an ordinary assertion comparing a built
    // table against a DICTIONARY of fixture values. Both halves are asked of this ONE fixture on
    // purpose: a test that only asserts the dictionary is ignored is satisfied by a fixture in which
    // nothing could have been found at all (L159), so the list of real handler names has to be picked
    // out of the same text.
    private static let fileWithAListOfNamesAndADictionaryFixture = #"""
        @Suite("A guard in the shape this sweep reads")
        struct AGuard {
            private static let guardedFunctions = ["pushOut", "standDown"]

            @Test func theHandlersStillSurfaceASaveFailure() throws {
                let src = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
                for name in Self.guardedFunctions {
                    let body = try SourceGuard.functionBody(named: name, in: src)
                    #expect(!body.contains("try? context.save()"))
                }
            }

            @Test func theTableIsBuiltFromTheWatchedSources() {
                #expect(table == ["hall": "https://example-hall.example/whats-on"])
            }
        }
        """#

    // The same shape again, with the example written out in PROSE. #2816 had to leave the sentence
    // explaining this defect unwritten, because writing it made the guard fail on its own explanation.
    private static let fileWhoseCommentQuotesTheExample = #"""
        // The sweep collects names from anything array-shaped after an equals sign, so an assertion
        // like `#expect(table == ["hall": "https://example-hall.example/whats-on"])` read as a list of
        // function names, and so did a bare example = ["quotedInProse"].
        @Suite("A guard whose comment quotes the shape that broke it")
        struct AGuard {
            private static let guardedFunctions = ["pushOut"]

            @Test func theHandlersStillSurfaceASaveFailure() throws {
                let src = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
                for name in Self.guardedFunctions {
                    _ = try SourceGuard.functionBody(named: name, in: src)
                }
            }
        }
        """#

    @Test func aDictionaryFixtureIsNotReadAsAListOfFunctionNames() {
        let refs = Self.references(in: Self.fileWithAListOfNamesAndADictionaryFixture)
        #expect(refs.paths == ["Overture/UI/FollowUpsView.swift"])
        // The positive half, in this same fixture: a list of handler names is still collected, so a
        // name that has genuinely moved out of every path the file reads is still caught.
        #expect(refs.names == ["pushOut", "standDown"],
                """
                the sweep must still read a file's own list of handler names; it collected \
                \(refs.names.sorted().joined(separator: ", "))
                """)
        // And the negative half: a dictionary's keys and values are fixture data, not references
        // anybody wrote. #2816 was told a fixture key was a function that had gone missing (#2953).
        #expect(!refs.names.contains("hall"),
                "a dictionary fixture's key was read as a function name this file references (#2953)")
    }

    @Test func theSweepReadsCodeAndNotComments() {
        let refs = Self.references(in: Self.fileWhoseCommentQuotesTheExample)
        #expect(refs.names == ["pushOut"],
                """
                the sweep read a name out of prose; it collected \
                \(refs.names.sorted().joined(separator: ", "))
                """)
        #expect(!refs.names.contains("quotedInProse"),
                "an example quoted in a comment was read as a function reference (#2953)")
        #expect(!refs.names.contains("hall"),
                "a dictionary quoted in a comment was read as a function reference (#2953)")
    }

    // The classifier itself, exercised on each shape it claims to tell apart rather than only ever
    // watched not to fire on the one fixture above (L151). The two it must NOT condemn are the ones a
    // fixture is least likely to reach for: a colon inside a call's argument label, and a colon inside
    // a string.
    @Test func theDictionaryClassifierKnowsEachShapeItNames() {
        #expect(Self.isDictionaryLiteral(#""hall": "https://example-hall.example/whats-on""#))
        #expect(Self.isDictionaryLiteral(":"))                                  // [:], the empty one
        #expect(Self.isDictionaryLiteral(#".hall: "a-source""#))                // a non-string key

        #expect(!Self.isDictionaryLiteral(#""pushOut", "standDown""#))
        #expect(!Self.isDictionaryLiteral(#"Fixture(named: "pushOut"), Fixture(named: "standDown")"#))
        #expect(!Self.isDictionaryLiteral(#""a: b", "c""#))
    }
}
