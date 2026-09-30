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
@MainActor
enum ScoutExtractLanding {
    // The copies whose ingest is waiting in THIS process right now, so the sweep never offers a copy a
    // second time while its first offer is still in the queue.
    private static var waiting: Set<String> = []

    // `sequence` is nil for a fresh file (the ingest mints one) and the kept sequence for a copy offered
    // again, whose copy is then already recorded.
    static func land(_ data: Data, _ results: ScoutExtractResults, sequence: Int? = nil,
                     clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                     today: String = QueueModel.easternToday(), now: Date = Date(),
                     landings: LandingSingleFlight = .shared,
                     priority: LandingSingleFlight.Priority = .scout,
                     pending: PendingScoutIngests = .live,
                     saveClosing: (ModelContext) throws -> Void = { try $0.save() },
                     into context: ModelContext) async -> Landed {
        let hash = PendingScoutIngests.contentHash(of: data)
        var kept = sequence != nil
        var copyFailure: String?
        waiting.insert(hash)
        defer { waiting.remove(hash) }
        var outcome = await ScoutExtractIngest.ingest(
            results, clients: clients, history: history, blocked: blocked, today: today, now: now,
            landings: landings, priority: priority, sequence: sequence,
            sequenceFloor: { pending.highestSequence },
            onWait: { runSequence in
                guard !kept else { return }
                do {
                    try pending.record(data, sequence: runSequence, now: now)
                    kept = true
                } catch {
                    copyFailure = String(describing: error)
                }
            },
            saveClosing: saveClosing,
            into: context)
        if outcome.notLandedYet != nil {
            // The refusal's own sentence says a copy was kept. When it was not, that sentence is false, so
            // it is replaced by one that names what failed and where the results still are.
            if !kept { outcome.notLandedYet = LandingWaitCopy.ingestRefusedWithoutACopy(copyFailure ?? "unknown") }
            return Landed(outcome: outcome, copyLeftBehind: nil)
        }
        // L5, L665: removed only once the save carrying these results has succeeded. A failed save means
        // they may never have reached disk, and the copy is then the only record of them, so it stays and
        // the sweep offers it again.
        if kept && !outcome.saveFailed {
            do {
                try pending.remove(hash)
            } catch {
                // Landed, and the copy could not be removed, so the sweep will offer it again and it will
                // land a second time. Said rather than left to happen.
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
        var stillWaiting = 0
        // Older than one scout interval and still not landed: STUCK, not waiting (L665).
        var stuck = 0
        var unreadable: [String] = []
        var copiesLeftBehind: [String] = []

        var isEmpty: Bool {
            landed.isEmpty && stillWaiting == 0 && stuck == 0 && unreadable.isEmpty && copiesLeftBehind.isEmpty
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
                             into context: ModelContext) async -> Offered {
        var offered = Offered()
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
                guard !waiting.contains(entry.contentHash) else { continue }
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
                                        into: context)
                let outcome = landed.outcome
                if let left = landed.copyLeftBehind { offered.copiesLeftBehind.append(left) }
                if outcome.notLandedYet == nil && !outcome.saveFailed {
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
