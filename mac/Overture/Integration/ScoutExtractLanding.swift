import Foundation
import SwiftData

// #4330 (A13, the L665 correction): an ingest of the detached read's results FILE, which keeps a copy of
// what it is holding the moment it has to wait for the store, and the sweep that offers every kept copy
// again.
//
// `ScoutExtractIngest.ingest` lands decoded results; this is the layer that knows they came from a file
// the next extract run will rewrite. So it is where the refusal is made to lose nothing: before the
// ingest waits, the exact bytes it decoded are copied by content hash with the run's sequence
// (`PendingScoutIngests`); once it lands the copy is removed; refused at its deadline the copy stays, and
// `offerPending` offers it again, from the copy and never from `defaultURL`, at launch and at the end of
// every landing.
// #4336 (A7): whether results with this identity have already landed. A parameter of the landing whose
// default is the real lookup on `LandingRun`. `bypassedForMeasurement` exists for one reason: a probe that
// re-lands ONE frozen results file every round would otherwise measure a refusal from the second round on
// (the 2026-09-29 decision on #4336). It is reachable from test code only: AlreadyLandedBypassIsTestOnlyTests
// fails if any app file outside this one names it or builds a check of its own.
struct AlreadyLandedCheck: Sendable {
    // When the results with this identity first landed, nil when they have not, or a throw when the record
    // cannot be read, which is neither (L215).
    let landedAt: @Sendable @MainActor (String, ModelContext) throws -> Date?

    init(_ landedAt: @escaping @Sendable @MainActor (String, ModelContext) throws -> Date?) {
        self.landedAt = landedAt
    }

    static let lookUp = AlreadyLandedCheck { identity, context in try LandingRun.landedAt(identity, in: context) }
    static let bypassedForMeasurement = AlreadyLandedCheck { _, _ in nil }
}

// #4336 (A7): the identity of the results a landing holds, and the check to judge it by. Handed to the ingest
// by this layer only, because only this layer holds the bytes the identity is the hash of.
struct LandedResultsIdentity: Sendable {
    let contentHash: String
    let check: AlreadyLandedCheck
}

@MainActor
enum ScoutExtractLanding {
    // The copies whose ingest is in flight in THIS process right now, so the sweep never offers a copy a
    // second time while a landing of it is still in the queue. COUNTED per content hash, not a set: two
    // landings of identical bytes can overlap (a fresh ingest and an offer of its kept copy), and the first
    // to finish must not un-mark the hash while the other is still queued.
    private static var inFlight: [String: Int] = [:]

    // `sequence` is nil for a fresh file (the ingest mints one) and the kept sequence for a copy offered
    // again, whose copy is then already recorded.
    static func land(_ data: Data, _ results: ScoutExtractResults, sequence: Int? = nil,
                     clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                     today: String = QueueModel.easternToday(), now: Date = Date(),
                     landings: LandingSingleFlight = .shared,
                     priority: LandingSingleFlight.Priority = .scout,
                     pending: PendingScoutIngests = .live,
                     alreadyLanded: AlreadyLandedCheck = .lookUp,
                     saveClosing: (ModelContext) throws -> Void = { try $0.save() },
                     // #4334: the landing's entry flush, injected so a test can make it refuse.
                     saveEntry: (ModelContext) throws -> Void = { try $0.save() },
                     // #4335 (A6): the landing journal folder, handed straight to the ingest. RootView passes
                     // `.live`; nil keeps none (a test whose subject is not the journal).
                     journals: LandingJournals? = nil,
                     into context: ModelContext) async -> Landed {
        let hash = PendingScoutIngests.contentHash(of: data)
        var kept = sequence != nil
        var waited = false
        var copyFailure: String?
        inFlight[hash, default: 0] += 1
        defer {
            inFlight[hash, default: 1] -= 1
            if inFlight[hash] == 0 { inFlight[hash] = nil }
        }
        // #4336 (A7): results that already landed are refused here, before the read phase spends anything,
        // as their own outcome carrying the first landing's time. The ingest asks again once it holds the
        // store, because this answer was formed before the store was held (L157). A record that cannot be
        // read is left to that second asking, which lands the results and says the read failed.
        if let landedAt = try? alreadyLanded.landedAt(hash, context) {
            var refused = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
            refused.alreadyLandedAt = landedAt
            return removingTheCopy(of: hash, kept: kept, after: refused, pending: pending)
        }
        func keepACopy(_ runSequence: Int) {
            guard !kept else { return }
            do {
                try pending.record(data, sequence: runSequence, now: now)
                kept = true
            } catch {
                copyFailure = String(describing: error)
            }
        }
        var outcome = await ScoutExtractIngest.ingest(
            results, clients: clients, history: history, blocked: blocked, today: today, now: now,
            landings: landings, priority: priority,
            identity: LandedResultsIdentity(contentHash: hash, check: alreadyLanded),
            sequence: sequence,
            sequenceFloor: { pending.highestSequence },
            onWait: { runSequence in
                waited = true
                keepACopy(runSequence)
            },
            saveClosing: saveClosing,
            saveEntry: saveEntry,
            // #4334 (A5, L371): a landing the entry flush refused applied nothing, so its results are kept
            // by content hash, exactly as a landing that waited is, and land once the edits are saved.
            onRefused: { keepACopy($0) },
            journals: journals,
            into: context)
        if outcome.notLandedYet != nil {
            // The refusal's own sentence says a copy was kept. When it was not, that sentence is false, so
            // it is replaced by one that names what failed and where the results still are.
            // L11: three cases, three sentences. A copy that was kept is what the refusal already says; a copy
            // that FAILED names its failure; and an ingest stopped before it ever waited attempted no copy at
            // all, so it says where its results still are rather than blaming a copy nobody tried to write.
            // The sentence comes from what HAPPENED: whether it waited, whether it was stopped or refused, and
            // whether a copy was attempted.
            if !kept {
                let stopped = outcome.notLandedYet == LandingWaitCopy.ingestCancelled
                if !waited {
                    outcome.notLandedYet = LandingWaitCopy.ingestStoppedBeforeItWaited
                } else {
                    let why = copyFailure ?? "no copy was written"
                    outcome.notLandedYet = stopped ? LandingWaitCopy.ingestCancelledWithoutACopy(why)
                                                   : LandingWaitCopy.ingestRefusedWithoutACopy(why)
                }
            }
            return Landed(outcome: outcome, copyLeftBehind: nil)
        }
        // #4334: a landing that stopped, or never started, keeps its copy (below); when that copy could not be
        // written, the results are still in the reader's file, which is said.
        if let copyFailure, outcome.landingStop != nil, !kept {
            outcome.notLandedYet = ScoutWarningCopy.stoppedWithoutACopy(copyFailure)
        }
        return removingTheCopy(of: hash, kept: kept, after: outcome, pending: pending)
    }

