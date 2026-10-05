import Testing
import Foundation

// #4343 (E0): which pure test files the release-like test run leaves out, DERIVED, and kept in step with the
// list the runner reads (mac/scripts/lib/release-like-excluded-tests.txt).
//
// The release-like run (`OVERTURE_TEST_RELEASE_LIKE=1`, mac/scripts/lib/release-like-build.sh) compiles DEBUG
// out of the pure suite so the acceptance rig times code shaped like the Release app. Every `#if DEBUG`
// declaration in the app is then gone (the queue's render counter, the Debug seed and staging, the landing's
// table snapshots), so a test file naming one outside `#if DEBUG` cannot compile there, and neither can a
// file using something such a file declares. Those files are LEFT OUT of that one build
// (EXCLUDED_SOURCE_FILE_NAMES) rather than wrapped in `#if DEBUG`: every source guard that skips Debug code
// (the window, store and container scans) would stop seeing a wrapped region in every ordinary run (L708).
//
// The list is derived here rather than kept by hand (L96, L41): the Debug-only names from the app's own
// `#if DEBUG` branches, the test files naming one, and the closure over what those files declare. A committed
// list that differs from the derivation fails, and `TEST_RUNNER_REGENERATE_RELEASE_LIKE_EXCLUSIONS=1` writes it
// (L422, L272). The acceptance rig's own file must never be on it, or the release-like reading would be
// UNMEASURED by construction.
@Suite("The release-like run leaves out exactly the pure test files that need DEBUG (#4343)")
struct ReleaseLikeBuildExclusionsTests {

    static let listURL = RepoRoot.mac.appendingPathComponent("scripts/lib/release-like-excluded-tests.txt")
    static let rigFile = "LandingAcceptanceRigTests.swift"

    // MARK: - The derivation, as pure functions over source text

    struct File {
        let name: String
        let text: String
    }

    // One `#if` group's DEBUG-only branch and its release branch, by line, ends exclusive.
    struct Branches {
        let ifLine: Int
        var debug: [ClosedRange<Int>] = []
        var release: [ClosedRange<Int>] = []
    }

    private struct Open {
        let line: Int
        let condition: String   // "DEBUG", "!DEBUG" or anything else
        var branchStart: Int
        var inElse = false
        var debug: [ClosedRange<Int>] = []
        var release: [ClosedRange<Int>] = []
    }

