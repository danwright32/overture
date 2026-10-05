import Testing
import Foundation

// #4516: the queue and the Sources sheet take their clock from whoever builds them, and the app hands
// neither of them one.
//
// WHY THE SEAM EXISTS. Both surfaces derive the whole store through a `ScopeMemo`, which refuses an
// answer older than `ScopeMemo.staleAfterSeconds` by the clock the surface hands it. In the app that is
// the wall clock, and it is right: the room rule and the queue's stages read the exact instant, so the
// window is what bounds how stale a served answer's clock can be. But a hosted test that counts
// derivations was measuring the runner with it: on a slow GitHub runner the next evaluation landed past
// the window and derived again, so `aRosterReloadThatChangesNoVerdictDerivesNothing` and two siblings in
// `OneChangeDerivesTheQueueOnceTests` failed at random. Those tests now hand a frozen clock in.
//
// WHY THIS GUARD. A view given its clock by a seam is proved by the tests that supply it, never by the
// app not doing so (L718). Any call site in the app that handed either surface a clock would freeze that
// window in production, and every hosted test would stay green. So the call sites are read from the
// app's own source, every one of them rather than a list, and none may pass `clock:`; and each surface's
// default is asserted to be the wall clock, which is what a call site passing nothing gets.
@Suite("The app hands neither the queue nor the Sources sheet a clock (#4516)")
struct TheAppHandsNoSurfaceAClockTests {

    static let surfaces = ["QueueView", "SourcesView"]

    // Every argument list the code passes to `<name>(`, balanced by parentheses, with comments stripped
    // first so a sentence about a call is not one. A word boundary in front, so `XQueueView(` is not read
    // as a call of `QueueView`.
    static func callArguments(of name: String, in source: String) -> [String] {
        let code = SourceGuardHelper.normalizedCode(source)
        guard let regex = try? NSRegularExpression(pattern: #"\b\#(name)\("#) else { return [] }
        var found: [String] = []
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range, in: code) else { continue }
            var index = code.index(before: range.upperBound)
            var depth = 0
            let open = index
            while index < code.endIndex {
                if code[index] == "(" { depth += 1 }
                if code[index] == ")" {
                    depth -= 1
                    if depth == 0 { found.append(String(code[open...index])); break }
                }
                index = code.index(after: index)
            }
        }
        return found
    }

    @Test func noCallSiteInTheAppHandsEitherSurfaceAClock() {
        let files = AppSourceWalk.appFiles()
        for surface in Self.surfaces {
            var calls: [(file: String, arguments: String)] = []
            for file in files {
                for arguments in Self.callArguments(of: surface, in: file.text) {
                    calls.append((file.name, arguments))
                }
            }
            // THE POSITIVE CONTROL. RootView builds both, so a scan that found no call at all matched
            // nothing and the empty list below would read as the cleanest possible app (L98).
            #expect(calls.contains { $0.file == "RootView.swift" }, Comment(rawValue:
                "no call of \(surface)( was found in RootView.swift, so this scan measured nothing; "
                + "found \(calls.map(\.file))"))
            let clocked = calls.filter { $0.arguments.contains("clock:") }
            #expect(clocked.isEmpty, Comment(rawValue:
                "the app hands \(surface) a clock in \(clocked.map(\.file).joined(separator: ", ")). That "
                + "replaces the wall clock its render memo's window is measured by, so a served answer "
                + "could be judged against an instant that never moves. The seam is for tests (L718)."))
        }
    }

    @Test func eachSurfaceDefaultsToTheWallClock() {
        for (surface, path) in [("QueueView", "Overture/UI/QueueView.swift"),
                                ("SourcesView", "Overture/UI/SourcesView.swift")] {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "\(path) could not be read, so nothing below was measured")
            #expect(SourceGuardHelper.containsCode("var clock: () -> Date = Date.init", in: source),
                    Comment(rawValue: "\(surface)'s clock no longer defaults to the wall clock, so a call "
                        + "site passing nothing no longer gets the clock the app has always used"))
        }
    }

    // The scanner itself, over a fixture, so a pattern that stopped matching cannot pass the guard above
    // by finding nothing to object to.
    @Test func theScanReadsEveryCallAndNothingElse() {
        let fixture = """
            // SourcesView(prospects: x, clock: { y })
            let a = SourcesView(prospects: rows)
            let b = SourcesView(prospects: rows.filter { $0.isLive }, clock: { pinned })
            let c = OtherSourcesView(prospects: rows, clock: c)
            """
        let found = Self.callArguments(of: "SourcesView", in: fixture)
        #expect(found == ["(prospects: rows)", "(prospects: rows.filter { $0.isLive }, clock: { pinned })"],
                Comment(rawValue: "the scan read \(found)"))
    }
}
