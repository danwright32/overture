import Foundation
import SwiftData
import CoreGraphics

// #4335 (A6, the recovery): finishing a scout landing that was interrupted, automatically, when Dan is away.
//
// A landing writes the store one source at a time. A crash, a quit, or a store that refuses a save part way
// leaves some sources landed and others not, and its journal (`LandingJournal`, written before anything was
// applied and removed once every save went through) still on disk. Each source's one save carries its shows AND
// its bookkeeping (#4335's moved save), so the store says exactly which sources that landing finished: the ones
// whose `lastTouchedSequence` is the journal's sequence. The recovery reads the two together.
//
// WHAT IT DOES WITH EACH JOURNAL (`survey`, read only, then `recoverNext`, one at a time):
//
//   finished     its record says it landed: only the journal's removal failed. Retired.
//   superseded   every source it named has since been touched by a LATER run (a check, a failed read, a newer
//                landing): its reading is the older one, a late event, and the store already holds newer truth
//                (L23). Retired, and an ingest's kept copy with it, by name ("superseded by run <sequence>").
//   replay       an ingest with sources still to land (or only its closing step left): landed again from its
//                OWN copy (never the reader's file), under its own sequence and its own `now` (L37). Sources the
//                interrupted attempt landed are recognised and not counted twice (`ScoutExtractIngest`).
//   sweep        a runScout landing with sources still to land, or only its tail: the daily watch-only sweep is
//                asked for, which reads every active source again (free), lands them with a higher sequence and
//                runs the tail, after which this journal is superseded. A runScout reading is re-read rather
//                than replayed, because the pages it read are not kept and the network has moved on.
//   copyMissing  an ingest whose copy is gone, or is not the results this journal describes: refused by name,
//                never landed from anything else.
//   stoppedRetrying  `attemptCap` attempts have started and none finished it. Left, visible, for A10 (#4338) to
//                offer "Try again" and "Discard" on, with the consequence derived from `unlanded`.
//
// WHEN (decision 5): only at idle, and only through the landing queue (A13). `RecoveryIdle` is the predicate;
// RootView asks it on a timer. A Run press that arrives first wins: its sources then carry a higher sequence,
// so they read as superseded here. An ingest replay holds the store as `.landingRecovery`, so a Run press
// waiting behind it says it waits for the interrupted landing.
//
// ATTEMPTS ARE COUNTED BEFORE THEY ARE MADE, on the landing's record (`LandingRun.attemptCount`), in a save of
// their own: an attempt that ends the process still counts, so a landing that crashes the app every time it is
// finished stops being tried after `attemptCap` launches instead of on every one (L365).
@MainActor
enum LandingRecovery {
    static let attemptCap = 3

    enum Finding: Equatable, Sendable {
        case finished
        case superseded(bySequence: Int)
        case replay
        case sweep
        case copyMissing(why: String)
        case stoppedRetrying(attempts: Int)
    }

    // One interrupted landing, judged against the store.
    struct Interrupted: Equatable, Sendable {
        let journal: LandingJournal
        let finding: Finding
        // The journal's sources the store does not say this landing (or a later run) reached, in its order.
        let unlanded: [String]
        // When the interrupted landing started, as its journal recorded it.
        var startedAt: Date { journal.now }
    }

    // What one `recoverNext` did, for the line Dan is told. nil from `recoverNext` means nothing was pending.
    enum Recovered: Equatable, Sendable {
        // The landing interrupted at `startedAt` is finished: its remaining sources landed now.
        case landed(startedAt: Date, sources: Int)
        // A journal whose work was already done (its record landed, or every source was overtaken). Removed.
        case retired(startedAt: Date, finding: Finding)
        // The sweep that will finish a runScout landing was asked for.
        case sweepRequested(startedAt: Date)
        // Tried, and not finished: why, by name. Left for the next idle moment, or stopped at the cap.
        case notFinished(startedAt: Date, why: String)
        case stoppedRetrying(startedAt: Date, attempts: Int, unlanded: Int)
        // The folder of landing records could not be listed, so nothing can be judged: no landing and no time
        // to name, and a line that reads the same every minute, so it is said once (L11, L36).
        case recordsUnreadable(why: String)
    }

    // MARK: - judging (read only)

