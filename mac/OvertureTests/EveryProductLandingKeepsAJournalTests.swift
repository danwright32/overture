import Testing
import Foundation

// #4335 (A6): every landing the APP makes keeps a journal.
//
// The journal folder is a parameter of each landing, resolved to the handoff folder once at the product call
// sites, so every test can pass its own sandbox (L433, L463) and a test whose subject is not the journal can
// pass none. That makes "no journal" the parameter's default, which is the shape L168 warns about: a product
// caller that forgets it lands with nothing to recover from and nothing goes red. This is what goes red. It
// is DERIVED from the code: every call of a landing entry point in the app must name `journals:` in its own
// argument list.
@Suite("Every landing the app makes keeps a journal (#4335)")
struct EveryProductLandingKeepsAJournalTests {
    // The landing entry points, by the code they are called as. `land(` inside the declaring file is
    // `offerPending`'s own call, which lands every kept copy.
    static let calls = ["ScoutService.runScout(", "ScoutExtractLanding.land(", "ScoutExtractLanding.offerPending(",
                        "ScoutExtractIngest.ingest(", "await land("]

    // Each call of an entry point whose argument list does not name `journals:`, as "file:line call".
    static func findings(in text: String, file: String) -> [String] {
        let scan = SwiftSource.tokenize(text)
        let last = scan.codeLines.keys.max() ?? 0
        guard last > 0 else { return [] }
        let lines = (1...last).map { scan.codeLines[$0] ?? "" }
        let code = lines.joined(separator: "\n")
        var out: [String] = []
        for call in calls {
            var from = code.startIndex
            while let found = code.range(of: call, range: from..<code.endIndex) {
                from = found.upperBound
                // The call's OWN arguments: what sits directly inside its parentheses, not inside a call nested
                // in one of them.
                var depth = 1
                var end = found.upperBound
                var arguments = ""
                while end < code.endIndex, depth > 0 {
                    let ch = code[end]
                    if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                    if depth == 1, ch != "(", ch != ")" { arguments.append(ch) }
                    end = code.index(after: end)
                }
                if !arguments.contains("journals:") {
                    let line = code[code.startIndex..<found.lowerBound].filter { $0 == "\n" }.count + 1
                    out.append("\(file):\(line) \(call)")
                }
            }
        }
        return out
    }

    @Test func everyLandingTheAppMakesNamesItsJournalFolder() {
        let files = AppSourceWalk.appFiles()
        let found = files.flatMap { Self.findings(in: $0.text, file: $0.name) }
        #expect(found.isEmpty, Comment(rawValue: "landings the app makes with no journal: \(found)"))
        // And the scan found the calls it exists for, or it is passing over nothing (L98).
        let calling = files.filter { file in Self.calls.contains { file.text.contains($0) } }.map(\.name)
        #expect(Set(calling).isSuperset(of: ["RootView.swift", "ScoutExtractLanding.swift"]),
                Comment(rawValue: "the landing calls were not found where they live: \(calling)"))
    }

    @Test func theScanFindsACallWithNoJournalAndIgnoresCommentsAndStrings() {
        #expect(Self.findings(in: "let o = try await ScoutService.runScout(\n    into: c, now: n)", file: "A.swift")
                    == ["A.swift:1 ScoutService.runScout("])
        #expect(Self.findings(in: "let o = await ScoutExtractLanding.land(d, r, f(x), journals: .live, into: c)",
                              file: "A.swift").isEmpty)
        // A `journals:` belonging to a call NESTED inside another argument does not count for the outer one.
        #expect(!Self.findings(in: "ScoutExtractIngest.ingest(r, x: g(journals: j), into: c)", file: "A.swift").isEmpty)
        #expect(Self.findings(in: "// ScoutService.runScout(into: c)\nlet s = \"ScoutExtractLanding.land(\"",
                              file: "A.swift").isEmpty)
    }
}
