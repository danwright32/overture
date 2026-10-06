import Foundation

// #4338 (A10, step A10 of the scout landing plan, discussion #4326): every outcome a scout landing can have,
// in one place, each with its own sentence and the state it is SHOWN in.
//
// Dan's rule for anything that takes time (his words, 2026-06-28: "that's a principle we should apply
// everywhere"): it started, it is still alive, it stalled, and it failed are four different things on screen,
// never one spinner. A landing adds a fifth that the rule takes for granted, finished. So each outcome carries
// its LOOK, and the landing line (`LandingLine`) draws each look its own way: a spinner and a start time for
// working, a spinner and a ticking counter for alive, a warning symbol for stalled, the warning colour for
// failed, and quiet ink for finished.
//
// The sentences are the ones the rest of the app already says, wherever one exists (`LandingWaitCopy`,
// `ScoutWarningCopy`, `RunProgress`): one wording per fact (#843). This catalogue adds only the sentences no
// surface had: the line a landing in progress shows, the standing states with their two actions, and what each
// action did.
//
// WHERE EACH OUTCOME IS SHOWN, because not all of them are shown here. A scout Dan started ends in its summary
// (`ScoutSummaryView`), and a scheduled one in the quiet line; those outcomes are `ScoutWarnings` sections, each
// with its own sentence there, and the landing ones carry a look of their own below (`ScoutWarnings.Section.look`)
// so the summary draws them in the same five states. Everything that happens BETWEEN scouts, a landing in
// progress, the sweep of kept calendar results, the idle recovery, and the standing states that need Dan, is the
// landing line's, and is `LandingOutcome`.
//
// THE HONEST LIMIT (the plan's): a landing applies its results in one synchronous block, and nothing on screen
// can redraw during it. So a landing in progress shows its START TIME, which stays true however long the
// block runs, rather than a counter that would sit frozen and read as alive; a counter is shown only where the
// screen can tick, while a landing waits its turn. Ticking through the block arrives with C5.
enum LandingLook: String, Equatable, Sendable, CaseIterable {
    // A landing started. What the screen can truthfully show of it is when.
    case working
    // Waiting for something that is coming: the store, the idle moment, the next sweep.
    case alive
    // Waited past where it should have finished, or stopped trying: it needs Dan.
    case stalled
    // Did not land, and why.
    case failed
    // Landed, or had nothing left to land.
    case finished
}

// One interrupted landing, as its journal names it, so an action can be aimed at exactly that landing.
struct LandingRef: Equatable, Hashable, Sendable {
    let runIdentity: String
    let sequence: Int
}

// The controls a standing outcome offers. Each pair is a way out of a state that otherwise stays for ever
// (L371, L111): trying the thing again, or giving up the thing that cannot be finished, with what giving it up
// changes said before it is done (L180).
enum LandingAction: Equatable, Hashable, Sendable {
    case trySavingAgain
    case discardUnsavedEdits
    case tryInterruptedLandingAgain(LandingRef)
    case discardInterruptedLanding(LandingRef)
    case tryUnreadableRecordAgain(path: String)
    case discardUnreadableRecord(path: String)

    var title: String {
        switch self {
        case .trySavingAgain: return "Try saving again"
        case .discardUnsavedEdits: return "Discard these unsaved edits"
        // One label for the same act on two records, and one for giving each up (#843).
        case .tryInterruptedLandingAgain, .tryUnreadableRecordAgain: return "Try again"
        case .discardInterruptedLanding, .discardUnreadableRecord: return "Discard"
        }
    }

    // A control that gives something up looks like one, and asks first with what it will change (L608).
    var isDestructive: Bool {
        switch self {
        case .discardUnsavedEdits, .discardInterruptedLanding, .discardUnreadableRecord: return true
        case .trySavingAgain, .tryInterruptedLandingAgain, .tryUnreadableRecordAgain: return false
        }
    }