    // Every pending journal, oldest first, judged. Quarantined and left-in-place journals are reported by
    // `LandingJournals.list()` itself (to the handoff read failures); they are not landings this can judge.
    static func survey(journals: LandingJournals, pending: PendingScoutIngests,
                       in context: ModelContext,
                       // The watchlist read, injected so a test can count it.
                       readSources: (ModelContext) throws -> [WatchedSource] = {
                           try $0.fetch(FetchDescriptor<WatchedSource>())
                       }) throws -> [Interrupted] {
        // The journals first: on the ordinary day there are none, and that answer costs a directory listing,
        // never a read of the watchlist.
        let pendingJournals = try journals.list().compactMap { listed -> LandingJournal? in
            guard case .pending(let journal, _) = listed else { return nil }
            return journal
        }
        guard !pendingJournals.isEmpty else { return [] }
        let sources = try readSources(context)
        let byId = Dictionary(sources.map { ($0.sourceId, $0) }, uniquingKeysWith: { first, _ in first })
        return try pendingJournals.map { try judge($0, sources: byId, pending: pending, in: context) }
    }

    static func judge(_ journal: LandingJournal, sources: [String: WatchedSource], pending: PendingScoutIngests,
                      in context: ModelContext) throws -> Interrupted {
        let isIngest = journal.entryPoint == LandingSingleFlight.EntryPoint.scoutExtractIngest.rawValue
        // The rows the journal named that still exist. For a sweep, only those still watched: the watch-only sweep
        // that finishes it reads active sources only, so a source switched off since holds nothing up. An ingest
        // keeps every row, active or not: its results were read while the source was watched, and whether they
        // land is the ingest's to decide from its own copy, never the recovery's to discard (L5).
        let rows = journal.sources.compactMap { sources[$0.sourceId] }
        let named = isIngest ? rows : rows.filter { $0.isActive }
        let unlanded = named.filter { $0.lastTouchedSequence < journal.sequence }.map(\.sourceId)
        let laterTouches = named.map(\.lastTouchedSequence).filter { $0 > journal.sequence }
        let overtaken = !named.isEmpty && laterTouches.count == named.count
        let record = try LandingRun.record(journal.runIdentity, sequence: journal.sequence, in: context)
        func found(_ finding: Finding) -> Interrupted {
            Interrupted(journal: journal, finding: finding, unlanded: unlanded)
        }
        if record?.landedAt != nil { return found(.finished) }
        // A sweep with no watched source left has nothing for any sweep to finish. An ingest whose rows are all
        // gone still goes to its replay below, which lands nothing for an id no row answers to and retires its
        // copy only once that landing has finished.
        if !isIngest && named.isEmpty { return found(.finished) }
        if overtaken { return found(.superseded(bySequence: laterTouches.min() ?? journal.sequence)) }
        if let record, record.attemptCount >= attemptCap { return found(.stoppedRetrying(attempts: record.attemptCount)) }
        guard isIngest else { return found(.sweep) }
        if let why = copyRefusal(journal, pending: pending) { return found(.copyMissing(why: why)) }
        return found(.replay)
    }

    // Why an ingest journal's kept copy cannot be landed, or nil when it can: the copy must be there, and its
    // bytes must hash to the identity the journal names (L420), so a landing is only ever finished from the very
    // results it started with.
    static func copyRefusal(_ journal: LandingJournal, pending: PendingScoutIngests) -> String? {
        guard let hash = journal.resultsCopy else {
            return "the landing record names no kept copy of its results"
        }
        guard hash == journal.runIdentity else {
            return "the kept copy it names is not the results this landing started with"
        }
        do {
            let entry = try pending.entry(hash)
            let copy = try pending.results(entry)
            guard PendingScoutIngests.contentHash(of: copy.data) == hash else {
                return "the kept copy of its results at \(pending.resultsURL(hash).path) has changed since"
            }
            return nil
        } catch {
            return "the kept copy of its results at \(pending.resultsURL(hash).path) could not be read ("
                + HandoffDecodeFailure.describe(error) + ")"
        }
    }

    // MARK: - acting (one at a time)

