import Testing
import Foundation
@testable import Overture

// #1027 Phase 4: the structured, sectioned warnings the end-of-scout popup renders.
//
// Two changes from the old single string: it accumulates BOTH halves of a scout (the native Carnegie
// sweep and the detached calendar read) so a warning can no longer be lost or shown mid-run, and it
// shows EVERY applicable warning as its own ranked section rather than the single highest-priority one a
// one-line alert could hold. The reader-finished-empty signal is kept as its own section, because it is
// the one shape of failure indistinguishable from every calendar being quiet.
@MainActor
@Suite("Structured end-of-scout warnings (#1027)")
struct ScoutWarningsTests {
    private func outcome() -> ScoutService.Outcome {
        ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0, uncertain: 0)
    }

    private func failed(_ id: String, _ org: String, _ f: SourceFailure) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: org, state: .failed(f))
    }

    private func deferred(_ id: String, _ org: String) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: org, state: .deferred)
    }

    @Test func aCleanRunHasNoWarnings() {
        let w = ScoutWarnings.from(native: outcome(), extract: nil, finishedEmpty: nil)
        #expect(w.isEmpty)
        #expect(w.sections.isEmpty)
    }

    // The per-source failures come off the EXTRACT outcome (html verdict failures never reach the native
    // sweep), the native outcome carries the app-level ones. Both must survive into one model.
    @Test func failuresFromBothHalvesAreUnioned() {
        var native = outcome()
        native.sources = [failed("carnegie", "Carnegie", .fetch(.http(500)))]
        var extract = outcome()
        extract.sources = [failed("kaufman", "Kaufman", .verdict(.noDatedContent))]

        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.failedSources.map(\.sourceId).sorted() == ["carnegie", "kaufman"])
    }

    // A source that somehow appears failed in both halves is listed once.
    @Test func failuresAreDedupedBySourceId() {
        var native = outcome()
        native.sources = [failed("kaufman", "Kaufman", .fetch(.unreachable))]
        var extract = outcome()
        extract.sources = [failed("kaufman", "Kaufman", .verdict(.noDatedContent))]

        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.failedSources.map(\.sourceId) == ["kaufman"])
    }

    // Show ALL applicable, ranked: app-level first, then actionable failures, then informational.
    @Test func everyApplicableWarningSurfacesInRankedOrder() {
        var native = outcome()
        native.saveFailed = true
        native.clientListWarning = "past-client list is stale"
        var extract = outcome()
        extract.sources = [failed("kaufman", "Kaufman", .verdict(.noDatedContent))]

        let w = ScoutWarnings.from(native: native, extract: extract,
                                   finishedEmpty: "the reader ran but produced nothing")
        #expect(!w.isEmpty)
        // app-level (saveFailed, then reader-finished-empty) before actionable failures before the
        // informational past-client note.
        #expect(w.sections == [
            .saveFailed,
            .readerFinishedEmpty("the reader ran but produced nothing"),
            .failures(w.failedSources),
            .pastClientList("past-client list is stale"),
        ])
    }

    // The reader-finished-empty signal is not dropped in the rework: it is its own section.
    @Test func readerFinishedEmptyIsItsOwnSection() {
        let w = ScoutWarnings.from(native: outcome(), extract: nil,
                                   finishedEmpty: "the reader ran but produced nothing")
        #expect(!w.isEmpty)
        #expect(w.sections == [.readerFinishedEmpty("the reader ran but produced nothing")])
    }

    // MARK: - Deferred venues (#1190): over the run's budget, not checked, and NOT "clean"

    // A run that deferred sources carries the count home so the manual summary can prompt a re-run.
    // A deferred-only run is not clean: the popup must open (isEmpty false) so Dan sees what is waiting.
    @Test func deferredSourcesCountIntoTheWarnings() {
        var native = outcome()
        native.sources = [deferred("a", "A"), deferred("b", "B")]
        let w = ScoutWarnings.from(native: native, extract: nil, finishedEmpty: nil)
        #expect(w.deferredCount == 2)
        #expect(!w.isEmpty)
    }

    // Deferred sources are counted from whichever half recorded them.
    @Test func deferredCountUnionsBothHalves() {
        var native = outcome(); native.sources = [deferred("a", "A")]
        var extract = outcome(); extract.sources = [deferred("b", "B")]
        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.deferredCount == 2)
    }

    // No sources deferred: nothing waiting, and (absent other warnings) still a clean run.
    @Test func noDeferredSourcesLeavesTheCountZero() {
        let w = ScoutWarnings.from(native: outcome(), extract: nil, finishedEmpty: nil)
        #expect(w.deferredCount == 0)
        #expect(w.isEmpty)
    }

    // MARK: - The quiet line an unattended scheduled run leaves instead of the popup

    @Test func aCleanRunLeavesNoQuietLine() {
        #expect(ScoutWarnings.from(native: outcome(), extract: nil, finishedEmpty: nil).quietLine == nil)
    }

    @Test func theQuietLineIsTheSingleMostUrgentSection() {
        // save-failed outranks a per-source failure, so its line is the one shown.
        var native = outcome()
        native.saveFailed = true
        var extract = outcome()
        extract.sources = [failed("kaufman", "Kaufman", .verdict(.noDatedContent))]
        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.quietLine == "The scout couldn't save its results. Run it again.")
    }

    @Test func theFailuresQuietLinePluralizes() {
        var one = outcome()
        one.sources = [failed("a", "A", .verdict(.noDatedContent))]
        #expect(ScoutWarnings.from(native: outcome(), extract: one, finishedEmpty: nil).quietLine
                == "A source couldn't be checked. Open Sources to fix or confirm it.")

        var two = outcome()
        two.sources = [failed("a", "A", .verdict(.noDatedContent)),
                       failed("b", "B", .fetch(.http(404)))]
        #expect(ScoutWarnings.from(native: outcome(), extract: two, finishedEmpty: nil).quietLine
                == "2 sources couldn't be checked. Open Sources to fix or confirm them.")
    }
}

