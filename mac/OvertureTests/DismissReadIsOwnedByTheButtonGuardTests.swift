import Testing
import Foundation

// #3876: a sheet that uses `DoneButton` must not ALSO read `@Environment(\.dismiss)` itself.
//
// SwiftUI revises that value when the window's key status changes, in either direction, so a view
// holding it re-evaluates its whole body every time focus moves. Six sheets did, and each derives over
// the whole prospect table in its body, so a click away from Overture and back cost two whole-store
// passes per open sheet for no data change. Measured on `ArchiveView` at 120 rows of 120 per transition
// (`ExternalRebuildProbeTests`).
//
// `DoneButton` exists so the one view that actually needs the value is the button, whose body is a
// button. This guard is the other half of that change: converting six call sites and leaving nothing to
// stop the seventh is how a class fix decays back into an instance fix (L613, L30).
//
// A SOURCE guard rather than a behavioural one, and that is a limitation stated rather than hidden.
// `ArchiveView` is covered behaviourally by `becomingKeyCostsNoWholeStorePass`, which measures rows
// built on a key transition. The other five cannot be: `QueueRenderPass.WorkTally` counts queue rows,
// and `FollowUpsRenderPass` and `OutcomePatterns` increment none of its counters, so no instrument in
// this repository can currently see those surfaces rebuild. Until one can, the invariant that is
// checkable is the one the fix actually established: the read lives on the button.
//
// WHAT IT DELIBERATELY DOES NOT CATCH. A NEW view that reads `dismiss` at view level and derives
// something expensive, without using `DoneButton` at all, is invisible here, because this keys on the
// component. That is the broader rule and it is #3880. `SourcesView` is the standing example of why the
// two are different: it calls `dismiss()` at `:533` and `:1152` as well as in its Done button, so it
// genuinely needs the value at view level, does not use `DoneButton`, and is correctly not named by
// this guard. #3879 is what reaches it.
@Suite("The dismiss read is owned by DoneButton (#3876)")
struct DismissReadIsOwnedByTheButtonGuardTests {

    // Derived from the tree, never a list, so a seventh sheet adopting `DoneButton` is covered without
    // anybody remembering this guard exists (L96).
    private static let roots = ["Overture"]

    // Low enough that an ordinary deletion cannot trip it, high enough that a wrong path does, on the
    // precedent `TestWindowsAreNotReleasedOnCloseGuardTests` set (#2311).
    private static let floor = 100

    private func appFiles() -> [(name: String, code: String)] {
        AppSourceWalk.files(underAll: Self.roots.map(RepoRoot.mac.appendingPathComponent),
                            floor: Self.floor)
            .map { (name: $0.name,
                    code: SwiftSource.scannableLines(in: $0.text).map(\.code).joined(separator: "\n")) }
    }

    @Test func noViewUsingTheSharedButtonAlsoHoldsTheDismissRead() {
        let files = appFiles()

        var users: [String] = []
        var alsoReading: [String] = []
        for file in files {
            // The DECLARATION is not a use: `DoneButton.swift` is where the read is supposed to live.
            guard file.name != "DoneButton.swift", file.code.contains("DoneButton(") else { continue }
            users.append(file.name)
            if file.code.contains("@Environment(\\.dismiss)") { alsoReading.append(file.name) }
        }

        // Cannot pass vacuously: with nothing using the component this has measured nothing, and that
        // must not read as everything being fine (L98).
        #expect(!users.isEmpty,
                "no file under mac/Overture uses DoneButton, so this guard checked nothing at all")
        #expect(alsoReading.isEmpty,
                Comment(rawValue: "these views render DoneButton AND read `@Environment(\\.dismiss)` "
                        + "themselves, so their whole body still re-evaluates on every window focus "
                        + "change, which is the cost #3876 removed: "
                        + alsoReading.joined(separator: ", ")))
    }

    // The component must actually own the read, or the rule above is satisfied by everyone having
    // dropped it and nothing closing the sheet (L98, L159: the positive case proved in the same fixture).
    @Test func theSharedButtonItselfHoldsTheRead() {
        let button = appFiles().first { $0.name == "DoneButton.swift" }
        let code = try? #require(button?.code, "DoneButton.swift is not under mac/Overture any more")
        #expect(code?.contains("@Environment(\\.dismiss)") == true,
                "DoneButton no longer reads the dismiss value, so nothing closes the sheets using it")
        #expect(code?.contains("dismiss()") == true,
                "DoneButton no longer calls dismiss(), so its callers render a button that does nothing")
    }
}