    // The question the confirmation asks. The answer, what it will change, is derived from the state at the
    // moment it is asked (`UnsavedEditsDiscard`, `LandingRecovery.discardConsequence`,
    // `LandingJournals.discardConsequence`), never a fixed sentence.
    var confirmationTitle: String? {
        switch self {
        case .discardUnsavedEdits: return "Discard these unsaved edits?"
        case .discardInterruptedLanding: return "Discard the interrupted landing?"
        case .discardUnreadableRecord: return "Discard the landing record Overture couldn't read?"
        case .trySavingAgain, .tryInterruptedLandingAgain, .tryUnreadableRecordAgain: return nil
        }
    }
}

// What a landing in progress is landing, for the line that names it.
enum LandingWork: Equatable, Sendable {
    // The reader's results file, after a scout's read.
    case calendarResults
    // Calendar results kept because they had to wait, offered again by the sweep.
    case keptResults
    // An interrupted landing the idle recovery is finishing, named by when it first started.
    case interrupted(startedAt: Date)

    // The phrase for what is happening, which the stalled sentence is built on (`RunProgress.stalledLabel`).
    var doing: String {
        switch self {
        case .calendarResults: return "Landing the calendar results"
        case .keptResults: return "Landing calendar results that waited for the store"
        case .interrupted: return "Finishing the interrupted landing"
        }
    }
}

enum LandingOutcome: Equatable, Sendable {
    // In progress.
    case landing(LandingWork, startedAt: Date)
    case waitingBehind(holder: LandingSingleFlight.EntryPoint?)
    case landingLooksStuck(LandingWork, elapsed: String)

    // The sweep of kept calendar results (`ScoutExtractLanding.offerPending`).
    case keptResultsLanded(sets: Int)
    case keptResultsAlreadyLanded(at: Date)
    case keptResultsWaiting(sets: Int)
    case keptResultsStuck(sets: Int, over: TimeInterval)
    case keptResultsUnreadable([String])
    // A copy that landed and could not be removed, in the sentence the landing wrote (`LandingWaitCopy.copyNotRemoved`).
    case keptCopyNotRemoved(String)
    case judgedAgainstLess(labels: [String])

    // The idle recovery (`LandingRecovery`).
    case waitingForIdle(startedAt: Date)
    case landedByRecovery(startedAt: Date)
    case overtakenWhileInterrupted(startedAt: Date)
    case checkingCalendarsAgain(startedAt: Date)
    case recoveryNotFinished(startedAt: Date, why: String)
    case recordsUnreadable(why: String)
    case stoppedRetrying(LandingRef, startedAt: Date, attempts: Int, unlanded: Int)
    case recordUnreadable(path: String)
    case recordStillUnreadable(path: String, why: String)

    // The entry flush's standing state (`EntryFlushRecord`) and what its two actions did.
    case editsStuck(rows: [String], lastTryFailedAt: Date?)
    case editsSaved
    case editsDiscarded
    case editsDiscardedButStillNotSaving(why: String)

    // What the other standing actions did. A discarded landing's start is nil when the survey no longer knew it.
    case interruptedDiscarded(startedAt: Date?)
    case unreadableRecordDiscarded
    case retryNotRecorded(startedAt: Date, why: String)
    case unreadableRecordNotDiscarded(why: String)
    // The landing a Discard named had already been finished or cleared by the time it was pressed.
    case nothingLeftToDiscard

    var look: LandingLook {
        switch self {
        case .landing, .checkingCalendarsAgain:
            return .working
        case .waitingBehind, .keptResultsWaiting, .waitingForIdle, .recoveryNotFinished:
            return .alive
        case .landingLooksStuck, .keptResultsStuck, .stoppedRetrying, .editsStuck:
            return .stalled
        case .keptResultsUnreadable, .keptCopyNotRemoved, .judgedAgainstLess, .recordsUnreadable,
             .recordUnreadable, .recordStillUnreadable, .editsDiscardedButStillNotSaving, .retryNotRecorded,
             .unreadableRecordNotDiscarded:
            return .failed
        case .keptResultsLanded, .keptResultsAlreadyLanded, .landedByRecovery, .overtakenWhileInterrupted,
             .editsSaved, .editsDiscarded, .interruptedDiscarded, .unreadableRecordDiscarded, .nothingLeftToDiscard:
            return .finished
        }
    }

