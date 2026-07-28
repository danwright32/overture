import Testing
@testable import Overture

// #27, rewritten per-source for #802.
//
// The old rule: any run that found zero events warns, because with one source (Carnegie's 90-day
// window) zero really did mean the page had changed or broken.
//
// Under a watchlist that rule becomes actively harmful. Zero is the NORMAL off-season answer (5 of the
// 7 real sites in the #770 spike, in July) and is also exactly what a fully hash-skipped run
// legitimately returns. Firing "the feed's data format may have changed" on every quiet week would
// train Dan to ignore the one warning that matters, which is the failure this whole feature exists to
// prevent, arriving by the back door.
//
// So the warning is now health-aware: an empty result is only unusual for a source that HAS a feed
// history and came back with nothing anyway.
@MainActor
@Suite("Scout outcome warning, per source (#27, #802)")
struct ScoutOutcomeWarningTests {
    private func outcome(found: Int, clientListWarning: String? = nil,
                         sources: [ScoutService.SourceResult] = []) -> ScoutService.Outcome {
        var o = ScoutService.Outcome(found: found, inserted: 0, updated: 0, skipped: 0,
                                     clientListWarning: clientListWarning)
        o.sources = sources
        return o
    }

    private func source(_ state: ScoutService.SourceResult.State, id: String = "carnegie",
                        hadBaseline: Bool = true) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: id == "carnegie" ? "Carnegie Hall" : id,
                                  state: state, hadBaseline: hadBaseline)
    }

    // MARK: - An established source that suddenly returns nothing

    @Test func anEstablishedSourceReturningNothingStillWarns() {
        let w = outcome(found: 0, sources: [source(.ingested(found: 0))]).warning
        #expect(w?.isEmpty == false)
    }

    // It must read as "nothing came back", distinct from a connection failure, which has its own copy.
    @Test func theEmptyWarningReadsAsAnEmptyResultNotAConnectionProblem() {
        let w = outcome(found: 0, sources: [source(.ingested(found: 0))]).warning ?? ""
        #expect(w.localizedCaseInsensitiveContains("no"))
        #expect(!w.localizedCaseInsensitiveContains("connection"))
    }

    @Test func anEmptyEstablishedFeedOutranksTheClientListWarning() {
        let w = outcome(found: 0, clientListWarning: "stale clients",
                        sources: [source(.ingested(found: 0))]).warning
        #expect(w != "stale clients")
        #expect(w?.isEmpty == false)
    }

    // MARK: - The cases that must now stay QUIET

    // A brand-new source's first check returning nothing is not unusual. It has no history that says
    // otherwise, and warning about it would mean every source Dan adds in the off-season nags him on
    // the day he adds it.
    @Test func aSourceWithNoHistoryReturningNothingIsQuiet() {
        let o = outcome(found: 0, sources: [source(.ingested(found: 0), id: "new-org", hadBaseline: false)])
        #expect(o.warning == nil)
    }

    // A run where every page was unchanged found zero events and is perfectly healthy. This is the
    // steady state of a working watchlist, and it must not warn, or the warning becomes wallpaper.
    @Test func aFullyUnchangedRunIsQuiet() {
        let o = outcome(found: 0, sources: [source(.unchanged, id: "a"), source(.unchanged, id: "b")])
        #expect(o.warning == nil)
    }

    @Test func aRunWithNoSourcesAtAllIsQuiet() {
        #expect(outcome(found: 0).warning == nil)
    }

    // MARK: - A source that could not be checked is named, every run

    @Test func aFailingSourceIsNamedAlongWithWhatWentWrong() {
        let w = outcome(found: 5, sources: [source(.failed(.fetch(.http(404))), id: "bargemusic")]).warning ?? ""

        #expect(w.contains("bargemusic"))
        #expect(w.contains("404"))
    }

    @Test func everyFailingSourceIsNamedNotJustTheFirst() {
        let w = outcome(found: 5, sources: [
            source(.failed(.fetch(.http(404))), id: "bargemusic"),
            source(.failed(.fetch(.unreachable)), id: "merkin"),
        ]).warning ?? ""

        #expect(w.contains("bargemusic"))
        #expect(w.contains("merkin"))
    }

    // A broken source is more actionable than a quiet one, so it is what Dan is told about.
    @Test func aFailureOutranksAnEmptyFeedAndTheClientList() {
        let w = outcome(found: 0, clientListWarning: "stale clients", sources: [
            source(.ingested(found: 0)),
            source(.failed(.fetch(.http(500))), id: "bargemusic"),
        ]).warning ?? ""

        #expect(w.contains("bargemusic"))
        #expect(w != "stale clients")
    }

    // A save failure still outranks everything: the run may have found and processed shows that never
    // persisted, which is the most actionable problem there is (#499).
    @Test func aSaveFailureOutranksEverything() {
        var o = outcome(found: 0, clientListWarning: "stale clients",
                        sources: [source(.failed(.fetch(.http(500))), id: "bargemusic")])
        o.saveFailed = true

        #expect(o.warning?.localizedCaseInsensitiveContains("save") == true)
    }

    // MARK: - Pages that changed and could not be handed off to be read (#802)

    // The runner not being configured is the first thing Dan will hit, and it MUST be loud. A watchlist
    // that quietly never reads anything is indistinguishable from one where every calendar is quiet,
    // and he would go on believing his sources were being watched.
    @Test func failingToHandOffTheChangedPagesIsSaidOutLoud() {
        var o = outcome(found: 5, sources: [source(.queuedForReading, id: "org")])
        o.extractLaunchFailure = "The reader isn't set up yet."

        #expect(o.warning == "The reader isn't set up yet.")
    }

    // It outranks a per-source failure, because it is the APP that is broken rather than a calendar, and
    // because it has a one-step fix.
    @Test func aFailedHandOffOutranksAFailingSource() {
        var o = outcome(found: 5, sources: [source(.failed(.fetch(.http(404))), id: "bargemusic")])
        o.extractLaunchFailure = "The reader isn't set up yet."

        #expect(o.warning == "The reader isn't set up yet.")
    }

    // But a save failure still outranks even that: shows were processed and never persisted.
    @Test func aSaveFailureStillOutranksAFailedHandOff() {
        var o = outcome(found: 5)
        o.extractLaunchFailure = "The reader isn't set up yet."
        o.saveFailed = true

        #expect(o.warning?.localizedCaseInsensitiveContains("save") == true)
    }

    // MARK: - The healthy run

    @Test func withEventsTheClientListWarningPassesThrough() {
        let sources = [source(.ingested(found: 5))]
        #expect(outcome(found: 5, clientListWarning: "stale clients", sources: sources).warning == "stale clients")
        #expect(outcome(found: 5, clientListWarning: nil, sources: sources).warning == nil)
    }
}
