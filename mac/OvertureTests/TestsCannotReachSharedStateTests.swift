import Testing
import Foundation

// #2540: a test must be structurally unable to reach a real shared location, not merely careful about it
// (L2).
//
// Two instances were known when this was filed, in two languages. The eval fixtures stubbed the `claude`
// CLI and those stubbed runs wrote the repo's REAL record of when the paid eval last completed, so a shell
// script pretending to be the model could mark the drafting rules as freshly scored against live output.
// And the Swift suite wrote into the live Debug handoff directory. Both are fixed: the second by #2097,
// which redirects the handoff directory at the point it is RESOLVED rather than at each call site, so a
// writer added later arrives protected.
//
// What was missing is the third thing the issue asked for: an enumeration, derived from the code, of the
// paths a test can still reach, so this cannot come back through a door nobody listed. That is this file.
//
// Measured 2026-08-15 across all test sources: no test WRITES to a real shared location. Every test that
// touches UserDefaults already builds a private suite. So this guard costs nothing today and exists to
// keep the answer at zero.
@Suite("A test cannot reach real shared state (#2540)")
struct TestsCannotReachSharedStateTests {

    // The APIs that reach something shared with the real app, and what to use instead. The message is
    // part of the rule: a guard that only says no is one somebody works around.
    private static let forbidden: [(api: String, instead: String)] = [
        ("UserDefaults.standard",
         "ScratchDefaults.make(\"<label>\"), which names a private suite and deletes it afterwards (#3774)"),
        ("NSHomeDirectory()",
         "a temp directory the test makes and asserts on"),
        ("homeDirectoryForCurrentUser",
         "a temp directory the test makes and asserts on"),
        (".applicationSupportDirectory",
         "StoreLocation.handoffDirectory, which #2097 redirects to a per-run folder under test"),
    ]

    // Named one by one, with the reason, because an exemption list is the part of a guard that rots. Each
    // one is asserted to still exist and to still need it, below.
    private static let exempt: [String: String] = [
        "StoreLocationTests.swift":
            "computes the path only to assert a PURE function's output. It performs no I/O at all: the "
            + "whole point of StoreLocation is that the decision is a function of its arguments.",
        "PerformerMatchPrecisionCheckTests.swift":
            "an opt-in diagnostic that READS Dan's real export on purpose, to report what the matcher "
            + "would do to real names. Disabled unless explicitly enabled, and it writes nothing.",
        "HandoffPathGuardTests.swift":
            "the guard that forbids this API in the APP's source, so it has to name it to search for it.",
        "TestsCannotReachSharedStateTests.swift":
            "this file, which names every API it forbids.",
        "ScratchDefaults.swift":
            "the helper that DELETES the tests' own defaults files from ~/Library/Preferences (#3774). It "
            + "has to name the real folder to clean it, it touches only files carrying its own prefix, and "
            + "its sweep is proved against a temp directory standing in for that folder.",
    ]