    var line: String {
        switch self {
        case .landing(.interrupted(let first), let startedAt):
            return "Finishing the landing that was interrupted at \(LandingWaitCopy.landedTime(first)). Started at "
                + "\(LandingWaitCopy.landedTime(startedAt))."
        case .landing(let work, let startedAt):
            return "\(work.doing). Started at \(LandingWaitCopy.landedTime(startedAt))."
        case .waitingBehind(let holder):
            return holder == .landingRecovery
                ? "Waiting for the interrupted landing to finish."
                : "Waiting for the landing in progress to finish."
        case .landingLooksStuck(let work, let elapsed):
            return RunProgress.stalledLabel(work.doing, elapsed: elapsed)
        case .keptResultsLanded(let sets):
            return LandingWaitCopy.keptResultsLanded(sets)
        case .keptResultsAlreadyLanded(let at):
            return LandingWaitCopy.keptCopyAlreadyLanded(at: at)
        case .keptResultsWaiting(let sets):
            return LandingWaitCopy.keptResultsWaiting(sets)
        case .keptResultsStuck(let sets, let over):
            return LandingWaitCopy.keptResultsStuck(sets, over: over)
        case .keptResultsUnreadable(let lines):
            return lines.joined(separator: " ")
        case .keptCopyNotRemoved(let sentence):
            return sentence
        case .judgedAgainstLess(let labels):
            return ScoutWarningCopy.degradedReads(labels)
        case .waitingForIdle(let startedAt):
            return LandingWaitCopy.interruptedWaiting(since: startedAt)
        case .landedByRecovery(let startedAt):
            return LandingWaitCopy.recovered(.landed(startedAt: startedAt, sources: 0)) ?? ""
        case .overtakenWhileInterrupted(let startedAt):
            return LandingWaitCopy.recovered(.retired(startedAt: startedAt, finding: .superseded(bySequence: 0))) ?? ""
        case .checkingCalendarsAgain(let startedAt):
            return LandingWaitCopy.recovered(.sweepRequested(startedAt: startedAt)) ?? ""
        case .recoveryNotFinished(let startedAt, let why):
            return LandingWaitCopy.recovered(.notFinished(startedAt: startedAt, why: why)) ?? ""
        case .recordsUnreadable(let why):
            return LandingWaitCopy.recovered(.recordsUnreadable(why: why)) ?? ""
        case .stoppedRetrying(_, let startedAt, let attempts, let unlanded):
            return LandingWaitCopy.recovered(.stoppedRetrying(startedAt: startedAt, attempts: attempts,
                                                              unlanded: unlanded)) ?? ""
        case .recordUnreadable:
            return "Overture couldn't read one of its landing records, so it can't tell whether that landing finished."
        case .recordStillUnreadable(_, let why):
            return "Overture still couldn't read that landing record (\(why)), so it can't tell whether that "
                + "landing finished."
        case .editsStuck(let rows, let lastTryFailedAt):
            let stuck = "Overture has twice been unable to save your recent edits, so scout results wait until "
                + "they are saved or discarded. Not yet saved: " + rows.joined(separator: ", ") + "."
            guard let lastTryFailedAt else { return stuck }
            return stuck + " Trying again at \(LandingWaitCopy.landedTime(lastTryFailedAt)) failed too."
        case .editsSaved:
            return "Your recent edits are saved, so scout results can land again."
        case .editsDiscarded:
            return "Overture discarded your unsaved edits, so scout results can land again."
        case .editsDiscardedButStillNotSaving(let why):
            return "Overture put your edits back but still couldn't save (\(why)), so the store itself is refusing "
                + "saves. Quit and reopen Overture; if this keeps happening, something's wrong with the local store."
        case .interruptedDiscarded(let startedAt):
            guard let startedAt else { return "Overture discarded the interrupted landing." }
            return "Overture discarded the landing that was interrupted at \(LandingWaitCopy.landedTime(startedAt))."
        case .unreadableRecordDiscarded:
            return "Overture discarded the landing record it couldn't read."
        case .retryNotRecorded(let startedAt, let why):
            return "Overture couldn't set the landing interrupted at \(LandingWaitCopy.landedTime(startedAt)) to be "
                + "tried again (\(why))."
        case .unreadableRecordNotDiscarded(let why):
            return "Overture couldn't discard the landing record it couldn't read (\(why))."
        case .nothingLeftToDiscard:
            return "That landing had already been finished or cleared, so there was nothing left to discard."
        }
    }

