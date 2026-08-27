import Foundation
import Testing

// #3154: a finished feature nothing in the app calls, found deliberately instead of one at a time.
//
// `UnreachedAppCodeTests` (#2811) asks its question only of `private` declarations, because a private
// name can be proved unused from its own file alone and a sweep over internal ones would need real
// reachability and would accuse correct code (L93). That subset is sound, and it is also why
// `DetachConversation.detach` sat finished, tested and reachable by nothing but its own tests from #2719
// until #2797 wired it: it is internal, so that guard could not see it. It was an UNDO Dan asked for, and
// #3069 quoted its refusal sentence as evidence the pair was wired while the whole function was
// unreachable, because a comment saying a thing is wired was the only thing in the tree that mentioned it.
//
// THE NARROWER QUESTION THIS CAN PROVE. An internal declaration in `mac/Overture/Domain` whose only
// mentions outside its own file are in the test targets is reachable by tests alone. That needs no call
// graph: it is three whole-word counts over text the repo's own lexer has already stripped comments from.
// Scoped to `Domain` deliberately, where the code is plain logic: a SwiftUI view's members are reached by
// dispatch this cannot see, and a guard that accused those would be switched off in a day.
//
// Three conditions, and the first is what keeps it honest. A name MENTIONED ELSEWHERE IN ITS OWN FILE is
// used, whatever its access level, so it is not reported: that case is over-broad access rather than dead
// code, and a rule that folded the two together would fire on dozens of correct declarations. A name with
// NO test mention either is not reported here: that is #2811's question about a wider set, and answering
// it would need the reachability this deliberately avoids.
//
// WHAT THE FIRST RUN FOUND, which is why this is a guard rather than a suggestion.
// `PrepQueueButton.canStart` is a `static func` whose own file says "RootView's `canStartPrep` now asks
// this". Measured 2026-08-27: `canStartPrep` appears in `mac/Overture` three times and every one is a
// COMMENT, so no view asks anything, and `canStart` is named by ten tests and by nothing else in the app.
// That is #3069's shape exactly, found on the first run.
//
// THE BASELINE IS A RATCHET, and it is strict in BOTH directions. `fixtures/test-only-reachable.txt`
// lists what was already here when this shipped. A finding NOT in it fails, which is the point. A LINE
// that is no longer a finding also fails, so an entry cannot outlive the code it describes and quietly
// exempt a future declaration that takes the same name (#2811 learned that one the same way). A line with
// no reason is UNTRIAGED DEBT and may only be removed; a line carrying a `# reason` has been looked at and
// is exempt on purpose. Both are named in the file's own header, because an entry with no reason beside
// entries with reasons is otherwise indistinguishable from one nobody thought about (L233).
@Suite("Domain code only the tests can reach (#3154)")
struct TestOnlyReachableDomainCodeTests {

    private static let domain = RepoRoot.mac.appendingPathComponent("Overture/Domain")
    private static let app = RepoRoot.mac.appendingPathComponent("Overture")
    private static let baselinePath =
        RepoRoot.url.appendingPathComponent("fixtures/test-only-reachable.txt")

