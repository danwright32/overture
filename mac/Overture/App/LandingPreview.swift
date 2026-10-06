import Foundation

#if DEBUG
// #4338 (A10): a Debug only way to put each landing outcome on screen, so every one can be LOOKED at (L606) on a
// synthetic store (`scripts/make-synthetic-landing-store.sh`), never on real data. `mac/scripts/run-debug.sh
// --store-folder <folder> --landing-preview <name>` hands the name to the app, which applies it once, after the
// launch survey, to the surface that outcome really appears on: the landing line for everything between scouts,
// and the scout summary for a scout's own outcomes. A Release build has none of this.
//
// The outcomes that live in records (a landing waiting to be finished, one the recovery stopped trying, a record
// it could not read, kept results) are also SEEDED as real records by the synthetic store, so those reach the
// screen through the real survey too; a preview of them is for looking at the line alone.
//
// copy-inventory:ignore-start  invented names and the Debug only preview's own refusal, never shown in a Release build (#4338)
enum LandingPreview {
    static let argument = "--overture-landing-preview"

    enum Name: String, CaseIterable, Sendable {
        // The landing line: a landing in progress.
        case working, alive, stalled
        // The landing line: the sweep of kept results.
        case keptResultsLanded, keptResultsAlreadyLanded, keptResultsWaiting, keptResultsStuck
        // The landing line: the idle recovery.
        case waitingForIdle, landedByRecovery, overtaken, checkingAgain, recoveryNotFinished, recordsUnreadable
        // The landing line: the standing states and their two actions.
        case stoppedRetrying, recordUnreadable, editsStuck
        // The scout summary: a scout's own outcomes.
        case alreadyLanded, refused, recentEditsUnsaved, notLandedYet, couldNotBeSaved, couldNotBeSavedRetried,
             notAttempted, notReverted, superseded
    }

    // What the launch was asked to preview, read once. nil when it was not asked.
    static var requested: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: argument), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    // Invented, like the synthetic store's own names (`LandingOracleCorpus`): never a real organisation.
    static let sources = ["Harbor Stage Collective", "Lantern Hall Players", "Marlow Theatre Company"]
    static let shows = ["Tidewater Suite", "Copper Tide"]

    // Where a preview goes: the landing line, or the scout summary with these warnings, or nowhere because the
    // name is not one of them, which is said rather than showing nothing (L320).
    enum Shown {
        case landingLine
        case summary(ScoutWarnings)
        case unknown(String)
    }

    @MainActor
    static func apply(_ raw: String, now: Date, marker: LandingMarker = .shared,
                      flushes: EntryFlushRecord = .shared, journals: LandingJournals = .live) -> Shown {
        guard let name = Name(rawValue: raw) else {
            return .unknown("No landing preview is called \(raw). The names are: "
                + Name.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let earlier = now.addingTimeInterval(-2 * 3_600)
        let journal = LandingJournal(runIdentity: "preview-run", sequence: 42, entryPoint: .scoutExtractIngest,
                                     sources: sources.map { .init(sourceId: $0, pageHash: nil) }, now: earlier,
                                     resultsCopy: "preview-run")
        var warnings = ScoutWarnings(saveFailed: false, extractLaunchFailure: nil, extractRunFinishedEmpty: nil,
                                     failedSources: [], unqueuedIds: [], silentlyEmptySources: [], clientListWarning: nil)
        switch name {
        case .working:
            marker.began(.calendarResults, at: now)
        case .alive:
            marker.began(.keptResults, at: now.addingTimeInterval(-42))
            marker.previewWaitingBehind = .runScoutLanding
        case .stalled:
            marker.began(.calendarResults, at: now.addingTimeInterval(-(RunTimeouts.landing + 60)))
        case .keptResultsLanded:
            marker.said([.keptResultsLanded(sets: 2)])
        case .keptResultsAlreadyLanded:
            marker.said([.keptResultsAlreadyLanded(at: earlier)])
        case .keptResultsWaiting:
            marker.said([.keptResultsWaiting(sets: 1)])
        case .keptResultsStuck:
            marker.said([.keptResultsStuck(sets: 1, over: ScoutSchedule.defaultInterval)])
        case .waitingForIdle:
            marker.surveyed(LandingRecovery.Survey(interrupted: [
                .init(journal: journal, finding: .replay, unlanded: Array(sources.prefix(2)))]))
        case .landedByRecovery:
            marker.said([.landedByRecovery(startedAt: earlier)])
        case .overtaken:
            marker.said([.overtakenWhileInterrupted(startedAt: earlier)])
        case .checkingAgain:
            marker.said([.checkingCalendarsAgain(startedAt: earlier)])
        case .recoveryNotFinished:
            marker.said([.recoveryNotFinished(startedAt: earlier, why: LandingRecovery.storeHeldElsewhere)])
        case .recordsUnreadable:
            marker.said([.recordsUnreadable(why: "the folder could not be listed")])
        case .stoppedRetrying:
            marker.surveyed(LandingRecovery.Survey(interrupted: [
                .init(journal: journal, finding: .stoppedRetrying(attempts: LandingRecovery.attemptCap),
                      unlanded: sources)]))
        case .recordUnreadable:
            marker.surveyed(LandingRecovery.Survey(unreadable: [
                journals.directory.appendingPathComponent(
                    LandingJournals.fileName(sequence: 41, runIdentity: "preview-unreadable")
                        + LandingJournals.quarantineSuffix).path]))
        case .editsStuck:
            for _ in 0..<EntryFlushRecord.stuckAfter { flushes.refused(rows: shows + [sources[0]]) }
        case .alreadyLanded:
            warnings.alreadyLandedAt = earlier
            return .summary(warnings)
        case .refused:
            warnings.notLandedYet = LandingWaitCopy.refused(.scoutExtractIngest, waited: .seconds(30 * 60))
            return .summary(warnings)
        case .recentEditsUnsaved:
            warnings.landingStopped = ScoutWarningCopy.recentEditsUnsaved(shows)
            return .summary(warnings)
        case .notLandedYet:
            warnings.notLandedYet = LandingWaitCopy.ingestCancelled
            return .summary(warnings)
        case .couldNotBeSaved, .couldNotBeSavedRetried:
            warnings.saveFailed = true
            warnings.saveFailedRetried = name == .couldNotBeSavedRetried
            return .summary(warnings)
        case .notAttempted:
            warnings.saveFailed = true
            warnings.landingStopped = ScoutWarningCopy.notAttempted(2)
            return .summary(warnings)
        case .notReverted:
            warnings.saveFailed = true
            warnings.landingStopped = ScoutWarningCopy.notReverted(sources[0]) + " " + ScoutWarningCopy.notAttempted(2)
            return .summary(warnings)
        case .superseded:
            warnings.supersededSources = [ScoutService.SourceResult(sourceId: "preview-lantern", orgName: sources[1],
                                                                    state: .superseded)]
            return .summary(warnings)
        }
        return .landingLine
    }
}
// copy-inventory:ignore-end
#endif
