import Testing
import Foundation

// #4338 (A10): every outcome a scout landing can have is said in its own sentence and shown in its own state, and
// the four states Dan's rule keeps apart (working, alive, stalled, failed) are each reached by the outcomes that
// are that state, never by a nearby one. Pure, so each rule is tested without a store or a screen.
@MainActor
@Suite("A scout landing's outcome is said once each, in the state it is in (#4338)")
struct LandingProgressTests {
    private let at = Date(timeIntervalSince1970: 1_791_000_000)
    private let ref = LandingRef(runIdentity: "sweep-x", sequence: 9)

    // One of every case, so a case added later without a look or a sentence fails here.
    private var every: [LandingOutcome] {
        [.landing(.calendarResults, startedAt: at), .landing(.interrupted(startedAt: at), startedAt: at),
         .waitingBehind(holder: nil), .waitingBehind(holder: .landingRecovery),
         .landingLooksStuck(.keptResults, elapsed: "6:00"),
         .keptResultsLanded(sets: 2), .keptResultsAlreadyLanded(at: at), .keptResultsWaiting(sets: 1),
         .keptResultsStuck(sets: 1, over: 86_400), .keptResultsUnreadable(["Overture could not read it."]),
         .keptCopyNotRemoved(LandingWaitCopy.copyNotRemoved("no permission")), .judgedAgainstLess(labels: ["x"]),
         .waitingForIdle(startedAt: at), .landedByRecovery(startedAt: at), .overtakenWhileInterrupted(startedAt: at),
         .checkingCalendarsAgain(startedAt: at), .recoveryNotFinished(startedAt: at, why: "a reason"),
         .recordsUnreadable(why: "a reason"), .stoppedRetrying(ref, startedAt: at, attempts: 3, unlanded: 4),
         .recordUnreadable(path: "/x"), .recordStillUnreadable(path: "/x", why: "a reason"),
         .editsStuck(rows: ["Copper Tide"], lastTryFailedAt: nil), .editsSaved, .editsDiscarded,
         .editsDiscardedButStillNotSaving(why: "a reason"), .interruptedDiscarded(startedAt: at),
         .unreadableRecordDiscarded, .retryNotRecorded(startedAt: at, why: "a reason"),
         .unreadableRecordNotDiscarded(why: "a reason"), .nothingLeftToDiscard]
    }

    @Test func everyOutcomeHasItsOwnSentence() {
        let lines = every.map(\.line)
        #expect(lines.allSatisfy { !$0.isEmpty }, Comment(rawValue: "\(zip(every, lines).filter { $0.1.isEmpty })"))
    }

    // The issue's list, each outcome in the state it is: the four Dan's rule names, and finished.
    @Test func eachOutcomeIsShownInTheStateItIsIn() {
        #expect(LandingOutcome.landing(.calendarResults, startedAt: at).look == .working)
        #expect(LandingOutcome.waitingBehind(holder: nil).look == .alive)
        #expect(LandingOutcome.waitingForIdle(startedAt: at).look == .alive)
        #expect(LandingOutcome.keptResultsWaiting(sets: 1).look == .alive)
        #expect(LandingOutcome.landingLooksStuck(.calendarResults, elapsed: "6:00").look == .stalled)
        #expect(LandingOutcome.keptResultsStuck(sets: 1, over: 86_400).look == .stalled)
        #expect(LandingOutcome.stoppedRetrying(ref, startedAt: at, attempts: 3, unlanded: 1).look == .stalled)
        #expect(LandingOutcome.editsStuck(rows: [], lastTryFailedAt: nil).look == .stalled)
        for failed: LandingOutcome in [.recordUnreadable(path: "/x"), .recordsUnreadable(why: "x"),
                                       .keptResultsUnreadable(["x"]), .editsDiscardedButStillNotSaving(why: "x")] {
            #expect(failed.look == .failed, Comment(rawValue: "\(failed)"))
        }
        for finished: LandingOutcome in [.keptResultsLanded(sets: 1), .landedByRecovery(startedAt: at),
                                         .keptResultsAlreadyLanded(at: at), .overtakenWhileInterrupted(startedAt: at)] {
            #expect(finished.look == .finished, Comment(rawValue: "\(finished)"))
        }
        // Every look is reached by something, so none of the five is a state nothing can be in (L90).
        #expect(Set(every.map(\.look)) == Set(LandingLook.allCases))
    }