    // Finishes, or retires, the OLDEST interrupted landing that has work, and says what it did. Retiring a
    // finished or superseded journal is cheap and is done for all of them first, so the one landing that needs
    // the store is never queued behind bookkeeping. `sweep` asks RootView for the watch-only sweep.
    static func recoverNext(journals: LandingJournals, pending: PendingScoutIngests,
                            clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                            landings: LandingSingleFlight = .shared,
                            now: Date = Date(),
                            // Asks for the watch-only sweep and answers whether it STARTED.
                            sweep: () -> Bool,
                            saveAttempt: (ModelContext) throws -> Void = { try $0.save() },
                            // Each replayed source's own save, injected so a test can make a recovery fail.
                            saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
                            movementLog: any FeedMovementLog.Sink = FeedMovementLog.file,
                            // L459: called with the run identity as a replay starts and nil as it ends, so the
                            // stall watchdog can record the replay's holds as idle work (`IdleWorkBox`).
                            replaying: (Int?) -> Void = { _ in },
                            // What a caller already surveyed in the same main actor turn, so an idle minute with
                            // a landing waiting lists the journals and reads each kept copy once, not twice.
                            surveyed: [Interrupted]? = nil,
                            into context: ModelContext) async -> Recovered? {
        let found: [Interrupted]
        if let surveyed {
            found = surveyed
        } else {
            do {
                found = try survey(journals: journals, pending: pending, in: context)
            } catch {
                return .recordsUnreadable(why: HandoffDecodeFailure.describe(error))
            }
        }
        var retired: Recovered?
        for item in found {
            switch item.finding {
            case .finished, .superseded:
                retire(item.journal, journals: journals, pending: pending)
                retired = retired ?? .retired(startedAt: item.startedAt, finding: item.finding)
            default:
                continue
            }
        }
        // A missing copy is an attempt too: counted, so it reaches the cap and stops being said every minute.
        guard let next = found.first(where: {
            switch $0.finding {
            case .replay, .sweep, .copyMissing: return true
            default: return false
            }
        }) else {
            if let stopped = found.first(where: { if case .stoppedRetrying = $0.finding { return true }; return false }),
               case .stoppedRetrying(let attempts) = stopped.finding {
                return .stoppedRetrying(startedAt: stopped.startedAt, attempts: attempts,
                                        unlanded: stopped.unlanded.count)
            }
            return retired
        }
        // Counted and saved BEFORE the attempt, so an attempt that ends the process still counts, and a sweep is
        // never running while the line says its attempt could not be recorded (L11).
        let record = LandingRun.begin(runIdentity: next.journal.runIdentity, sequence: next.journal.sequence,
                                      entryPoint: LandingSingleFlight.EntryPoint(rawValue: next.journal.entryPoint)
                                          ?? .scoutExtractIngest,
                                      startedAt: next.journal.now, in: context)
        let inserted = context.insertedModelsArray.contains { $0.persistentModelID == record.persistentModelID }
        record.attemptCount += 1
        do {
            try saveAttempt(context)
        } catch {
            // Put back exactly what this step wrote, through the one revert the landing path uses (never
            // `rollback()`): a row it inserted leaves, a count it raised goes back, so no later save carries a
            // half recorded attempt.
            _ = LandingRevert.revert(LandingRevert.WriteSet(changed: inserted ? [] : [record],
                                                        inserted: inserted ? [record] : [], deleted: []),
                                 in: context)
            return .notFinished(startedAt: next.startedAt, why: "its attempt could not be recorded ("
                                + HandoffDecodeFailure.describe(error) + ")")
        }
        let replayed: Recovered
        switch next.finding {
        case .sweep:
            guard sweep() else {
                // A sweep that could not start (another run, the reader) uses up nothing of the cap: the count
                // just recorded is taken back in a save of its own. If that save fails too, the count stands,
                // which errs toward stopping rather than toward retrying for ever.
                record.attemptCount -= 1
                do {
                    try saveAttempt(context)
                } catch {
                    _ = LandingRevert.revert(LandingRevert.WriteSet(changed: [record], inserted: [], deleted: []),
                                             in: context)
                }
                return .notFinished(startedAt: next.startedAt, why: "the scout that would finish it could not start yet")
            }
            return .sweepRequested(startedAt: next.startedAt)
        case .copyMissing(let why):
            replayed = .notFinished(startedAt: next.startedAt, why: why)
        default:
            replaying(next.journal.sequence)
            replayed = await replay(next, journals: journals, pending: pending, clients: clients, history: history,
                                    blocked: blocked, landings: landings, now: now, saveSource: saveSource,
                                    movementLog: movementLog, into: context)
            replaying(nil)
        }
        // "It will try again" is said only while there is an attempt left to make (L703).
        if case .notFinished = replayed, record.attemptCount >= attemptCap {
            return .stoppedRetrying(startedAt: next.startedAt, attempts: record.attemptCount,
                                    unlanded: next.unlanded.count)
        }
        return replayed
    }

