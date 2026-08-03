import Testing

// #1035: a detached scout-extract read outlives the app. RootView already reattaches to an in-flight
// Prep run at launch (`if PrepQueueService.isRunning { await watchPrepRun() }`), but had no equivalent
// for the scout-extract read. If the view is recreated while a read is genuinely still running (the
// window scene torn down and rebuilt, or the app relaunched over a live detached run), the app reads as
// idle while the run continues in the background.
//
// That is a real regression once the #1034 progress modal is the primary progress signal: there is no
// toolbar-only fallback anymore. So launch must detect a live read and REOPEN the modal on its own (Dan
// asked for this scout; it reopens without a click, #1010 grilling).
//
// Guarded by source, mirroring ScoutExtractWatchGuardTests: the reattach lives in a `.task` and drives
// @State, and the failure it prevents is silent (remove it and everything still compiles and passes,
// the only symptom being a live run that shows nothing after a relaunch).
@MainActor
@Suite("A live scout-extract read is reattached at launch (#1035)")
struct ScoutReattachGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func launchReattachesToALiveRead() {
        #expect(!rootView.isEmpty)
        // The launch task gates on a genuinely-live read and hands off to the reattach, exactly as it
        // does for a live Prep run right above it.
        #expect(rootView.contains("await reattachScoutExtractRun()"))
        #expect(rootView.contains("private func reattachScoutExtractRun()"))
    }

    @Test func theReattachReopensTheModalInItsReadingPhase() {
        // It reopens the takeover on its own (readingStartedAt + the presented sheet) rather than waiting
        // for a click, so a live run is never invisible after a relaunch.
        #expect(rootView.contains("readingStartedAt = ScoutExtractService.lastRunStartedAt"))
        #expect(rootView.contains("scoutSheetShown = true"))
    }

    @Test func theReattachFollowsTheReadToCompletion() {
        // And it still ingests and reports what the run produced, via the same watch + finish path a
        // manual run uses, so a reattached run is not a dead end.
        #expect(rootView.contains("await watchScoutExtractRun()"))
        #expect(rootView.contains("finishScout("))
    }

    // The data path the reattach folds through, exercised directly. The native sweep already ran (and was
    // reported) in the session that started the run, so a reattach passes an EMPTY native outcome and
    // surfaces only what the read itself produced. A read that came back with a failed source must still
    // reach Dan; a clean read must leave nothing to pop.
    @Test func aReattachSurfacesTheReadsOwnFailureAndNothingFromAnAbsentNativeHalf() {
        var extract = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        extract.sources = [ScoutService.SourceResult(sourceId: "kaufman", orgName: "Kaufman Music Center",
                                                     state: .failed(.verdict(.unreadable)))]
        let empty = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)

        let withFailure = ScoutWarnings.from(native: empty, extract: extract, finishedEmpty: nil)
        #expect(withFailure.failedSources.map(\.sourceId) == ["kaufman"])
        #expect(!withFailure.isEmpty)   // a manual-origin run with this would pop the summary

        // A clean read (no failures, nothing finished-empty) folds to nothing, so the reattach just
        // closes the takeover instead of popping an empty summary.
        let clean = ScoutWarnings.from(native: empty, extract: empty, finishedEmpty: nil)
        #expect(clean.isEmpty)
    }

    // A reattached read that finished having produced nothing is its own shape of failure (the reader ran
    // and wrote nothing), and it must say so rather than looking like every calendar happening to be
    // quiet, exactly as a freshly-started run does.
    @Test func aReattachedReadThatFinishedEmptyStillSurfacesThatFailure() {
        let empty = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        let warnings = ScoutWarnings.from(native: empty, extract: nil,
                                          finishedEmpty: "The reader finished without producing anything.")
        #expect(!warnings.isEmpty)
        #expect(warnings.sections.contains { if case .readerFinishedEmpty = $0 { return true }; return false })
    }
}