    // The controls this outcome offers, in the order they are drawn: the one that keeps the work first, the one
    // that gives it up last (L609).
    var actions: [LandingAction] {
        switch self {
        case .editsStuck:
            return [.trySavingAgain, .discardUnsavedEdits]
        case .stoppedRetrying(let ref, _, _, _):
            return [.tryInterruptedLandingAgain(ref), .discardInterruptedLanding(ref)]
        case .recordUnreadable(let path):
            return [.tryUnreadableRecordAgain(path: path), .discardUnreadableRecord(path: path)]
        // What a "Try again" that failed said: the record still stands above it with the two controls, so they
        // are not drawn twice.
        case .recordStillUnreadable:
            return []
        default:
            return []
        }
    }
}

// #4338: the lines one background event leaves on the landing line, from what that event returned. Ordered for
// the reader (L609): what needs Dan first, then what is still coming, then what finished.
extension LandingOutcome {
    static func ordered(_ outcomes: [LandingOutcome]) -> [LandingOutcome] {
        let rank: [LandingLook: Int] = [.stalled: 0, .failed: 1, .working: 2, .alive: 3, .finished: 4]
        return outcomes.enumerated().sorted { a, b in
            let ra = rank[a.element.look] ?? 5, rb = rank[b.element.look] ?? 5
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    // One sweep of kept calendar results, as the lines it leaves. Nothing when it did nothing worth saying.
    static func from(offered: ScoutExtractLanding.Offered, degradedLabels: [String]) -> [LandingOutcome] {
        var out: [LandingOutcome] = []
        if !offered.landed.isEmpty { out.append(.keptResultsLanded(sets: offered.landed.count)) }
        out.append(contentsOf: offered.alreadyLanded.map(LandingOutcome.keptResultsAlreadyLanded(at:)))
        if offered.stillWaiting > 0 { out.append(.keptResultsWaiting(sets: offered.stillWaiting)) }
        if offered.stuck > 0 { out.append(.keptResultsStuck(sets: offered.stuck, over: offered.stuckAfter)) }
        if !offered.unreadable.isEmpty { out.append(.keptResultsUnreadable(offered.unreadable)) }
        out.append(contentsOf: offered.copiesLeftBehind.map(LandingOutcome.keptCopyNotRemoved))
        if !degradedLabels.isEmpty { out.append(.judgedAgainstLess(labels: degradedLabels)) }
        return ordered(out)
    }

    // What a Discard on an interrupted landing says, from whether it discarded anything.
    static func afterDiscard(discarded: Bool, startedAt: Date?) -> LandingOutcome {
        discarded ? .interruptedDiscarded(startedAt: startedAt) : .nothingLeftToDiscard
    }

    // One step of the idle recovery, as the line it leaves, or nil when there is nothing worth saying (a spent
    // record cleared). The standing case, a landing it stopped trying, carries the landing it is about, so its
    // two actions can be aimed at it.
    static func from(recovered: LandingRecovery.Recovered, ref: LandingRef?) -> LandingOutcome? {
        switch recovered {
        case .landed(let startedAt, _): return .landedByRecovery(startedAt: startedAt)
        case .retired(let startedAt, .superseded): return .overtakenWhileInterrupted(startedAt: startedAt)
        case .retired: return nil
        case .sweepRequested(let startedAt): return .checkingCalendarsAgain(startedAt: startedAt)
        case .notFinished(let startedAt, let why): return .recoveryNotFinished(startedAt: startedAt, why: why)
        case .recordsUnreadable(let why): return .recordsUnreadable(why: why)
        case .stoppedRetrying(let startedAt, let attempts, let unlanded):
            guard let ref else { return nil }
            return .stoppedRetrying(ref, startedAt: startedAt, attempts: attempts, unlanded: unlanded)
        }
    }

    // The landings that need Dan, standing until he acts or they clear: every landing the recovery stopped
    // trying, every landing record it could not read, and the entry flush refused twice in a row. A landing the
    // recovery is still going to finish is said too, so the wait is visible (decision 5).
    static func standing(interrupted: [LandingRecovery.Interrupted], unreadable: [String],
                         editsStuck: (rows: [String], lastTryFailedAt: Date?)?) -> [LandingOutcome] {
        var out: [LandingOutcome] = []
        if let editsStuck {
            out.append(.editsStuck(rows: editsStuck.rows, lastTryFailedAt: editsStuck.lastTryFailedAt))
        }
        for item in interrupted {
            if case .stoppedRetrying(let attempts) = item.finding {
                out.append(.stoppedRetrying(LandingRef(runIdentity: item.journal.runIdentity,
                                                       sequence: item.journal.sequence),
                                            startedAt: item.startedAt, attempts: attempts,
                                            unlanded: item.unlanded.count))
            }
        }
        out.append(contentsOf: unreadable.map { LandingOutcome.recordUnreadable(path: $0) })
        if let waiting = interrupted.first(where: { $0.finding == .replay || $0.finding == .sweep }) {
            out.append(.waitingForIdle(startedAt: waiting.startedAt))
        }
        return ordered(out)
    }
}

// #4338: the line a landing in progress shows at a given moment. Waiting its turn in the landing queue, it says
// what it waits for and its counter ticks, since the screen can redraw while it waits. Otherwise it shows its start
// time (the honest limit above), until the window passes, when it says it looks stuck with how long it has run.
extension LandingWork {
    // Which holder of the store this work is, so the line can tell whether it is the one waiting.
    var entryPoint: LandingSingleFlight.EntryPoint {
        switch self {
        case .calendarResults, .keptResults: return .scoutExtractIngest
        case .interrupted: return .landingRecovery
        }
    }
}

extension LandingOutcome {
    static func live(_ work: LandingWork, startedAt: Date, now: Date, waiting: Bool,
                     holder: LandingSingleFlight.EntryPoint?,
                     timeout: TimeInterval = RunTimeouts.landing) -> (outcome: LandingOutcome, counter: String?) {
        if waiting {
            return (.waitingBehind(holder: holder), RunProgress.elapsedLabel(since: startedAt, now: now))
        }
        if case .stalled(let elapsed) = RunProgress.liveness(since: startedAt, now: now, timeout: timeout) {
            return (.landingLooksStuck(work, elapsed: elapsed), nil)
        }
        return (.landing(work, startedAt: startedAt), nil)
    }
}

// #4338: the landing outcomes a scout's own summary says, in the same five states as the landing line, so a refusal
// and a landing that had nothing new to add never look alike there either. nil for a section that is not about a
// landing (a source that could not be checked, a calendar that went quiet), which keeps its own treatment.
extension ScoutWarnings.Section {
    var look: LandingLook? {
        switch self {
        // Could not be saved (retried or not), refused because recent edits could not be saved first, not attempted
        // because the store refused a save, not reverted, and the copy or record a landing could not keep.
        case .saveFailed, .landingStopped: return .failed
        // Not landed yet, kept, and offered again: coming, not failed.
        case .notLandedYet: return .alive
        // Superseded by a newer run, and already landed: nothing was lost and nothing is left to do.
        case .superseded, .alreadyLanded: return .finished
        case .storeUnreadable, .extractLaunchFailure, .readerFinishedEmpty, .failures, .unqueued, .silentlyEmptyFeed,
             .pastClientList:
            return nil
        }
    }
}
