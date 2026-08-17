import Testing
import Foundation

// #2313: a helper both Swift test targets use has to live in `mac/TestSupport/`, and until now nothing
// said so except AGENTS.md.
//
// The two targets compile DISJOINT folders (`mac/project.yml`: each takes its own directory plus
// `TestSupport`), so a type declared in `OvertureTests/` is not visible from `OvertureHostedTests/` at
// all. That is what makes the drift silent rather than loud: the second target cannot reference the
// helper, so whoever needs it there COPIES it, both copies compile, and the two answer identically
// right up until one of them is fixed. A guard reading the stale copy then keeps passing, which is the
// cost (#987/#1001/#1005 is the same defect in another guise, two source-health recorders drifting
// until one silently stopped writing a field).
//
// So the detectable shape is a type NAME declared at top level in both folders, plus the same name
// declared in a test folder AND in `TestSupport/`, which is a copy shadowing the shared one. Measured
// 2026-08-16: 1050 top-level types in `OvertureTests/`, 46 in `OvertureHostedTests/`, 10 in
// `TestSupport/`, and zero overlap of any kind. So this is a guard against the next one rather than a
// live finding, and its detector is exercised against a planted copy below rather than only ever being
// watched not to fire (L1).
@Suite("A helper both test targets use lives in TestSupport (#2313)")
struct SharedTestHelperGuardTests {

    // MARK: - The detector, as a pure function

    struct Declaration: Equatable, Hashable {
        var name: String
        var file: String
    }

    // Every type declared at TOP LEVEL, which is the only kind that can be a shared helper: a type
    // nested inside a suite is reachable by nobody else even within its own target, so a second copy of
    // one is two independent fixtures rather than a helper that drifted.
    //
    // Read through the lexer with comments stripped, because a guard that matches raw source text is
    // answered by prose ABOUT the thing as readily as by the thing (L103), and this repo's test files
    // carry long comments that quote declarations.
    static func topLevelTypes(in text: String, file: String) -> [Declaration] {
        var out: [Declaration] = []
        for line in SwiftSource.scannableLines(in: text, skipping: []) {
            let code = line.code
            guard !code.hasPrefix(" "), !code.hasPrefix("\t") else { continue }
            var rest = Substring(code)
            // Attributes and modifiers can sit ahead of the keyword on the same line
            // (`@MainActor final class`, `private struct`), so step over them rather than trying to
            // spell every ordering in one pattern.
            while let word = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
                  word.hasPrefix("@") || Self.modifiers.contains(String(word)) {
                guard let space = rest.firstIndex(of: " ") else { rest = ""; break }
                rest = rest[rest.index(after: space)...]
            }
            let words = rest.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 2, Self.typeKeywords.contains(String(words[0])) else { continue }
            let name = words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            out.append(Declaration(name: String(name), file: file))
        }
        return out
    }

    private static let modifiers: Set<String> = [
        "public", "internal", "private", "fileprivate", "open", "final", "indirect",
    ]
    private static let typeKeywords: Set<String> = ["struct", "enum", "class", "actor", "protocol"]

    // A name declared in more than one of the folders handed in. Returned as the name with every file
    // that declares it, because the fix ("move it to TestSupport") needs both sides named: a message
    // saying only that a duplicate exists leaves the reader grepping for the other copy.
    static func declaredInMoreThanOneFolder(_ folders: [String: [Declaration]]) -> [String: [String]] {
        var homes: [String: [String]] = [:]
        for (folder, declarations) in folders {
            for declaration in Set(declarations) {
                homes[declaration.name, default: []].append("\(folder)/\(declaration.file)")
            }
        }
        return homes.filter { name, files in
            Set(files.map { $0.split(separator: "/").first.map(String.init) ?? "" }).count > 1
                && !name.isEmpty
        }
    }

    // MARK: - The detector was seen to find a copy

    @Test func findsATypeCopiedIntoBothTestTargets() {
        let pure = Self.topLevelTypes(in: """
        import Foundation
        // A comment mentioning struct NotADeclaration { } must not count.
        enum PitchFixture {
            static let org = "Aurora Strings"
        }
        @Suite("something")
        struct SomethingTests {
            struct NestedFixture { }
        }
        """, file: "PitchFixture.swift")
        let hosted = Self.topLevelTypes(in: """
        import Foundation
        enum PitchFixture {
            static let org = "Aurora Strings"
        }
        """, file: "PitchFixtureCopy.swift")

        #expect(pure.map(\.name).sorted() == ["PitchFixture", "SomethingTests"])
        #expect(hosted.map(\.name) == ["PitchFixture"])

        let shared = Self.declaredInMoreThanOneFolder(["OvertureTests": pure, "OvertureHostedTests": hosted])
        #expect(shared.keys.sorted() == ["PitchFixture"])
        #expect(shared["PitchFixture"]?.sorted()
                == ["OvertureHostedTests/PitchFixtureCopy.swift", "OvertureTests/PitchFixture.swift"])
    }

    // And the ordinary case it must not fire on: two names that merely look alike, and a fixture nested
    // inside a suite in each target, which is two independent fixtures rather than one helper copied.
    @Test func doesNotFireOnDistinctNamesOrNestedFixtures() {
        let pure = Self.topLevelTypes(in: """
        struct QueueRowFixture { }
        @Suite("a")
        struct ATests {
            struct Recipient { }
        }
        """, file: "A.swift")
        let hosted = Self.topLevelTypes(in: """
        struct QueueRowOnScreenFixture { }
        @Suite("b")
        struct BTests {
            struct Recipient { }
        }
        """, file: "B.swift")
        #expect(Self.declaredInMoreThanOneFolder(
            ["OvertureTests": pure, "OvertureHostedTests": hosted]).isEmpty)
    }

    // MARK: - The live claim

    private static func declarations(in folder: String, floor: Int) -> [Declaration] {
        // Through the shared walk (#2311), which refuses out loud rather than handing back an empty
        // list this guard would read as a clean result.
        AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent(folder), floor: floor)
            .flatMap { Self.topLevelTypes(in: $0.text, file: $0.name) }
    }

    @Test func noHelperIsDeclaredInBothTestTargetsOrShadowsTheSharedOne() {
        let folders = [
            "OvertureTests": Self.declarations(in: "OvertureTests", floor: 100),
            "OvertureHostedTests": Self.declarations(in: "OvertureHostedTests", floor: 5),
            "TestSupport": Self.declarations(in: "TestSupport", floor: 5),
        ]
        let shared = Self.declaredInMoreThanOneFolder(folders)
        let report = shared.keys.sorted().map { name in
            "\(name): \((shared[name] ?? []).sorted().joined(separator: ", "))"
        }
        #expect(report.isEmpty,
                """
                these types are declared in more than one of mac/OvertureTests, mac/OvertureHostedTests \
                and mac/TestSupport, so they are copies rather than one helper: \
                \(report.joined(separator: "; ")). The two test targets compile disjoint folders, so \
                neither can see the other's copy and the two will drift; a guard reading the stale one \
                keeps passing. Move it to mac/TestSupport/, which both targets compile (#2313).
                """)
    }
}