    // Every `#if DEBUG` (or `#if !DEBUG`) group in the code lines, with which lines compile only when DEBUG is
    // defined and which only when it is not. Other conditions are tracked so their `#else` and `#endif` are
    // not mistaken for a DEBUG group's.
    static func debugGroups(_ code: [Int: String]) -> [Branches] {
        var stack: [Open] = []
        var out: [Branches] = []
        func close(_ open: inout Open, before line: Int) {
            guard open.branchStart <= line - 1 else { return }
            let range = open.branchStart...(line - 1)
            let isDebug = (open.condition == "DEBUG") != open.inElse
            if open.condition == "DEBUG" || open.condition == "!DEBUG" {
                if isDebug { open.debug.append(range) } else { open.release.append(range) }
            }
        }
        for line in code.keys.sorted() {
            let text = code[line]!.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#if") {
                let condition = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
                stack.append(Open(line: line, condition: condition, branchStart: line + 1))
            } else if text.hasPrefix("#elseif"), !stack.isEmpty {
                close(&stack[stack.count - 1], before: line)
                // A DEBUG group continued by another condition is no longer only about DEBUG.
                stack[stack.count - 1] = Open(line: stack[stack.count - 1].line, condition: "other",
                                              branchStart: line + 1)
            } else if text.hasPrefix("#else"), !stack.isEmpty {
                close(&stack[stack.count - 1], before: line)
                stack[stack.count - 1].inElse = true
                stack[stack.count - 1].branchStart = line + 1
            } else if text.hasPrefix("#endif"), var open = stack.popLast() {
                close(&open, before: line)
                if open.condition == "DEBUG" || open.condition == "!DEBUG" {
                    out.append(Branches(ifLine: open.line, debug: open.debug, release: open.release))
                }
            }
        }
        return out
    }

    // The lines of a file that compile only when DEBUG is defined.
    static func debugOnlyLines(_ code: [Int: String]) -> Set<Int> {
        var lines: Set<Int> = []
        for group in debugGroups(code) {
            for range in group.debug { lines.formUnion(range) }
        }
        return lines
    }

    // The brace depth each line starts at.
    static func depths(_ code: [Int: String]) -> [Int: Int] {
        var depth = 0
        var out: [Int: Int] = [:]
        for line in code.keys.sorted() {
            out[line] = depth
            for c in code[line]! {
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
            }
        }
        return out
    }

    struct Declaration: Equatable {
        let keyword: String
        let name: String
        let isPrivate: Bool
    }

    private static let declarationPattern = try! NSRegularExpression(pattern:
        #"^\s*((?:@[A-Za-z_]+(?:\([^)]*\))?\s+|(?:public|internal|private|fileprivate)\(set\)\s+|(?:public|internal|private|fileprivate|static|final|nonisolated|override|mutating|lazy|indirect|convenience|required|open|class|weak|unowned)\s+)*)(func|var|let|enum|struct|class|actor|protocol|typealias|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#)

    // The declaration a code line opens, if it opens one with a name another file could use.
    static func declaration(in line: String) -> Declaration? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = declarationPattern.firstMatch(in: line, range: range),
              let modifiers = Range(m.range(at: 1), in: line).map({ String(line[$0]) }),
              let keyword = Range(m.range(at: 2), in: line).map({ String(line[$0]) }),
              let name = Range(m.range(at: 3), in: line).map({ String(line[$0]) }),
              name != "_" else { return nil }
        let words = modifiers.split(whereSeparator: \.isWhitespace)
        let isPrivate = words.contains("private") || words.contains("fileprivate")
        return Declaration(keyword: keyword, name: name, isPrivate: isPrivate)
    }

    // The names declared at `depth` within `lines`, and for an `extension` declared there, the names declared
    // one level inside it, since those are what a caller names.
    static func names(declaredAt depth: Int, in lines: [Int], code: [Int: String], depths: [Int: Int]) -> Set<String> {
        var names: Set<String> = []
        var insideExtension = false
        for line in lines {
            guard let d = depths[line] else { continue }
            if d == depth {
                insideExtension = false
                if let decl = declaration(in: code[line]!), !decl.isPrivate {
                    if decl.keyword == "extension" { insideExtension = true } else { names.insert(decl.name) }
                }
            } else if insideExtension, d == depth + 1, let decl = declaration(in: code[line]!), !decl.isPrivate,
                      decl.keyword != "extension" {
                names.insert(decl.name)
            }
        }
        return names
    }

    // Every name the app declares ONLY when DEBUG is defined: declared in a DEBUG branch at that branch's own
    // depth (a type's members are covered by the type's name), visible to another file, not declared again in
    // the same group's release branch, and not a local inside a function or a computed property's body.
    static func debugOnlyNames(_ files: [File]) -> Set<String> {
        let index = StoreWriteScan.Index(files: files.map { (name: $0.name, text: $0.text) })
        let bodies = Dictionary(grouping: index.functions + index.properties, by: \.file)
        var out: Set<String> = []
        for file in files {
            let code = SwiftSource.tokenize(file.text).codeLines
            let depths = depths(code)
            let lines = code.keys.sorted()
            for group in debugGroups(code) {
                // A group inside a body declares locals, which no other file can name.
                if (bodies[file.name] ?? []).contains(where: { $0.bodyLine < group.ifLine && group.ifLine <= $0.lastLine }) {
                    continue
                }
                let depth = depths[group.ifLine] ?? 0
                func declared(_ ranges: [ClosedRange<Int>]) -> Set<String> {
                    names(declaredAt: depth, in: lines.filter { l in ranges.contains { $0.contains(l) } },
                          code: code, depths: depths)
                }
                out.formUnion(declared(group.debug).subtracting(declared(group.release)))
            }
        }
        return out
    }

    // The names in `names` a file uses in code that compiles without DEBUG, with the first line each is on.
    static func uses(of names: Set<String>, in file: File) -> [(name: String, line: Int)] {
        guard !names.isEmpty else { return [] }
        let code = SwiftSource.tokenize(file.text).codeLines
        let skipped = debugOnlyLines(code)
        var found: [String: Int] = [:]
        for line in code.keys.sorted() where !skipped.contains(line) {
            for word in words(in: code[line]!) where names.contains(word) && found[word] == nil {
                found[word] = line
            }
        }
        return found.map { (name: $0.key, line: $0.value) }.sorted { $0.line < $1.line }
    }

    static func words(in line: String) -> [String] {
        var out: [String] = []
        var current = ""
        for c in line {
            if c.isLetter || c.isNumber || c == "_" { current.append(c) } else {
                if !current.isEmpty { out.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // The names a test file declares that another file could use: its top-level declarations, and the members
    // of its top-level extensions.
    static func exportedNames(_ file: File) -> Set<String> {
        let code = SwiftSource.tokenize(file.text).codeLines
        let skipped = debugOnlyLines(code)
        return names(declaredAt: 0, in: code.keys.sorted().filter { !skipped.contains($0) }, code: code,
                     depths: depths(code))
    }

    // The files to leave out, each with why, closed over use: a file using a name only a left out file declares
    // is left out too, until nothing changes.
    static func exclusions(app: [File], tests: [File]) -> [String: String] {
        let debugNames = debugOnlyNames(app)
        var excluded: [String: String] = [:]
        for file in tests {
            let used = uses(of: debugNames, in: file)
            if !used.isEmpty {
                excluded[file.name] = "names " + used.map(\.name).sorted().joined(separator: ", ")
            }
        }
        var changed = true
        while changed {
            changed = false
            var declaredBy: [String: String] = [:]
            for file in tests where excluded[file.name] != nil {
                for name in exportedNames(file) { declaredBy[name] = file.name }
            }
            for file in tests where excluded[file.name] == nil {
                let mine = exportedNames(file)
                let used = uses(of: Set(declaredBy.keys).subtracting(mine), in: file)
                if let first = used.first {
                    excluded[file.name] = "uses \(first.name) (\(declaredBy[first.name]!))"
                    changed = true
                }
            }
        }
        return excluded
    }

    // The list file's contents for a set of exclusions: a header, then each file under a comment saying why.
    static func listText(_ excluded: [String: String]) -> String {
        var out = """
            # GENERATED by ReleaseLikeBuildExclusionsTests (#4343). Do not edit by hand: run that suite with
            # TEST_RUNNER_REGENERATE_RELEASE_LIKE_EXCLUSIONS=1 to write it again.
            #
            # The pure test files the release-like test run (OVERTURE_TEST_RELEASE_LIKE=1) leaves out, because they
            # name an app symbol declared only under #if DEBUG, or use something a file like that declares.
            # mac/scripts/lib/release-like-build.sh hands these to xcodebuild as EXCLUDED_SOURCE_FILE_NAMES.

            """
        out += "\n"
        for name in excluded.keys.sorted() {
            out += "# \(excluded[name]!)\n\(name)\n"
        }
        return out
    }

    static func listedNames(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // Only an affirmative value asks, in either spelling: xcodebuild hands the test process a TEST_RUNNER_
    // variable with the prefix removed, which is the one that arrives (the copy inventory measured that).
    static func regenerationRequested(_ environment: [String: String]) -> Bool {
        ["REGENERATE_RELEASE_LIKE_EXCLUSIONS", "TEST_RUNNER_REGENERATE_RELEASE_LIKE_EXCLUSIONS"].contains { name in
            ["1", "true", "yes"].contains(environment[name]?.lowercased() ?? "")
        }
    }

    // MARK: - The real tree

    static func appFiles() -> [File] { AppSourceWalk.appFiles().map { File(name: $0.name, text: $0.text) } }

    static func pureTestFiles() -> [File] {
        AppSourceWalk.files(underAll: ["OvertureTests", "TestSupport"].map(RepoRoot.mac.appendingPathComponent),
                            floor: 100).map { File(name: $0.name, text: $0.text) }
    }

    @Test func theDerivationFindsTheAppsDebugOnlyDeclarations() {
        let names = Self.debugOnlyNames(Self.appFiles())
        // POSITIVE CONTROLS (L98): a type declared in a DEBUG branch, and members declared in one inside a type
        // that exists in both builds. A derivation finding none of these would clear every test file.
        for expected in ["QueueRenderCounter", "DebugSeed", "DebugStaging", "walkedRows", "batchTablesSnapshot",
                         "rebuiltBatchTablesSnapshot", "buildPartsNanoseconds"] {
            #expect(names.contains(expected), Comment(rawValue: "the derivation missed \(expected)"))
        }
        // Declared in both branches, so present in both builds; and private, so no other file can name it.
        for absent in ["isDebugBuild", "scheme", "rootRenderInputs", "debugMenuItems", "renderTrace"] {
            #expect(!names.contains(absent), Comment(rawValue: "\(absent) is not Debug-only to another file"))
        }
    }

    @Test func theCommittedListIsTheDerivedOne() throws {
        let tests = Self.pureTestFiles()
        let excluded = Self.exclusions(app: Self.appFiles(), tests: tests)
        let derived = Self.listText(excluded)
        // A census beside the verdict, so the size of the release-like build's gap is read rather than assumed.
        let hosted = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("OvertureHostedTests"), floor: 20)
            .map { File(name: $0.name, text: $0.text) }
        let hostedNaming = hosted.filter { !Self.uses(of: Self.debugOnlyNames(Self.appFiles()), in: $0).isEmpty }
        print("release-like exclusions: \(excluded.count) of \(tests.count) pure test files left out; "
              + "\(hostedNaming.count) of \(hosted.count) hosted test files name a Debug-only symbol "
              + "(the hosted target is not built by that run)")
        if Self.regenerationRequested(ProcessInfo.processInfo.environment) {
            try derived.write(to: Self.listURL, atomically: true, encoding: .utf8)
            print("release-like exclusions: wrote \(Self.listURL.path); review it with git diff")
            return
        }
        let committed = (try? String(contentsOf: Self.listURL, encoding: .utf8)) ?? ""
        #expect(committed == derived, Comment(rawValue: """
            \(Self.listURL.path) is not the derived list. Run \
            TEST_RUNNER_REGENERATE_RELEASE_LIKE_EXCLUSIONS=1 mac/scripts/run-tests-locked.sh \
            -only-testing:OvertureTests/ReleaseLikeBuildExclusionsTests to write it. Derived: \
            \(Self.listedNames(derived).joined(separator: ", ")); committed: \
            \(Self.listedNames(committed).joined(separator: ", "))
            """))
        #expect(excluded[Self.rigFile] == nil, Comment(rawValue: """
            the acceptance rig would be left out of the release-like build (\(excluded[Self.rigFile] ?? "")), so its \
            release-like reading could never be taken
            """))
    }

    // MARK: - The rule, on sources written here

    @Test func onlyADeclarationEveryOtherFileCanSeeAndOnlyOneBuildHasIsDebugOnly() {
        let app = File(name: "App.swift", text: """
            #if DEBUG
            enum OnlyInDebug { static func reset() {} }
            private enum HiddenInDebug {}
            #endif
            enum Everywhere {
                #if DEBUG
                static let flag = true
                static func snapshot() {}
                #else
                static let flag = false
                #endif
                func body() {
                    #if DEBUG
                    let localOnly = 1
                    #endif
                }
            }
            #if !DEBUG
            enum OnlyInRelease {}
            #else
            extension Everywhere {
                func debugMember() {}
                private func hiddenMember() {}
            }
            #endif
            """)
        #expect(Self.debugOnlyNames([app]) == ["OnlyInDebug", "snapshot", "debugMember"])
    }

    @Test func aFileNamingOneOutsideDebugIsLeftOutAndSoIsAFileUsingIt() {
        let app = File(name: "App.swift", text: "#if DEBUG\nenum Counter {}\n#endif\n")
        let names = File(name: "NamesTests.swift", text: "struct Helper {}\nlet c = Counter.self\n")
        let guarded = File(name: "GuardedTests.swift", text: "#if DEBUG\nlet c = Counter.self\n#endif\n")
        let inAString = File(name: "StringTests.swift", text: "let s = \"Counter\" // Counter\n")
        let usesHelper = File(name: "UsesTests.swift", text: "let h = Helper()\n")
        let unrelated = File(name: "OtherTests.swift", text: "let x = 1\n")
        let excluded = Self.exclusions(app: [app], tests: [names, guarded, inAString, usesHelper, unrelated])
        #expect(Set(excluded.keys) == ["NamesTests.swift", "UsesTests.swift"])
        #expect(excluded["NamesTests.swift"] == "names Counter")
        #expect(excluded["UsesTests.swift"] == "uses Helper (NamesTests.swift)")
    }

    @Test func theRunnersListIsTheNamesAloneUnderTheirReasons() {
        let text = Self.listText(["BTests.swift": "names Counter", "ATests.swift": "uses Helper (BTests.swift)"])
        #expect(Self.listedNames(text) == ["ATests.swift", "BTests.swift"])
        #expect(text.contains("# uses Helper (BTests.swift)\nATests.swift\n"))
    }
}