    // Through AppSourceWalk, never a private enumerator: the walk is what REFUSES when it comes back
    // short, so a guard standing on its own walker cannot tell "checked everything, found nothing wrong"
    // from "checked nothing" (#2311). `AppSourceWalkTests` enforces that, and caught this file doing it.
    private static func testSourceFiles() -> [AppSourceWalk.File] {
        ["OvertureTests", "OvertureHostedTests", "TestSupport"].flatMap { directory in
            AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent(directory), floor: 5)
        }
    }

    @Test("no test reaches a real shared location")
    func noTestReachesSharedState() throws {
        let files = Self.testSourceFiles()
        #expect(files.count > 100, "the walk found \(files.count) test files, which is not the suite")

        var offenders: [String] = []
        for file in files where Self.exempt[file.name] == nil {
            for (line, code) in SwiftSource.scannableLines(in: file.text, skipping: []) {
                for rule in Self.forbidden where code.contains(rule.api) {
                    offenders.append("\(file.name):\(line)  \(rule.api)  ->  use \(rule.instead)")
                }
            }
        }
        #expect(offenders.isEmpty, """
            A test reaches a location the real app shares. Being careful is not enough here, because the \
            damage lands in Dan's live data and looks like nothing happened (L2):
            \(offenders.joined(separator: "\n"))
            """)
    }

    // An exemption for a file that no longer exists is a rule nobody is following any more, and it makes
    // the list read as though it were still doing work.
    @Test("every exemption still names a real file")
    func exemptionsAreNotStale() {
        let present = Set(Self.testSourceFiles().map(\.name))
        for name in Self.exempt.keys {
            #expect(present.contains(name), "\(name) is exempted and does not exist")
        }
    }

    // And every exemption is still USED. One whose file stopped naming the API is an exemption that would
    // silently cover a future reach in that file, which is the same defect one level up.
    @Test("every exemption is still needed")
    func exemptionsAreStillUsed() throws {
        for (name, reason) in Self.exempt where name != "TestsCannotReachSharedStateTests.swift" {
            guard let file = Self.testSourceFiles().first(where: { $0.name == name }) else {
                Issue.record("\(name) could not be read")
                continue
            }
            let stillNamesOne = Self.forbidden.contains { file.text.contains($0.api) }
            #expect(stillNamesOne, "\(name) no longer reaches anything, so drop its exemption (\(reason))")
        }
    }

    // #3774: and the ONLY way a test builds a defaults suite is `ScratchDefaults.make`.
    //
    // #3272 put a rule here that every suite a test built carried a UUID, so two tests could never share
    // one. It held, and it was the wrong question: every one of those unique suites is a real file in
    // `~/Library/Preferences`, and nothing deleted any of them. Measured 2026-09-10, that folder held
    // 745,089 files, 528 of them real preferences, and listing it took minutes; cleared by hand that day,
    // it was back to 67,696 by 2026-09-19. The ten sites that called `removePersistentDomain` leaked too,
    // because that call empties the domain and LEAVES THE FILE (measured, see ScratchDefaults.swift).
    //
    // A rule every call site must opt into cannot be enforced by a scan (L621), so the scan now enforces
    // the one thing that can be: a raw `UserDefaults(suiteName:` anywhere in the test sources outside the
    // helper itself. Uniqueness and cleanup both live in the helper, so neither can be forgotten.
    private static let defaultsSuiteExempt: [String: String] = [
        "ScratchDefaults.swift":
            "the helper itself, which is the one place a suite is built and the one place it is removed.",
        "TestsCannotReachSharedStateTests.swift":
            "this file, which has to name the API in order to forbid it.",
    ]

    // Whether a line of Swift builds a defaults suite directly. A COMMENT is not a call, and LaunchReplay
    // once had to reword a comment to get past a scan that could not tell them apart (#3767).
    static func buildsARawSuite(_ line: String) -> Bool {
        let code = line.components(separatedBy: "//").first ?? line
        return code.contains("UserDefaults(suiteName:")
    }

    @Test("every defaults suite a test builds comes from ScratchDefaults")
    func everyDefaultsSuiteComesFromTheHelper() throws {
        let files = Self.testSourceFiles()
        #expect(files.count > 100, "the walk found \(files.count) test files, which is not the suite")

        var offenders: [String] = []
        var examined = 0
        for file in files {
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                if line.contains("ScratchDefaults.make(") { examined += 1 }
                if Self.defaultsSuiteExempt[file.name] == nil, Self.buildsARawSuite(line) {
                    offenders.append("\(file.name):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // Zero subjects is UNMEASURED, never clean: if the helper were renamed this would report a tidy
        // tree while examining nothing (L98).
        #expect(examined > 30,
                "found \(examined) ScratchDefaults.make call sites, which is too few to be measuring the tree")
        #expect(offenders.isEmpty, """
            A test builds a defaults suite directly. Every one is a real file in ~/Library/Preferences, and \
            nothing deletes it (#3774):
            \(offenders.joined(separator: "\n"))
            Use ScratchDefaults.make("<label>"), which names it uniquely and removes it at process exit.
            """)
    }

    // The control for the rule above: a guard that reports no offenders and a guard whose pattern matches
    // nothing look identical (L70).
    @Test("the defaults rule still recognises a raw suite, and not a comment about one")
    func theDefaultsRuleStillWorks() {
        #expect(Self.buildsARawSuite("    let d = UserDefaults(suiteName: \"x-\\(UUID().uuidString)\")!"),
                "the rule did not flag a raw suite, even one with a UUID in its name")
        #expect(!Self.buildsARawSuite("    // never build a UserDefaults(suiteName: here"),
                "the rule flagged a comment")
        #expect(!Self.buildsARawSuite("    let d = ScratchDefaults.make(\"x\")"),
                "the rule flagged the helper")
    }

    // And every exemption from THAT rule is still needed, on the same terms as the ones above: an
    // exemption for a file that no longer builds a defaults suite would silently cover a future one.
    @Test("every defaults-suite exemption is still needed")
    func defaultsSuiteExemptionsAreStillUsed() {
        for (name, reason) in Self.defaultsSuiteExempt where name != "TestsCannotReachSharedStateTests.swift" {
            guard let file = Self.testSourceFiles().first(where: { $0.name == name }) else {
                Issue.record("\(name) is exempted and does not exist")
                continue
            }
            #expect(file.text.contains("UserDefaults(suiteName:"),
                    "\(name) no longer builds a defaults suite, so drop its exemption (\(reason))")
        }
    }

    // #3272: and a test does not append a FIXED name to the temp directory.
    //
    // That is the shape the one offender had: `(try? sandboxes.makeFile(...)) ?? ` a fallback of
    // `URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Overture.store")`, reached
    // exactly when the sandbox could not be made, so it turned a failure into a path every test in that
    // suite would share (L93, L98).
    //
    // NARROW on purpose, and measured before it was written rather than after (L147). The loose version
    // tried first asked whether a UUID appeared anywhere near a temp-directory line, and it accepted the
    // offender back: the class holds `private let sandboxes = TemporarySandboxes()` twenty lines up, so
    // the window said "scoped" about a line that was not. What is asked instead is exactly the defect:
    // a LITERAL component appended directly to the temp directory. Measured 2026-08-31 over all 965 test
    // sources, that shape has ONE instance, named below.
    //
    // Distinct from `scripts/check-temp-dir-leaks.sh` (#3065), which asks whether a suite REMOVES what it
    // made. A perfectly cleaned-up fixed path is still one two tests can hold at once.
    private static let temporaryDirectoryExempt: [String: String] = [
        "HandoffOutOfBoundsAgreementTests.swift":
            "names a directory to ask a PURE function about it (is this the live handoff folder), and "
            + "never writes to it. The name has to be fixed for the case to be readable.",
        "TestsCannotReachSharedStateTests.swift":
            "this file, which has to name the shape in order to forbid it.",
    ]

    @Test("no test appends a fixed name to the temp directory")
    func noTestBuildsAFixedTemporaryPath() throws {
        let files = Self.testSourceFiles()
        #expect(files.count > 100, "the walk found \(files.count) test files, which is not the suite")

        var offenders: [String] = []
        var examined = 0
        for file in files where Self.temporaryDirectoryExempt[file.name] == nil {
            for (line, code) in SwiftSource.scannableLines(in: file.text, skipping: []) {
                guard code.contains("NSTemporaryDirectory()") || code.contains("temporaryDirectory") else { continue }
                examined += 1
                guard let literal = Self.literalComponent(in: code) else { continue }
                offenders.append("\(file.name):\(line)  appends the fixed name \"\(literal)\"")
            }
        }

        // Zero subjects is UNMEASURED, never clean: a renamed API would empty the corpus and this would
        // report a perfectly scoped tree while examining nothing (L98).
        #expect(examined > 50,
                "examined \(examined) temp-directory call sites, which is too few to be measuring the tree")
        #expect(offenders.isEmpty, """
            A test appends a fixed name to the temp directory, so every other test spelling that name, \
            and anything else on this Mac using it, shares the same file (#3272):
            \(offenders.joined(separator: "\n"))
            Take it from TemporarySandboxes, or scope it with a UUID.
            """)
    }

    /// The component appended on this line when it is a plain literal, or nil. A component carrying an
    /// interpolation is scoped by whatever it interpolates and is not this defect.
    static func literalComponent(in code: String) -> String? {
        var rest = Substring(code)
        while let call = rest.range(of: "appendingPathComponent(") {
            let after = rest[call.upperBound...]
            guard let open = after.firstIndex(of: "\"") else { return nil }
            let body = after[after.index(after: open)...]
            guard let close = body.firstIndex(of: "\"") else { return nil }
            let literal = String(body[..<close])
            // Anything before the quote other than whitespace means the argument is not a literal at all.
            if after[..<open].allSatisfy({ $0 == " " }) && !literal.contains("\\(") {
                return literal
            }
            rest = body[close...]
        }
        return nil
    }

    // The control for that rule, so a guard that matches nothing reads as a failure rather than as a
    // clean tree (L70).
    @Test("the fixed-temp-path rule still recognises one")
    func theTemporaryPathRuleStillWorks() {
        #expect(Self.literalComponent(
            in: "URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(\"Overture.store\")")
            == "Overture.store")
        #expect(Self.literalComponent(
            in: "FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)") == nil)
        #expect(Self.literalComponent(
            in: "dir.appendingPathComponent(\"m-\\(UUID().uuidString)\")") == nil)
    }

    // And every exemption from it is still needed, on the same terms as the two lists above.
    @Test("every fixed-temp-path exemption is still needed")
    func temporaryPathExemptionsAreStillUsed() {
        for (name, reason) in Self.temporaryDirectoryExempt where name != "TestsCannotReachSharedStateTests.swift" {
            guard let file = Self.testSourceFiles().first(where: { $0.name == name }) else {
                Issue.record("\(name) is exempted and does not exist")
                continue
            }
            let stillHasOne = SwiftSource.scannableLines(in: file.text, skipping: []).contains { _, code in
                (code.contains("NSTemporaryDirectory()") || code.contains("temporaryDirectory"))
                    && Self.literalComponent(in: code) != nil
            }
            #expect(stillHasOne, "\(name) no longer appends a fixed temp name, so drop its exemption (\(reason))")
        }
    }

    // The control. A guard reporting no offenders is indistinguishable from one whose patterns match
    // nothing, and matching nothing is what a rename produces (L70).
    @Test("the scan still recognises a real reach")
    func theScanStillWorks() {
        let live = """
            @Test func writesSomewhereReal() {
                let d = UserDefaults.standard
                let home = NSHomeDirectory()
            }
            """
        let hits = SwiftSource.scannableLines(in: live, skipping: []).flatMap { _, code in
            Self.forbidden.filter { code.contains($0.api) }
        }
        #expect(hits.count == 2, "the scan found \(hits.count) of the 2 reaches in its own fixture")
    }
}
