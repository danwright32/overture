import Testing
import Foundation

// #2349: two branches open at once each regenerated the generated docs against their own base, so each
// recorded its own scanned-file count and the second went red on main purely because the number had
// drifted underneath it. Measured three times in one session on 2026-08-10 (402 to 404 to 406 to 407),
// each costing a full suite rerun, and each red reading as a copy change when no sentence had moved.
//
// The fix is not a friendlier message: it is that the docs no longer STATE a number that moves for
// reasons unrelated to what they are about. A red on either file is now always a real change.
@Suite("A generated doc only moves when its own subject does (#2349)")
struct GeneratedDocDriftTests {

    // Adding a Swift file that says nothing must not change the inventory by one character.
    @Test func addingASourceFileWithNoCopyDoesNotChangeTheInventory() throws {
        let built = try CopyInventory.build()
        let rendered = built.render()

        // The same inventory with one more file scanned and not one more sentence found, which is what
        // an unrelated merge does to a branch.
        var withAnotherFile = built
        withAnotherFile.filesScanned += 1

        #expect(withAnotherFile.render() == rendered,
                "the scanned-file count is in the rendered header again, so an unrelated merge will keep turning a branch red with nothing to fix")
    }

    @Test func addingASourceFileThatRendersNothingDoesNotChangeTheSurfacesReport() throws {
        let built = try CopySurfaces.build()
        let rendered = built.render()

        var withAnotherFile = built
        withAnotherFile.filesScanned += 1

        #expect(withAnotherFile.render() == rendered)
    }

    // And the other half, so the docs cannot go quiet: a REAL change still moves them.
    @Test func aSentenceStillMovesTheInventory() throws {
        let built = try CopyInventory.build()
        #expect(built.render().contains("\(built.occurrences.count) sentences"),
                "the sentence count is what the header states, and it moves only when the copy does")
    }

    // The count that left the file still exists and is still asserted, so what proves the scan ran is the
    // test rather than a printed number. Without this, dropping it from the header would have quietly
    // removed the only visible sign that the walk found anything (#1967's failure).
    @Test func theScanIsStillProvenToHaveRun() throws {
        #expect(try CopyInventory.build().filesScanned > 50)
        #expect(try CopySurfaces.build().filesScanned > 100)
    }
}
