import Testing
import Foundation

// #4534: a hosted suite that reads a counter of a hosted view's work never ends a hosted view with a bare
// `close()`.
//
// WHY. `window.close()` alone leaves the hosted view in the SwiftUI graph: the window is not released
// (every harness sets `isReleasedWhenClosed = false`, #3480), the hosting view is still its content, and
// the view beneath it keeps its state, its queries and its render memo. `QueueRenderCounter` counts per
// SURFACE for the whole process, so a view an earlier test closed and left can be evaluated during a
// later test and charged to it. That is what CI run 37231800659 carried into the roster reload test
// (#4516). `HostedPassCounting.unmountAndClose` takes the view out of the graph first.
//
// WHICH SUITES, derived from the code rather than listed (L96): every file under OvertureHostedTests
// whose CODE, with comments and string literals stripped, names one of the COUNTERS below. A suite that
// starts counting tomorrow is covered without anybody remembering this guard. `HostedPassCounting.swift`
// is exempt by name, because it is where the one close each helper performs lives.
//
// #4571: WHICH COUNTERS, derived from the app's code too. This read `QueueRenderCounter` alone until then,
// so the hosted suites counting through `QueueRenderPass.WorkTally` closed their windows bare and nothing
// said so. A task local tally is charged by a leftover view only when that view is evaluated inside a
// later test's measurement, which is rarer than the process wide case and not impossible.
//
// THE ONE SANCTIONED EXCEPTION is `HostedPassCounting.closeLeavingMounted(_:because:)`, which carries its
// reason at the call: a positive control proving a closed window is still evaluated, and a RootView host
// whose teardown crashed the shared host. It does not match the shape refused below, by design, so a
// reviewer reads the reason rather than a bare call.
@Suite("A counting suite unmounts every hosted view before closing its window (#4534)")
struct CountingSuitesUnmountBeforeClosingTests {

    static let helper = "HostedPassCounting.swift"

    // Each line's CODE: comments stripped by the lexer, and string literals emptied here, because the
    // lexer puts a literal back into its line and a sentence quoting a call is not one. Nothing skipped,
    // so a test inside a DEBUG block is read too.
    static func codeLines(_ text: String) -> [(line: Int, code: String)] {
        SwiftSource.scannableLines(in: text, skipping: []).map { entry in
            (entry.line, entry.code.replacingOccurrences(of: ##"#?"(?:[^"\\]|\\.)*"#?"##, with: "\"\"",
                                                          options: .regularExpression))
        }
    }

    // #4571: THE COUNTERS, found in the app's own source by the declaration that makes each one a counter,
    // so a third added tomorrow is covered without anybody remembering this guard (L96). Two shapes:
    //
    //   PROCESS WIDE  a type holding a `nonisolated(unsafe)` static COUNT, an `Int` or a dictionary of
    //                 them: a leftover view evaluated during any later test is charged to it.
    //   TASK LOCAL    a type declaring `@TaskLocal static var current` of its own type: a leftover view is
    //                 charged when it is evaluated inside a later test's measurement.
    //
    // The owner of a process wide count is the innermost type declared at a smaller indent above it.
    static func counters(in files: [(name: String, text: String)]) -> Set<String> {
        var found: Set<String> = []
        for file in files {
            var owners: [(indent: Int, name: String)] = []
            for (_, code) in codeLines(file.text) {
                let indent = code.prefix { $0 == " " }.count
                if let declared = firstCapture(typeDeclaration, in: code) {
                    owners.removeAll { $0.indent >= indent }
                    owners.append((indent, declared))
                }
                if let tally = firstCapture(taskLocalTally, in: code) {
                    found.insert(tally)
                } else if code.contains("nonisolated(unsafe)"),
                          code.range(of: staticCount, options: .regularExpression) != nil,
                          let owner = owners.last(where: { $0.indent < indent }) {
                    found.insert(owner.name)
                }
            }
        }
        return found
    }

    static let typeDeclaration = #"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:enum|struct|class|actor|extension)\s+([A-Za-z_][\w.]*)"#
    static let taskLocalTally = #"@TaskLocal\s+static\s+var\s+current\s*:\s*(\w+)\?"#
    static let staticCount = #"static\s+var\s+\w+\s*(?::\s*(?:Int|\[String:\s*Int\])\s*=|=\s*(?:0|\[:\])\s*$)"#