    // L5, L665: removed only once the save carrying these results has succeeded. A failed save means
    // they may never have reached disk, and the copy is then the only record of them, so it stays and
    // the sweep offers it again. #4336: results that had already landed have nothing left to offer, so
    // their copy goes too. #4334: a landing that stopped, or never started, before every source in it had
    // landed keeps its copy, like a failed save.
    private static func removingTheCopy(of hash: String, kept: Bool, after outcome: ScoutService.Outcome,
                                        pending: PendingScoutIngests) -> Landed {
        if kept && !outcome.saveFailed && outcome.landingStop == nil {
            do {
                try pending.remove(hash)
            } catch {
                // Landed, and the copy could not be removed, so the sweep will offer it again (#4336: and
                // it will then be refused as already landed). Said rather than left to happen.
                return Landed(outcome: outcome,
                              copyLeftBehind: LandingWaitCopy.copyNotRemoved(String(describing: error)))
            }
        }
        return Landed(outcome: outcome, copyLeftBehind: nil)
    }

    // The ingest's outcome, and the one thing only this layer can know went wrong: a copy that landed and
    // could not be removed afterwards.
    struct Landed {
        var outcome: ScoutService.Outcome
        var copyLeftBehind: String?
    }

    // What one sweep did, for the line Dan is told.
    struct Offered: Equatable {
        var landed: [ScoutService.Outcome] = []
        // #4336 (A7): copies whose results had already landed, by when they first landed. Removed, never
        // counted as landing now (L11).
        var alreadyLanded: [Date] = []
        var stillWaiting = 0
        // Older than one scout interval and still not landed: STUCK, not waiting (L665).
        var stuck = 0
        var unreadable: [String] = []
        var copiesLeftBehind: [String] = []
        // The age past which a copy counted as stuck, carried so the sentence says the same interval.
        var stuckAfter: TimeInterval = ScoutSchedule.defaultInterval

        var isEmpty: Bool {
            landed.isEmpty && alreadyLanded.isEmpty && stillWaiting == 0 && stuck == 0 && unreadable.isEmpty && copiesLeftBehind.isEmpty
        }
    }

    // Every kept copy, offered again from its copy, oldest first. A copy whose sources a later run has
    // already landed is set aside by the ingest's own re-validation, because it carries its original
    // sequence; it still counts as landed here, since there is nothing left of it to offer.
    static func offerPending(clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                             now: Date = Date(),
                             stuckAfter: TimeInterval = ScoutSchedule.defaultInterval,
                             landings: LandingSingleFlight = .shared,
                             pending: PendingScoutIngests = .live,
                             saveClosing: (ModelContext) throws -> Void = { try $0.save() },
                             // #4335: handed to every landing it makes, as `land` takes it.
                             journals: LandingJournals? = nil,
                             into context: ModelContext) async -> Offered {
        var offered = Offered(stuckAfter: stuckAfter)
        let listed: [PendingScoutIngests.Listed]
        do {
            listed = try pending.list()
        } catch {
            offered.unreadable.append(LandingWaitCopy.pendingUnreadable(path: pending.directory.path,
                                                                        why: String(describing: error)))
            return offered
        }
        for item in listed {
            switch item {
            case .unreadable(let path, let why):
                offered.unreadable.append(LandingWaitCopy.pendingUnreadable(path: path, why: why))
            case .entry(let entry):
                guard inFlight[entry.contentHash] == nil else { continue }
                let copy: (data: Data, results: ScoutExtractResults)
                do {
                    copy = try pending.results(entry)
                } catch {
                    offered.unreadable.append(LandingWaitCopy.pendingUnreadable(
                        path: pending.resultsURL(entry.contentHash).path, why: String(describing: error)))
                    continue
                }
                let landed = await land(copy.data, copy.results, sequence: entry.sequence,
                                        clients: clients, history: history, blocked: blocked, now: now,
                                        landings: landings, pending: pending, saveClosing: saveClosing,
                                        journals: journals, into: context)
                let outcome = landed.outcome
                if let left = landed.copyLeftBehind { offered.copiesLeftBehind.append(left) }
                if let landedAt = outcome.alreadyLandedAt {
                    offered.alreadyLanded.append(landedAt)
                } else if outcome.notLandedYet == nil && !outcome.saveFailed && outcome.landingStop == nil {
                    offered.landed.append(outcome)
                } else if now.timeIntervalSince(entry.recordedAt) > stuckAfter {
                    offered.stuck += 1
                } else {
                    offered.stillWaiting += 1
                }
            }
        }
        return offered
    }
}
