import Testing
import Foundation
import SwiftData
@testable import Overture

// #1125: the end-of-scout popup's couldn't-be-checked row was reading its address off the run-time
// SourceResult snapshot, so a URL Dan corrected with "Fix the address" saved to the live WatchedSource
// but the row kept showing the OLD address, and a real save read as a no-op. The row now reads the live
// source when one matches; this pins that choice so the snapshot can never win over a saved correction
// again.
@MainActor
@Suite("Scout summary row address display (#1125)")
struct ScoutSummaryRowTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func failed(_ id: String, url: String?) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: "The Cell Theatre",
                                  state: .failed(.verdict(.noDatedContent)), listingsURL: url)
    }

    // The bug, end to end: a source whose URL Dan corrects, and the run-time snapshot still carrying the
    // OLD URL. After the real editURL save, the address the row chooses to display must be the URL just
    // saved, not the stale snapshot.
    @Test func aSavedCorrectionShowsTheNewAddressNotTheSnapshot() throws {
        let ctx = try context()
        let oldURL = "http://www.thecelltheatre.org/events"
        let newURL = "https://www.thecelltheatre.org/box-office"
        let source = WatchedSource(sourceId: "cell", orgName: "The Cell Theatre",
                                   listingsURL: oldURL, kind: .html)
        ctx.insert(source)
        try ctx.save()

        // The snapshot the popup was handed when the scout ran, still on the old address.
        let snapshot = failed("cell", url: oldURL)

        // Dan fixes the address; the live source is updated and persisted.
        #expect(WatchlistEditing.editURL(source, to: newURL, in: ctx) == .saved(sourceId: "cell"))

        #expect(ScoutSummaryRow.displayURL(result: snapshot, source: source) == newURL)
    }

    // With no matching live row (a result that has no watchlist source of its own), the snapshot is the
    // only address there is, so it is what shows.
    @Test func withoutAMatchingSourceTheSnapshotIsShown() throws {
        let snapshot = failed("orphan", url: "https://orphan.example/calendar")
        #expect(ScoutSummaryRow.displayURL(result: snapshot, source: nil)
                == "https://orphan.example/calendar")
    }

    // A result with no page and no live URL shows nothing (Carnegie's native feed has no page to correct).
    @Test func aResultWithNoAddressShowsNothing() throws {
        let snapshot = failed("carnegie", url: nil)
        #expect(ScoutSummaryRow.displayURL(result: snapshot, source: nil) == nil)
    }
}
