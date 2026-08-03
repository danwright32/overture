import Foundation
import SwiftData
import Testing

// #875, the wiring half. `SourceNote` being right is worth nothing if the note never reaches the row:
// a rule that is correct but never called is the exact failure this repo has already shipped (#887),
// and the note has been decoded and dropped on the floor since #856.
@Suite("The run's explanation actually reaches the source row (#875)")
@MainActor
struct SourceNoteIngestTests {

    private func context() -> ModelContext {
        ModelContext(try! ModelContainer(
            for: Schema([Prospect.self, Recipient.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
    }

    private func watched(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "kaufmanmusiccenter.org", orgName: "Kaufman Music Center",
                              listingsURL: "https://www.kaufmanmusiccenter.org/mch/calendar/",
                              kind: .html)
        ctx.insert(s)
        return s
    }

    private func results(_ verdict: PageVerdict, note: String?) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "now", results: [
            ScoutExtractResult(sourceId: "kaufmanmusiccenter.org", verdict: verdict,
                               events: [], note: note),
        ])
    }

    // The one the issue is about. A source the run never reached explains WHY, and Dan can read it.
    @Test func aFailedSourcesOwnExplanationLandsOnTheRow() {
        let ctx = context()
        let source = watched(ctx)

        _ = ScoutExtractIngest.ingest(results(.notRead, note:
            "The run exited with status 1 and produced no results for this source. "
            + "Last lines of the run log: + claude -p | Error: connection reset"),
            clients: [], history: [], blocked: .empty, now: Date(), into: ctx)

        #expect(source.runNote == "The run exited with status 1 and produced no results for this source.")
        #expect(source.runNoteDetail == "+ claude -p | Error: connection reset")
    }

    // A HEALTHY source can have something to say too, and it is worth saying: "only three of these had
    // text captions" is exactly the kind of thing Dan should see and currently cannot.
    @Test func aHealthySourceCanStillExplainItself() {
        let ctx = context()
        let source = watched(ctx)

        _ = ScoutExtractIngest.ingest(
            results(.upcomingListings, note: "Two shows list no venue, so they were left out."),
            clients: [], history: [], blocked: .empty, now: Date(), into: ctx)

        #expect(source.runNote == "Two shows list no venue, so they were left out.")
    }

    // THE FAILURE-PATH CASE THAT MATTERS MOST. A source that RECOVERS must stop explaining a failure it
    // no longer has. A stale note is worse than no note: it would tell Dan a healthy source is broken,
    // and he would stop believing the notes entirely.
    @Test func aSourceThatRecoversStopsExplainingItsOldFailure() {
        let ctx = context()
        let source = watched(ctx)

        _ = ScoutExtractIngest.ingest(results(.notRead, note: "The run never reached this page."), clients: [], history: [], blocked: .empty,
                                      now: Date(), into: ctx)
        #expect(source.runNote != nil)

        _ = ScoutExtractIngest.ingest(results(.upcomingListings, note: nil),
                                      clients: [], history: [], blocked: .empty, now: Date(), into: ctx)
        #expect(source.runNote == nil)
    }
}
