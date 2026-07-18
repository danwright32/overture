import Testing
import Foundation
@testable import Overture

// #1054: cancelling a scout mid-read used to silently import whatever the reader had written before it
// stopped. These pin the rule (ask, do not auto-decide), the honest count shown, and the failure path
// that matters most: a discard must actually drop the partial file so a later reattach cannot re-import it.
@Suite("Cancelling a scout mid-read asks before keeping its partial shows (#1054)")
struct CancelledReadDispositionTests {

    private func event(title: String = "Recital", venue: String?) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: nil, venue: venue,
                          performanceDate: "2026-09-01", sourceUrl: nil, location: nil)
    }

    private func results(_ events: [ScoutExtractEvent]) -> ScoutExtractResults {
        ScoutExtractResults(version: 3, generatedAt: "2026-07-18T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: "s1", verdict: .upcomingListings,
                                                         events: events, note: nil)])
    }

    @Test func aRunThatFinishedNormallyIsIngestedNotPrompted() {
        #expect(CancelledReadDisposition.decide(cancelled: false, readCount: 5) == .ingest)
    }

    @Test func aCancelledRunWithPartialShowsPromptsWithTheCount() {
        #expect(CancelledReadDisposition.decide(cancelled: true, readCount: 3)
                == .promptKeepOrDiscard(readCount: 3))
    }

    @Test func aCancelledRunThatReadNothingUsableClosesQuietly() {
        #expect(CancelledReadDisposition.decide(cancelled: true, readCount: 0) == .discardSilently)
    }

    @Test func theCountIsOnlyShowsThatWouldSurviveTheGuard() {
        // Two real venues, one blank venue (rejected as .noVenue), one numeric placeholder (rejected).
        let r = results([
            event(title: "Recital", venue: "Carnegie Hall"),
            event(title: "Gala", venue: "Merkin Hall"),
            event(title: "Mystery", venue: ""),
            event(title: "Bargemusic", venue: "3"),
        ])
        #expect(r.usableEventCount == 2)
    }

    @Test func discardRemovesTheResultsFileSoAReattachCannotReimportIt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-1054-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: tmp)
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        ScoutExtractResultsDecoder.discard(at: tmp)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test func theCopyNamesTheCountAndReadsRightForOneShow() {
        #expect(CancelledReadCopy.keepLabel(readCount: 1) == "Keep 1 show")
        #expect(CancelledReadCopy.keepLabel(readCount: 3) == "Keep 3 shows")
        #expect(CancelledReadCopy.message(readCount: 1) == "Read 1 show before you cancelled.")
        #expect(CancelledReadCopy.message(readCount: 7) == "Read 7 shows before you cancelled.")
    }
}