    // An internal declaration: no explicit `private` or `fileprivate`, and one of the three keywords a
    // feature is finished in. `public` and `internal` are both spelled out because this repo writes
    // neither most of the time and both occasionally.
    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?!private\b|fileprivate\b)"#
            + #"(?:public\s+|internal\s+)?(?:static\s+|class\s+|final\s+)*(?:func|var|let)\s+([A-Za-z_]\w*)"#)

    struct Finding: Hashable, Comparable {
        let file: String
        let name: String
        var key: String { "\(file):\(name)" }
        static func < (a: Finding, b: Finding) -> Bool { a.key < b.key }
    }

    // MARK: - The detector

    // Whole-word, for the reason #2811 records: without the boundaries `list` is found inside `listing`,
    // nothing is ever reported, and the guard fails silently rather than loudly.
    static func mentions(_ name: String, in lines: [(line: Int, code: String)]) -> Int {
        guard let re = try? NSRegularExpression(
            pattern: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#) else { return 1 }
        return lines.reduce(0) { total, entry in
            total + re.numberOfMatches(in: entry.code, range: NSRange(entry.code.startIndex..., in: entry.code))
        }
    }

    static func declaredNames(in lines: [(line: Int, code: String)]) -> [String] {
        lines.compactMap { entry in
            let range = NSRange(entry.code.startIndex..., in: entry.code)
            guard let match = declaration.firstMatch(in: entry.code, range: range),
                  let nameRange = Range(match.range(at: 1), in: entry.code) else { return nil }
            return String(entry.code[nameRange])
        }
    }

    private static func scanned(_ url: URL, floor: Int) -> [(name: String, path: String, lines: [(line: Int, code: String)])] {
        AppSourceWalk.files(under: url, floor: floor).map {
            ($0.name, $0.url.path, SwiftSource.scannableLines(in: $0.text, skipping: []))
        }
    }

    static func findings() -> [Finding] {
        let appFiles = scanned(app, floor: 200)
        var testFiles = scanned(RepoRoot.mac.appendingPathComponent("OvertureTests"), floor: 400)
        testFiles += scanned(RepoRoot.mac.appendingPathComponent("OvertureHostedTests"), floor: 20)
        testFiles += scanned(RepoRoot.mac.appendingPathComponent("TestSupport"), floor: 5)

        var out: Set<Finding> = []
        for file in appFiles where file.path.contains("/Overture/Domain/") {
            for name in Set(declaredNames(in: file.lines)) {
                // Used somewhere else in its own file: not dead, whatever its access level.
                guard mentions(name, in: file.lines) <= 1 else { continue }
                // Named anywhere else in the app: reached, and this guard says nothing about it.
                guard !appFiles.contains(where: { $0.path != file.path && mentions(name, in: $0.lines) > 0 })
                else { continue }
                // Named by no test either: a different question, and #2811's, not this one.
                guard testFiles.contains(where: { mentions(name, in: $0.lines) > 0 }) else { continue }
                out.insert(Finding(file: file.name, name: name))
            }
        }
        return out.sorted()
    }

    // MARK: - The baseline

    // A line is `File.swift:name`, optionally followed by a `#` reason. Blank lines and whole-line
    // comments are the file's header.
    static func baselineKeys(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let key = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : key
        }
    }

    // MARK: - The detector was seen to find the shape, and to leave the ordinary ones alone

    @Test func findsAnInternalDeclarationOnlyItsTestsName() {
        let lines: [(line: Int, code: String)] = [
            (1, "enum PrepQueueButton {"),
            (2, "    static func canStart(keptToPrep: Int) -> Bool { keptToPrep > 0 }"),
            (3, "    private let unrelated = 1"),
            (4, "}"),
        ]
        #expect(Self.declaredNames(in: lines) == ["canStart"])
        #expect(Self.mentions("canStart", in: lines) == 1)
        // Used again in its own file, which is the case that must NOT be reported.
        let usedLocally = lines + [(5, "let ready = PrepQueueButton.canStart(keptToPrep: 3)")]
        #expect(Self.mentions("canStart", in: usedLocally) == 2)
    }

    @Test func readsABaselineLineWithAndWithoutAReason() {
        let keys = Self.baselineKeys(in: """
        # a header line, which is not an entry
        PrepQueueButton.swift:canStart

        SearchScope.swift:isHolding  # reached through a key path the scan cannot see
        """)
        #expect(keys == ["PrepQueueButton.swift:canStart", "SearchScope.swift:isHolding"])
    }

    // MARK: - The live claim

    @Test func theScanReallyReadsTheDomain() {
        let names = AppSourceWalk.files(under: Self.domain, floor: 60).flatMap {
            Self.declaredNames(in: SwiftSource.scannableLines(in: $0.text, skipping: []))
        }
        #expect(names.count > 400, "found only \(names.count) internal declarations; the scan is broken")
    }

    @Test func everyFindingIsInTheBaseline() throws {
        let text = try String(contentsOf: Self.baselinePath, encoding: .utf8)
        let known = Set(Self.baselineKeys(in: text))
        #expect(!known.isEmpty, "the baseline read as empty, so nothing below measured anything")
        let newcomers = Self.findings().map(\.key).filter { !known.contains($0) }
        #expect(newcomers.isEmpty, """
            These declarations in mac/Overture/Domain are named by the tests and by nothing else in the \
            app, so the only thing that can reach them is the suite that was written for them (#3154):
            \(newcomers.map { "  \($0)" }.joined(separator: "\n"))

            Wire it up, or delete it and its tests with it. If it is genuinely reachable by a route this \
            cannot see, add the line to fixtures/test-only-reachable.txt WITH the reason after a #.
            """)
    }

    // The other direction, and it is the half that keeps the list honest. An entry that is no longer a
    // finding has been fixed, and leaving it there would exempt a future declaration that happens to take
    // the same name.
    @Test func everyBaselineEntryIsStillAFinding() throws {
        let text = try String(contentsOf: Self.baselinePath, encoding: .utf8)
        let current = Set(Self.findings().map(\.key))
        let stale = Self.baselineKeys(in: text).filter { !current.contains($0) }
        #expect(stale.isEmpty, """
            These lines in fixtures/test-only-reachable.txt no longer describe anything: the code is \
            either reached now or gone. Delete them, so the list stays a measurement of what is left \
            rather than a record of what used to be (L182):
            \(stale.map { "  \($0)" }.joined(separator: "\n"))
            """)
    }
}
