import Foundation
import SwiftData

// #3874: the in-memory container every hosted test builds, in ONE place, with AUTOSAVE OFF.
//
// WHY AUTOSAVE IS THE POINT, and it is not tidiness. `ModelContainer.mainContext` autosaves by
// default, and `.modelContainer(c)` hands SwiftUI exactly that context, so every hosted test armed a
// run loop timer it never asked for. The crash in #3874 is that timer firing into a
// `_SwiftData_SwiftUI` observer while XCTest is BETWEEN tests: a SwiftData trap, on a stack holding no
// Overture test code at all, blamed on whichever test happened to be starting.
//
// MEASURED, not reasoned. Running the hosted target with `-test-iterations 10`:
//
//   autosave ON  (as every suite had it)   3, 5 and 3 restarts per run on one Mac, 2 in a partial run here
//   autosave OFF (this helper)             0 restarts in 10 iterations, and no new crash report at all
//
// The tests lose nothing by it: every one of them saves explicitly, so the timer only ever duplicated
// work they had already done, and it did that while the container it belonged to was being torn down.
//
// WHAT WAS WRONG BEFORE THIS, recorded because the issue said something else. #3874 was filed claiming
// hosted tests LEAK their view trees and that a teardown would fix the crash. They do not:
// `HostedWindowsAreReleasedTests` holds weak references to the hosting view, the model context and the
// model container across a hosted test, including the seed, save, rebuild and second save the crashing
// suite performs, and all three are released by `window.close()` alone. The teardown that issue
// proposed would have fixed nothing (L3: built is not wired, and an inferred cause is not a cause).
//
// ONE PLACE, so the next suite cannot quietly go back to a container that autosaves. A helper that has
// to be remembered at twenty call sites is a rule living in prose (L27, L613).
enum TestModelContainer {
    /// An in-memory container over `types`, with its main context's autosave switched off.
    @MainActor
    static func inMemory(_ types: [any PersistentModel.Type]) throws -> ModelContainer {
        let made = try ModelContainer(for: Schema(types),
                                      configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        made.mainContext.autosaveEnabled = false
        return made
    }
}
