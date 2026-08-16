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
         "UserDefaults(suiteName: \"<something>-\\(UUID().uuidString)\"), which every test here already does"),
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
