import Testing
import Foundation

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
        ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
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

    // #2758 / #2999: a run that refused rows because the store stopped answering must SAY so. The
    // refusal is the right call (writing anyway merges two shows into one row and takes a card's keep
    // decision, its contacts and its outreach record with it), but a run that quietly leaves shows out
    // is indistinguishable from a run that found none (L98).
    @Test func refusedRowsSurfaceAsTheirOwnWarning() {
        var native = outcome()
        native.storeUnreadable = 2

        let w = ScoutWarnings.from(native: native, extract: nil, finishedEmpty: nil)
        #expect(!w.isEmpty)
        #expect(w.sections == [.storeUnreadable(2)])
        #expect(w.quietLine == "2 shows were left out this run because the local store stopped answering. Run the scout again.")
    }

    // It counts across both halves, so which half met the unreadable store is not a fact about Dan's run.
    @Test func refusedRowsFromBothHalvesAreSummed() {
        var native = outcome()
        native.storeUnreadable = 1
        var extract = outcome()
        extract.storeUnreadable = 3

        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.sections == [.storeUnreadable(4)])
    }

    // And a run that refused nothing says nothing, which is what keeps this from being a section Dan
    // learns to scroll past.
    @Test func aRunThatRefusedNothingCarriesNoSuchWarning() {
        let w = ScoutWarnings.from(native: outcome(), extract: nil, finishedEmpty: nil)
        #expect(!w.sections.contains { if case .storeUnreadable = $0 { return true } else { return false } })
    }

    // It ranks with the app-level warnings, above the actionable per-source ones: nothing is wrong with
    // any source, and there is nothing to fix per-source.
    @Test func refusedRowsRankWithTheAppLevelWarnings() {
        var native = outcome()
        native.saveFailed = true
        native.storeUnreadable = 1
        var extract = outcome()
        extract.sources = [failed("kaufman", "Kaufman", .verdict(.noDatedContent))]

        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.sections == [.saveFailed, .storeUnreadable(1), .failures(w.failedSources)])
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

    // MARK: - An established calendar that came back empty (#1531)

    private func emptyWithBaseline(_ id: String, _ org: String) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: org, state: .ingested(found: 0), hadBaseline: true)
    }

    // #1531: the run KNOWS which calendar went quiet, and that is the only actionable fact in the warning.
    // The old model collapsed it to a Bool, so the popup could only say "the calendar feed" and Dan had no
    // way to tell which of 62 sources it meant.
    @Test func theEmptyFeedWarningCarriesTheSourceThatWentQuiet() {
        var native = outcome()
        native.sources = [emptyWithBaseline("jalopy", "Jalopy Theatre")]
        let w = ScoutWarnings.from(native: native, extract: nil, finishedEmpty: nil)

        #expect(w.silentlyEmptySources.map(\.orgName) == ["Jalopy Theatre"])
        #expect(w.sections == [.silentlyEmptyFeed(w.silentlyEmptySources)])
    }

    // A source with no history has nothing unusual about an empty check, and a quiet off-season is not a
    // defect: that rule is unchanged, and is what keeps this warning rare enough to be worth reading.
    @Test func aSourceWithNoBaselineNeverWarns() {
        var native = outcome()
        native.sources = [ScoutService.SourceResult(sourceId: "new", orgName: "New Venue",
                                                    state: .ingested(found: 0), hadBaseline: false)]
        let w = ScoutWarnings.from(native: native, extract: nil, finishedEmpty: nil)
        #expect(w.silentlyEmptySources.isEmpty)
        #expect(w.isEmpty)
    }

    // Both halves of a run can land an established source, so both must be able to report one empty, and a
    // co-listed source seen empty in both is named once (the same rule the failures already follow).
    @Test func emptySourcesFromBothHalvesAreUnionedAndDeduped() {
        var native = outcome()
        native.sources = [emptyWithBaseline("jalopy", "Jalopy Theatre"),
                          emptyWithBaseline("roulette", "Roulette")]
        var extract = outcome()
        extract.sources = [emptyWithBaseline("roulette", "Roulette"),
                           emptyWithBaseline("kitchen", "The Kitchen")]

        let w = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(w.silentlyEmptySources.map(\.sourceId) == ["jalopy", "roulette", "kitchen"])
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

    // #1531: even the one quiet line a scheduled run leaves names the calendar. "An established calendar
    // came back empty" sent Dan to the Sources sheet to work out which one.
    @Test func theEmptyFeedQuietLineNamesTheCalendar() {
        var one = outcome()
        one.sources = [emptyWithBaseline("jalopy", "Jalopy Theatre")]
        let line = ScoutWarnings.from(native: one, extract: nil, finishedEmpty: nil).quietLine
        #expect(line?.contains("Jalopy Theatre") == true)

        var three = outcome()
        three.sources = [emptyWithBaseline("jalopy", "Jalopy Theatre"),
                         emptyWithBaseline("roulette", "Roulette"),
                         emptyWithBaseline("kitchen", "The Kitchen")]
        #expect(ScoutWarnings.from(native: three, extract: nil, finishedEmpty: nil).quietLine
                == "3 established calendars came back empty this run.")
    }
}

