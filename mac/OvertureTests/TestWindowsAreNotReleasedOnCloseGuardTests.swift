import Testing
import Foundation

// #3480: a test that builds an `NSWindow` and closes it must set `isReleasedWhenClosed = false` first.
//
// AppKit's default is TRUE, so `close()` RELEASES the window while the test still holds a reference to
// it. Alone that is often survivable; run beside the other hosted suites it crashed the SHARED app host,
// which restarts the test process and truncates the whole hosted target.
//
// Measured 2026-09-03 while adding RealScrollInvalidationTests: the hosted target ran 304 tests in 50
// suites green without it, and 111 tests plus a process restart with it. The crash NAMES NO TEST
// (`Crash: Overture at <external symbol>`), so it reads as an unrelated flake rather than as something
// one suite did, and the run-shape readout correctly refuses to state a suite size for it (#2821).
//
// That is the #1967 failure with a new cause: one fault in the shared host costing every hosted test at
// once, and the hosted tests are the only ones that render a real SwiftUI view.
//
// The app already knows this rule. `AppDelegate.swift:214` sets the flag on the one window it makes. The
// test targets are where the convention was not being followed, which is why this guard reads them.
//
// A SOURCE guard, not a behavioural one, and deliberately: the failure is a use after free in a shared
// process, so a test that provoked it would take the run down rather than report a red, which is the
// thing being prevented.
@Suite("A test window is never released on close (#3480)")
struct TestWindowsAreNotReleasedOnCloseGuardTests {
    // Derived from the tree rather than from a list, so a THIRD window arriving in a new file is covered
    // without anybody remembering this guard exists (L96). Through AppSourceWalk, which REFUSES on an
    // empty walk, so a wrong path cannot make this pass over nothing (#2311, L98).
    //
    // Every root this repo's OWN Swift lives in, named rather than walked from `mac/`, and that is not
    // tidiness. Walking `mac/` collects `mac/build/SourcePackages/checkouts/`, where SwiftPM puts the
    // ViewInspector checkout, and the first run of this guard duly reported two of ITS files as
    // offenders: `ViewHosting.swift` and `PopoverContentTests.swift`. Neither is ours to edit, and a
    // guard naming a dependency is a guard that gets switched off (L234).
    //
    // The app is included on purpose. The rule is not a test rule: `AppDelegate.swift:214` already
    // follows it, and a window built anywhere that closes while something still holds it has the fault.
    private static let roots = ["Overture", "OvertureTests", "OvertureHostedTests", "TestSupport"]

    // Low enough that an ordinary deletion cannot trip it, high enough that a wrong path does (#2311).
    private static let floor = 100

    @Test func everyFileThatBuildsAWindowKeepsItAliveOnClose() {
        let files = Self.roots.flatMap {
            AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent($0), floor: 0)
        }
        #expect(files.count >= Self.floor,
                Comment(rawValue: "walked \(files.count) Swift files across \(Self.roots.count) roots, "
                        + "fewer than the \(Self.floor) this needs to be checking anything at all. That "
                        + "is a broken path, not a clean tree (#2311)."))

        var builders: [String] = []
        var missing: [String] = []
        for file in files {
            let code = SwiftSource.scannableLines(in: file.text).map(\.code).joined(separator: "\n")
            guard code.contains("NSWindow(") else { continue }
            builders.append(file.name)
            if !code.contains("isReleasedWhenClosed = false") { missing.append(file.name) }
        }

        // Cannot pass vacuously: with nothing building a window this has measured nothing, and that must
        // not read as everything being fine (L98).
        #expect(!builders.isEmpty,
                "no file under mac/ builds an NSWindow, so this guard checked nothing at all")
        #expect(missing.isEmpty,
                Comment(rawValue: "these files build an NSWindow and never set "
                        + "`isReleasedWhenClosed = false`, so closing one releases a window something "
                        + "still holds, which crashed the shared app host and truncated the whole hosted "
                        + "target: " + missing.joined(separator: ", ")))
    }
}