    static func firstCapture(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    static var appCounters: Set<String> {
        counters(in: AppSourceWalk.files(under: RepoRoot.app).map { ($0.name, $0.text) })
    }

    // A counter named as a WHOLE WORD, so `WorkTallyCostTests` or a `MarkerReadTallyish` is not a read of one.
    static func isCountingSuite(_ text: String, counters: Set<String>) -> Bool {
        let patterns = counters.map { #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"# }
        return codeLines(text).contains { line in
            patterns.contains { line.code.range(of: $0, options: .regularExpression) != nil }
        }
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
        let counters = Self.appCounters
        // THE POSITIVE CONTROL FOR THE COUNTERS. The two the hosted suites read today must be found, or the
        // derivation matches nothing and every suite below reads as not counting (L98).
        // The process wide counter's name assembled rather than written, because this guard only READS for
        // it: `SharedStateWiringTests` matches the whole word in a file's code, string literals included,
        // and demands the counter's lock of any suite that names it.
        #expect(counters.isSuperset(of: [["Queue", "RenderCounter"].joined(), "WorkTally"]), Comment(rawValue:
            "the counters derived from the app's source were \(counters.sorted()), missing one the hosted "
            + "suites are known to read, so the set of counting suites below is measured by a reader that "
            + "matches less than it should (#4571)"))
        let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("OvertureHostedTests"),
                                        floor: 30)
        let counting = files.filter { $0.name != Self.helper && Self.isCountingSuite($0.text, counters: counters) }
        // THE POSITIVE CONTROL FOR THE SUITES. One suite per kind of counter, so a derivation that lost
        // either kind is seen here rather than as a quiet pass (L98).
        for known in ["OneChangeDerivesTheQueueOnceTests.swift", "FeltWaitCostTests.swift"] {
            #expect(counting.contains { $0.name == known }, Comment(rawValue:
                "\(known) was not read as a counting suite, so the derivation of the set this guard checks "
                + "matched less than it should; found \(counting.map(\.name).sorted())"))
        }
        let offenders = counting.flatMap { file in
            Self.bareCloses(in: file.text).map { "\(file.name):\($0)" }
        }.sorted()
        #expect(offenders.isEmpty, Comment(rawValue:
            "these hosted suites read a counter of a hosted view's work (\(counters.sorted().joined(separator: ", "))) "
            + "and close a window without unmounting its view: \(offenders.joined(separator: ", ")). A closed "
            + "window's view stays in the SwiftUI graph, so a later test can be charged for its passes "
            + "(#4516, #4571). Use HostedPassCounting.unmountAndClose, or closeLeavingMounted(_:because:) "
            + "with the reason."))
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
            let n = SomeCounter.derivations
            """
        #expect(Self.bareCloses(in: fixture) == [3, 4],
                Comment(rawValue: "the scan read lines \(Self.bareCloses(in: fixture))"))
        #expect(Self.isCountingSuite(fixture, counters: ["SomeCounter"]))
        #expect(!Self.isCountingSuite("// SomeCounter in a comment\nlet s = \"SomeCounter\"",
                                      counters: ["SomeCounter"]))
        // A longer identifier that merely CONTAINS a counter's name is not a read of it.
        #expect(!Self.isCountingSuite("let n = SomeCounterCostTests.self", counters: ["SomeCounter"]))
        #expect(Self.isCountingSuite("let n = Outer.SomeCounter.current", counters: ["SomeCounter"]))
    }

    // #4571: the counter derivation over a fixture, both shapes and the near misses each must not take.
    @Test func theCountersAreFoundByTheDeclarationsThatMakeThemCounters() {
        let fixture = """
            enum ProcessCounter {
                nonisolated(unsafe) private(set) static var passes = 0
                nonisolated(unsafe) private static var bySurface: [String: Int] = [:]
            }
            enum Outer {
                final class NestedTally: @unchecked Sendable {
                    @TaskLocal static var current: NestedTally?
                }
            }
            final class AppHolder {
                nonisolated(unsafe) static var sharedContainer: ModelContainer?
                // nonisolated(unsafe) static var commented = 0
            }
            enum Flags {
                @TaskLocal static var asOracle = false
            }
            """
        #expect(Self.counters(in: [("Fixture.swift", fixture)]) == ["ProcessCounter", "NestedTally"],
                Comment(rawValue: "derived \(Self.counters(in: [("Fixture.swift", fixture)]).sorted())"))
    }
}
