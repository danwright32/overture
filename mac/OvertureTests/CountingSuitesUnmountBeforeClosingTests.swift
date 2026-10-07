import Testing
import Foundation

// #4534: a hosted suite that reads the process wide `QueueRenderCounter` never ends a hosted view with a
// bare `close()`.
//
// WHY. `window.close()` alone leaves the hosted view in the SwiftUI graph: the window is not released
// (every harness sets `isReleasedWhenClosed = false`, #3480), the hosting view is still its content, and
// the view beneath it keeps its state, its queries and its render memo. `QueueRenderCounter` counts per
// SURFACE for the whole process, so a view an earlier test closed and left can be evaluated during a
// later test and charged to it. That is what CI run 37231800659 carried into the roster reload test
// (#4516). `HostedPassCounting.unmountAndClose` takes the view out of the graph first.
//
// WHICH SUITES, derived from the code rather than listed (L96): every file under OvertureHostedTests
// whose CODE, with comments and string literals stripped, names `QueueRenderCounter`. A suite that starts
// counting tomorrow is covered without anybody remembering this guard. `HostedPassCounting.swift` is
// exempt by name, because it is where the one close each helper performs lives.
//
// THE ONE SANCTIONED EXCEPTION is `HostedPassCounting.closeLeavingMounted(_:because:)`, which carries its
// reason at the call: a positive control proving a closed window is still evaluated, and a RootView host
// whose teardown crashed the shared host. It does not match the shape refused below, by design, so a
// reviewer reads the reason rather than a bare call.
@Suite("A counting suite unmounts every hosted view before closing its window (#4534)")
struct CountingSuitesUnmountBeforeClosingTests {

    static let helper = "HostedPassCounting.swift"

    // The counter's name, assembled rather than written, because this guard only READS for it and must not
    // be read as touching it: `SharedStateWiringTests` matches the whole word in a file's code, string
    // literals included, and demands the counter's lock of any suite that names it.
    static let counter = ["Queue", "RenderCounter"].joined()

    // Each line's CODE: comments stripped by the lexer, and string literals emptied here, because the
    // lexer puts a literal back into its line and a sentence quoting a call is not one. Nothing skipped,
    // so a test inside a DEBUG block is read too.
    static func codeLines(_ text: String) -> [(line: Int, code: String)] {
        SwiftSource.scannableLines(in: text, skipping: []).map { entry in
            (entry.line, entry.code.replacingOccurrences(of: ##"#?"(?:[^"\\]|\\.)*"#?"##, with: "\"\"",
                                                          options: .regularExpression))
        }
    }

    static func isCountingSuite(_ text: String) -> Bool {
        codeLines(text).contains { $0.code.contains(counter) }
    }

    // The lines of code calling `close()` with no arguments on anything. A `close(` WITH arguments is a
    // different function (the probes' own `Kind.close(cpu:wall:)`), and a comment or a string about a
    // close is not one.
    static func bareCloses(in text: String) -> [Int] {
        codeLines(text)
            .filter { $0.code.range(of: #"\.close\(\s*\)"#, options: .regularExpression) != nil }
            .map(\.line)
    }

    @Test func noCountingSuiteClosesAWindowWithoutUnmountingIt() {
        let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("OvertureHostedTests"),
                                        floor: 30)
        let counting = files.filter { $0.name != Self.helper && Self.isCountingSuite($0.text) }
        // THE POSITIVE CONTROL. The suite #4516 converted reads the counter, so a derivation that found it
        // not counting would mean the set below was measured by a reader that matches nothing (L98).
        #expect(counting.contains { $0.name == "OneChangeDerivesTheQueueOnceTests.swift" }, Comment(rawValue:
            "OneChangeDerivesTheQueueOnceTests.swift was not read as a counting suite, so the derivation of "
            + "the set this guard checks matched nothing; found \(counting.map(\.name).sorted())"))
        let offenders = counting.flatMap { file in
            Self.bareCloses(in: file.text).map { "\(file.name):\($0)" }
        }.sorted()
        #expect(offenders.isEmpty, Comment(rawValue:
            "these hosted suites read the process wide \(Self.counter) and close a window without "
            + "unmounting its view: \(offenders.joined(separator: ", ")). A closed window's view stays in "
            + "the SwiftUI graph, so a later test can be charged for its passes (#4516). Use "
            + "HostedPassCounting.unmountAndClose, or closeLeavingMounted(_:because:) with the reason."))
    }

    // The scanner over a fixture, so a pattern that stopped matching cannot pass the guard above by
    // finding nothing to object to.
    @Test func theScanFindsEachBareCloseAndNothingElse() {
        let fixture = """
            // window.close() in a sentence is not a call
            let note = "window.close()"
            window.close()
            w?.close()
            firstPre.close(cpu: cpus, wall: walls)
            HostedPassCounting.unmountAndClose(window)
            HostedPassCounting.closeLeavingMounted(window, because: "the positive control")
            let n = \(Self.counter).derivations
            """
        #expect(Self.bareCloses(in: fixture) == [3, 4],
                Comment(rawValue: "the scan read lines \(Self.bareCloses(in: fixture))"))
        #expect(Self.isCountingSuite(fixture))
        #expect(!Self.isCountingSuite("// \(Self.counter) in a comment\nlet s = \"\(Self.counter)\""))
    }
}