    // Only the standing states needing Dan carry controls, each the pair the decision names, keep first.
    @Test func onlyTheStandingStatesCarryTheirTwoActions() {
        #expect(LandingOutcome.editsStuck(rows: [], lastTryFailedAt: nil).actions == [.trySavingAgain, .discardUnsavedEdits])
        #expect(LandingOutcome.stoppedRetrying(ref, startedAt: at, attempts: 3, unlanded: 1).actions
                == [.tryInterruptedLandingAgain(ref), .discardInterruptedLanding(ref)])
        #expect(LandingOutcome.recordUnreadable(path: "/x").actions
                == [.tryUnreadableRecordAgain(path: "/x"), .discardUnreadableRecord(path: "/x")])
        let withActions = every.filter { !$0.actions.isEmpty }
        #expect(withActions.allSatisfy { $0.look == .stalled || $0.look == .failed })
        #expect(withActions.count == 3, Comment(rawValue: "\(withActions)"))
        // A failed "Try again" says so beside the record it is about, which keeps the controls.
        #expect(LandingOutcome.recordStillUnreadable(path: "/x", why: "a reason").actions.isEmpty)
    }

    @Test func eachDiscardLooksDestructiveAndAsksFirst() {
        for action: LandingAction in [.discardUnsavedEdits, .discardInterruptedLanding(ref), .discardUnreadableRecord(path: "/x")] {
            #expect(action.isDestructive && action.confirmationTitle != nil, Comment(rawValue: "\(action)"))
        }
        for action: LandingAction in [.trySavingAgain, .tryInterruptedLandingAgain(ref), .tryUnreadableRecordAgain(path: "/x")] {
            #expect(!action.isDestructive && action.confirmationTitle == nil, Comment(rawValue: "\(action)"))
        }
        #expect(LandingAction.trySavingAgain.title == "Try saving again")
        #expect(LandingAction.discardUnsavedEdits.title == "Discard these unsaved edits")
    }

    // A landing in progress: its start time while it runs, a ticking counter while it waits its turn, and that it
    // looks stuck once its window has passed.
    @Test func aLandingInProgressShowsItsStartThenWaitingThenStuck() {
        let running = LandingOutcome.live(.calendarResults, startedAt: at, now: at.addingTimeInterval(30),
                                          waiting: false, holder: nil)
        #expect(running.outcome == .landing(.calendarResults, startedAt: at) && running.counter == nil)
        #expect(running.outcome.line.contains(LandingWaitCopy.landedTime(at)))

        let waiting = LandingOutcome.live(.keptResults, startedAt: at, now: at.addingTimeInterval(42),
                                          waiting: true, holder: .landingRecovery)
        #expect(waiting.outcome == .waitingBehind(holder: .landingRecovery) && waiting.counter == "0:42")
        #expect(waiting.outcome.line == "Waiting for the interrupted landing to finish.")

        let stuck = LandingOutcome.live(.calendarResults, startedAt: at,
                                        now: at.addingTimeInterval(RunTimeouts.landing + 1), waiting: false, holder: nil)
        #expect(stuck.outcome.look == .stalled, Comment(rawValue: "\(stuck.outcome)"))
        #expect(stuck.outcome.line == RunProgress.stalledLabel("Landing the calendar results", elapsed: "5:01"))

        // Waiting in the queue is never called stuck, however long the wait: it has its own named deadline.
        let longWait = LandingOutcome.live(.keptResults, startedAt: at, now: at.addingTimeInterval(20 * 60),
                                           waiting: true, holder: .runScoutLanding)
        #expect(longWait.outcome.look == .alive)
        #expect(LandingWork.interrupted(startedAt: at).entryPoint == .landingRecovery)
        #expect(LandingWork.keptResults.entryPoint == .scoutExtractIngest)
    }

    // The sweep of kept results, one line per part, what needs Dan first (L609), in the words its line always used.
    @Test func aSweepOfKeptResultsLeavesEachPartInItsOwnState() {
        var offered = ScoutExtractLanding.Offered()
        offered.landed = [ScoutService.Outcome(found: 1, inserted: 1, updated: 0, skipped: 0)]
        offered.stillWaiting = 1
        offered.stuck = 2
        let lines = LandingOutcome.from(offered: offered, degradedLabels: [])
        #expect(lines == [.keptResultsStuck(sets: 2, over: offered.stuckAfter), .keptResultsWaiting(sets: 1),
                          .keptResultsLanded(sets: 1)])
        #expect(lines.map(\.line) == [LandingWaitCopy.keptResultsStuck(2, over: offered.stuckAfter),
                                       LandingWaitCopy.keptResultsWaiting(1), LandingWaitCopy.keptResultsLanded(1)])
        #expect(LandingOutcome.from(offered: ScoutExtractLanding.Offered(), degradedLabels: []).isEmpty)
    }

    // A landing the recovery stopped trying is the standing state, never a recovery line said beside it.
    @Test func theRecoveryStepsBecomeLinesAndAStoppedLandingStandsInstead() {
        #expect(LandingOutcome.from(recovered: .landed(startedAt: at, sources: 2), ref: nil) == .landedByRecovery(startedAt: at))
        #expect(LandingOutcome.from(recovered: .retired(startedAt: at, finding: .finished), ref: nil) == nil)
        #expect(LandingOutcome.from(recovered: .stoppedRetrying(startedAt: at, attempts: 3, unlanded: 1), ref: nil) == nil)
        #expect(LandingOutcome.from(recovered: .stoppedRetrying(startedAt: at, attempts: 3, unlanded: 1), ref: ref)
                == .stoppedRetrying(ref, startedAt: at, attempts: 3, unlanded: 1))
    }

    @Test func theStandingStatesAreOrderedForTheReader() {
        let journal = LandingJournal(runIdentity: "sweep-x", sequence: 9, entryPoint: .runScoutLanding,
                                     sources: [], now: at)
        let waiting = LandingRecovery.Interrupted(journal: journal, finding: .sweep, unlanded: ["a"])
        let stopped = LandingRecovery.Interrupted(journal: journal, finding: .stoppedRetrying(attempts: 3),
                                                  unlanded: ["a", "b"])
        let standing = LandingOutcome.standing(interrupted: [waiting, stopped], unreadable: ["/x"],
                                               editsStuck: (rows: ["Copper Tide"], lastTryFailedAt: nil))
        #expect(standing == [.editsStuck(rows: ["Copper Tide"], lastTryFailedAt: nil),
                             .stoppedRetrying(ref, startedAt: at, attempts: 3, unlanded: 2),
                             .recordUnreadable(path: "/x"), .waitingForIdle(startedAt: at)])
        #expect(LandingOutcome.standing(interrupted: [], unreadable: [], editsStuck: nil).isEmpty)
    }

    @Test func theEditsStuckLineNamesTheRowsAndAFailedTry() {
        let stuck = LandingOutcome.editsStuck(rows: ["Copper Tide", "Tidewater Suite"], lastTryFailedAt: nil).line
        #expect(stuck.contains("Not yet saved: Copper Tide, Tidewater Suite."))
        let tried = LandingOutcome.editsStuck(rows: ["Copper Tide"], lastTryFailedAt: at).line
        #expect(tried.hasSuffix("Trying again at \(LandingWaitCopy.landedTime(at)) failed too."))
    }

    // A scout's own summary draws its landing outcomes in the same states: a refusal is a failure, results kept to
    // be offered again are still coming, and a newer reading or an earlier landing is finished. The other sections
    // are not landing outcomes and keep their own treatment.
    @Test func theSummaryDrawsItsLandingOutcomesInTheSameStates() {
        #expect(ScoutWarnings.Section.saveFailed.look == .failed)
        #expect(ScoutWarnings.Section.landingStopped(ScoutWarningCopy.notAttempted(2)).look == .failed)
        #expect(ScoutWarnings.Section.notLandedYet(LandingWaitCopy.ingestCancelled).look == .alive)
        #expect(ScoutWarnings.Section.alreadyLanded(at).look == .finished)
        #expect(ScoutWarnings.Section.superseded([]).look == .finished)
        #expect(ScoutWarnings.Section.failures([]).look == nil)
        #expect(ScoutWarnings.Section.storeUnreadable(1, []).look == nil)
    }

    // #4338: a save failure says it will be tried again only when the recovery really will (L703).
    @Test func aSaveFailureSaysItWillBeRetriedOnlyWhenItWillBe() {
        #expect(LandingRecovery.willRetry(journalKept: true, attempts: 0))
        #expect(LandingRecovery.willRetry(journalKept: true, attempts: LandingRecovery.attemptCap - 1))
        #expect(!LandingRecovery.willRetry(journalKept: true, attempts: LandingRecovery.attemptCap))
        #expect(!LandingRecovery.willRetry(journalKept: false, attempts: 0))

        var retried = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        retried.saveFailed = true
        retried.retriedByRecovery = true
        var notRetried = retried
        notRetried.retriedByRecovery = false
        let clean = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)

        #expect(ScoutWarnings.from(native: retried, extract: nil, finishedEmpty: nil).saveFailedRetried)
        #expect(!ScoutWarnings.from(native: retried, extract: notRetried, finishedEmpty: nil).saveFailedRetried)
        #expect(ScoutWarnings.from(native: clean, extract: retried, finishedEmpty: nil).saveFailedRetried)
        #expect(!ScoutWarnings.from(native: clean, extract: nil, finishedEmpty: nil).saveFailedRetried)

        #expect(retried.warning?.hasPrefix(ScoutWarningCopy.saveFailedRetried) == true)
        #expect(notRetried.warning?.hasPrefix(ScoutWarningCopy.saveFailed) == true)
        #expect(ScoutWarnings.from(native: retried, extract: nil, finishedEmpty: nil).quietLine
                == "The scout couldn't save its results. Overture will try again when you are away from the Mac.")
        #expect(ScoutWarnings.from(native: notRetried, extract: nil, finishedEmpty: nil).quietLine
                == "The scout couldn't save its results. Run it again.")

        // Merged, one half that will not be retried decides the sentence.
        var merged = retried
        merged.merge(notRetried)
        #expect(merged.saveFailed && !merged.retriedByRecovery)
        var both = retried
        both.merge(retried)
        #expect(both.retriedByRecovery)
        var cleanMerged = clean
        cleanMerged.merge(clean)
        #expect(!cleanMerged.retriedByRecovery)
    }
}