    // An ingest landed again from its own copy, under its own sequence and `now`, holding the store as the
    // recovery. The landing retires its journal and removes its copy itself when every save goes through.
    private static func replay(_ item: Interrupted, journals: LandingJournals, pending: PendingScoutIngests,
                               clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                               landings: LandingSingleFlight, now: Date,
                               saveSource: @escaping (ModelContext) throws -> Void,
                               movementLog: any FeedMovementLog.Sink,
                               into context: ModelContext) async -> Recovered {
        let journal = item.journal
        let copy: (data: Data, results: ScoutExtractResults)
        do {
            copy = try pending.results(try pending.entry(journal.runIdentity))
        } catch {
            return .notFinished(startedAt: item.startedAt, why: "the kept copy of its results could not be read ("
                                + HandoffDecodeFailure.describe(error) + ")")
        }
        // The journal's `now` stamps what lands (its results were read then, L37); what is still UPCOMING is
        // judged on the day the replay runs, so a night that passed while it waited is not a show to come.
        let landed = await ScoutExtractLanding.land(
            copy.data, copy.results, sequence: journal.sequence, clients: clients, history: history, blocked: blocked,
            today: QueueModel.easternToday(now), now: journal.now, landings: landings,
            holdingAs: .landingRecovery, pending: pending, journals: journals, saveSource: saveSource,
            movementLog: movementLog, recoveredAt: now, into: context)
        let outcome = landed.outcome
        if outcome.alreadyLandedAt != nil {
            retire(journal, journals: journals, pending: pending)
            return .retired(startedAt: item.startedAt, finding: .finished)
        }
        if let why = reason(outcome) { return .notFinished(startedAt: item.startedAt, why: why) }
        return .landed(startedAt: item.startedAt, sources: item.unlanded.count)
    }

    // Why a replay did not finish, as a clause the recovery's sentence carries in parentheses, or nil when it
    // finished. The landing's own warnings are whole sentences written for a scout Dan started, so the clause
    // names the cause instead (L11).
    static func reason(_ outcome: ScoutService.Outcome) -> String? {
        if outcome.notLandedYet != nil { return "another landing was holding the store" }
        switch outcome.landingStop {
        case .recentEditsUnsaved?: return "your recent edits could not be saved first"
        case .journalNotWritten(let why)?: return "its landing record could not be written: \(why)"
        case .resultsNotKept(let why)?: return "a copy of its results could not be kept: \(why)"
        case .storeRefusedASave(let source)?: return "the store refused to save \(source)"
        case .notReverted(let source, _)?: return "\(source) could not be put back after its save failed"
        case nil: return outcome.saveFailed ? "a save failed" : nil
        }
    }

    // The step that retires a journal is the one that deletes its kept copy (L5): the copy is the journal's
    // results, and nothing else may delete it while the journal can still be finished.
    static func retire(_ journal: LandingJournal, journals: LandingJournals, pending: PendingScoutIngests) {
        journals.retire(journal)
        if let hash = journal.resultsCopy {
            do {
                try pending.remove(hash)
            } catch {
                journals.readFailures.record(file: PendingScoutIngests.folderName + "/" + hash,
                                             reason: "could not be removed after its landing was finished: "
                                                 + HandoffDecodeFailure.describe(error))
            }
        }
    }
}

// #4335 (A6, decision 5): "idle", as the plan defines it. Every term is read by the caller and handed in, so the
// rule is one pure function a test drives term by term.
enum RecoveryIdle {
    // No keyboard or mouse input to the Mac for this long. Measured before relying on it (L82): on this Mac on
    // 2026-10-03, `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kCGAnyInputEventType)`
    // read 0.04 s while the pointer was moving and climbed with the wall clock between key presses (15.38 s,
    // then 20.38 s five seconds later, then 0.31 s after a key).
    static let quietFor: TimeInterval = 120

    enum Verdict: Equatable, Sendable {
        case idle(inputQuietFor: TimeInterval)
        case landingInProgress
        case scoutRunning
        case inputRecent(secondsAgo: TimeInterval)
        // The system did not give a reading, which is never read as idle (L42).
        case inputUnmeasured
    }

    // The system's own reading of how long ago the last keyboard or mouse input to this Mac was, from any app.
    static func secondsSinceInput() -> TimeInterval? {
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    static func judge(landingHeld: Bool, scoutRunning: Bool, secondsSinceInput: TimeInterval?) -> Verdict {
        if landingHeld { return .landingInProgress }
        if scoutRunning { return .scoutRunning }
        guard let seconds = secondsSinceInput, seconds.isFinite, seconds >= 0 else { return .inputUnmeasured }
        return seconds >= quietFor ? .idle(inputQuietFor: seconds) : .inputRecent(secondsAgo: seconds)
    }
}