// #1531: the sentence the popup shows when a calendar that has listed shows before comes back with
// nothing. It used to name no source at all ("the scout reached the calendar feed") and to explain the
// surprise with a 90-day window, which was Carnegie's Algolia index horizon from when Carnegie was the
// only established feed. Shown for any of 62 sources it was simply a number about none of them, and it
// was not the app's own horizon either (a month plus three).
@MainActor
@Suite("Empty-feed warning copy (#1531)")
struct SilentlyEmptyFeedCopyTests {
    @Test func itNamesTheOneCalendarThatWentQuiet() {
        let line = ScoutWarningCopy.silentlyEmptyFeed(orgNames: ["Jalopy Theatre"])
        #expect(line == "Jalopy Theatre has listed shows before and came back with nothing this run. Its page format may have changed.")
    }

    // The claim it can no longer make: a window nobody measured for this source.
    @Test func itClaimsNoWindowOfItsOwn() {
        for names in [["Jalopy Theatre"], ["Jalopy Theatre", "Roulette"]] {
            let line = ScoutWarningCopy.silentlyEmptyFeed(orgNames: names)
            #expect(!line.contains("90"))
            #expect(!line.lowercased().contains("day"))
        }
    }

    // Several established calendars can go quiet in one run, and the sentence names every one of them
    // rather than reading as though there were only ever a single feed.
    @Test func itNamesEveryCalendarWhenSeveralGoQuiet() {
        let line = ScoutWarningCopy.silentlyEmptyFeed(orgNames: ["Jalopy Theatre", "Roulette", "The Kitchen"])
        #expect(line == "3 sources have listed shows before and came back with nothing this run: Jalopy Theatre, Roulette, The Kitchen. Their page formats may have changed.")
    }

    // The old single-string warning reads the SAME copy, so the two surfaces cannot drift apart.
    @Test func theSingleStringWarningNamesTheCalendarToo() {
        var outcome = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        outcome.sources = [ScoutService.SourceResult(sourceId: "jalopy", orgName: "Jalopy Theatre",
                                                    state: .ingested(found: 0), hadBaseline: true)]
        #expect(outcome.warning == ScoutWarningCopy.silentlyEmptyFeed(orgNames: ["Jalopy Theatre"]))
    }

    // MARK: - #1539: a page that was read fine is not a page whose format changed

    // The real run, from the live store on 2026-07-26 at 10:08: The Players Theatre, baseline 153,
    // readable 0, DROPPED 149. Every row was read and then dropped for having no venue (#1529). The
    // warning explained it as a format change while the same run had recorded the 149 on that row, so
    // it named a cause that was not true and sent Dan to inspect a page that was correct.
    @Test func aSourceThatDroppedEveryRowIsNotBlamedOnItsPageFormat() {
        let line = ScoutWarningCopy.silentlyEmptyFeed(sources: [("The Players Theatre", 149)])

        #expect(!line.contains("format"), "the page was read fine, so its format is not the finding")
        #expect(line.contains("149"), "the count the run already recorded is the actionable fact")
        #expect(line == "The Players Theatre listed 149 shows this run and every one was dropped, so its page is being read fine. Open Sources to see why they were dropped.")
    }

    // The other case keeps today's sentence, because for a page that really did come back with nothing,
    // a format change is a fair thing to suspect.
    @Test func aSourceThatReadNothingKeepsTheFormatExplanation() {
        let line = ScoutWarningCopy.silentlyEmptyFeed(sources: [("Jalopy Theatre", 0)])
        #expect(line == "Jalopy Theatre has listed shows before and came back with nothing this run. Its page format may have changed.")
    }

    // A run can produce both, and picking one explanation would be wrong about the rest of the sources
    // in the same sentence.
    @Test func aRunWithBothKindsExplainsEachOfThem() {
        let line = ScoutWarningCopy.silentlyEmptyFeed(sources: [("Jalopy Theatre", 0),
                                                                ("The Players Theatre", 149)])

        #expect(line.contains("Jalopy Theatre has listed shows before"))
        #expect(line.contains("Its page format may have changed."))
        #expect(line.contains("The Players Theatre listed 149 shows this run and every one was dropped"))
    }

    @Test func oneDroppedShowIsNotReportedAsShows() {
        let line = ScoutWarningCopy.silentlyEmptyFeed(sources: [("Jalopy Theatre", 1)])
        #expect(line.contains("listed 1 show this run"))
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
