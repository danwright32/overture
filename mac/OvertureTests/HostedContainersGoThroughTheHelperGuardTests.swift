import Testing
import Foundation

// #3874: a hosted suite must build its container through `TestModelContainer`, never directly.
//
// WHY. `ModelContainer.mainContext` autosaves by default, and `.modelContainer(c)` hands SwiftUI
// exactly that context, so a directly built container arms a run loop timer the test never asked for.
// That timer firing into a `_SwiftData_SwiftUI` observer between tests is what killed the test host:
// measured at 3, 5 and 3 restarts per `-test-iterations 10` run with autosave on, and 0 across 10
// iterations with it off.
//
// All 20 hosted suites were converted in one change. This is the other half of that change, because a
// helper that has to be REMEMBERED at every new call site is a rule living in prose, and the
// twenty-first suite is the one nobody reviews for it (L27, L613).
//
// SCOPED TO THE HOSTED TARGET on purpose. The unhosted suites build containers the same way and are
// not exposed: the crash needs SwiftUI's query machinery to be observing the context, and they render
// nothing. Widening this guard to them would refuse code that cannot have the fault, which is how a
// guard earns a reputation for noise.
@Suite("Hosted suites build containers through the helper (#3874)")
struct HostedContainersGoThroughTheHelperGuardTests {

    private static let roots = ["OvertureHostedTests"]

    // Low enough that an ordinary deletion cannot trip it, high enough that a wrong path does, on the
    // precedent `TestWindowsAreNotReleasedOnCloseGuardTests` set (#2311).
    private static let floor = 20

    @Test func noHostedSuiteBuildsAnInMemoryContainerItself() {
        let files = AppSourceWalk.files(underAll: Self.roots.map(RepoRoot.mac.appendingPathComponent),
                                        floor: Self.floor)

        var offenders: [String] = []
        for file in files {
            let code = SwiftSource.scannableLines(in: file.text).map(\.code).joined(separator: "\n")
            if code.contains("isStoredInMemoryOnly") { offenders.append(file.name) }
        }

        // Cannot pass vacuously: with no hosted sources walked this has measured nothing, and that must
        // not read as everything being fine (L98).
        #expect(files.count >= Self.floor,
                "the hosted test sources were not walked, so this guard checked nothing at all")
        #expect(offenders.isEmpty,
                Comment(rawValue: "these hosted suites build an in-memory ModelContainer directly, so "
                        + "their container's main context autosaves and arms the timer that kills the "
                        + "test host between tests (#3874). Use `TestModelContainer.inMemory(...)`: "
                        + offenders.joined(separator: ", ")))
    }

    // The helper must actually switch autosave off, or the rule above is satisfied by everyone calling
    // a helper that does nothing (L98, L159: the positive case proved in the same fixture).
    @Test func theHelperItselfSwitchesAutosaveOff() {
        let files = AppSourceWalk.files(underAll: ["TestSupport"].map(RepoRoot.mac.appendingPathComponent),
                                        floor: 5)
        let helper = files.first { $0.name == "TestModelContainer.swift" }
        let code = helper.map { SwiftSource.scannableLines(in: $0.text).map(\.code).joined(separator: "\n") }
        #expect(code?.contains("autosaveEnabled = false") == true, Comment(rawValue:
                "TestModelContainer no longer switches autosave off, so every hosted suite is back to "
                + "arming the timer that kills the test host (#3874)"))
    }
}