// #1027: the popup's own count-dependent copy, pinned so a plural bug shows in the diff (#863/#885).
@MainActor
@Suite("Scout summary popup copy (#1027)")
struct ScoutSummaryCopyTests {
    @Test func theFailuresHeadingPluralizes() {
        #expect(ScoutSummaryCopy.failuresHeading(1) == "One source couldn't be checked.")
        #expect(ScoutSummaryCopy.failuresHeading(3) == "3 sources couldn't be checked.")
    }

    @Test func theReadButtonPluralizes() {
        #expect(ScoutSummaryCopy.readFixed(1) == "Read the one I fixed")
        #expect(ScoutSummaryCopy.readFixed(2) == "Read the 2 I fixed")
    }
}

// #1190: the "N venues still waiting, run again" prompt a MANUAL scout summary shows when the run hit
// its per-scout budget and deferred sources. The show/hide rule and the singular/plural wording live in
// a helper rather than the view body, so a plural bug or a leak into scheduled runs shows in the diff
// (#863: view-computed logic drifted twice under a green suite).
@MainActor
@Suite("Re-run prompt after a budget-capped scout (#1190)")
struct ScoutRerunPromptTests {
    // (a) a manual run that deferred sources offers the prompt, with a line and a one-click button.
    @Test func aManualRunWithDeferredSourcesOffersARerun() {
        let prompt = ScoutRerunPrompt.after(deferredCount: 3, auto: false)
        #expect(prompt != nil)
        #expect(prompt?.line == "3 venues are still waiting to be checked.")
        #expect(prompt?.buttonLabel == "Run scout again")
    }

    // The line pluralizes: one waiting venue is singular.
    @Test func theLinePluralizes() {
        #expect(ScoutRerunPrompt.after(deferredCount: 1, auto: false)?.line
                == "1 venue is still waiting to be checked.")
        #expect(ScoutRerunPrompt.after(deferredCount: 5, auto: false)?.line
                == "5 venues are still waiting to be checked.")
    }

    // (b) nothing deferred, nothing to prompt.
    @Test func noDeferredSourcesShowsNoPrompt() {
        #expect(ScoutRerunPrompt.after(deferredCount: 0, auto: false) == nil)
    }

    // (c) an automatic scheduled run never nags Dan to run again. Scheduled runs defer nothing by
    // design, and even if that changed, the re-run affordance is a manual surface he chose to open.
    @Test func aScheduledRunStaysQuiet() {
        #expect(ScoutRerunPrompt.after(deferredCount: 4, auto: true) == nil)
    }
}
