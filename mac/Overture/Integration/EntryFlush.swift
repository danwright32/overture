import Foundation
import Observation

// #4338 (A10): what one entry flush (`ScoutService.flushBeforeLanding`) did. Three answers rather than the
// refusal alone, because the landing that ran it counts the flushes that SAVED something on its record
// (`LandingRun.entryFlushSaves`), and "nothing was pending" is not a save.
enum EntryFlush: Equatable, Sendable {
    case nothingPending
    case saved
    case refused(LandingStop)

    var refusal: LandingStop? {
        if case .refused(let stop) = self { return stop }
        return nil
    }
}

// #4338 (A10, the L371 decision on #4332 and #4334): the entry flush's refusals in a row, so a refusal that
// keeps happening becomes a STANDING state on the landing line, with a way out, instead of a sentence each
// landing says once and the next landing says again.
//
// A refusal leaves the edits exactly where they were, and every landing after it refuses for the same reason,
// so one refusal is a report and two in a row are a state: no scout results land until the edits are saved or
// discarded. It stays until a save succeeds, which is any entry flush that finds nothing pending or saves what
// was, any save of the main context (RootView reports each one), or "Try saving again" working, or until Dan
// discards the edits.
//
// In memory, deliberately: the edits it is about live only in the main context, so a relaunch that loses them
// loses the state with them.
@Observable
@MainActor
final class EntryFlushRecord {
    // The one the app uses. A test that asserts on the record passes its own, so no test reads another's.
    static let shared = EntryFlushRecord()

    // Two in a row: the first is a report, the second is the state (the decision on #4332).
    static let stuckAfter = 2

    private(set) var refusalsInARow = 0
    // The rows the latest refusal was carrying, in Dan's words (`ScoutService.pendingRowNames`).
    private(set) var rows: [String] = []
    // When "Try saving again" last failed, so the line can say it was tried and what came of it.
    private(set) var lastTryFailedAt: Date?

    init() {}

    var isStuck: Bool { refusalsInARow >= Self.stuckAfter }

    func refused(rows: [String]) {
        refusalsInARow += 1
        self.rows = rows
    }

    func tryFailed(at time: Date, rows: [String]) {
        lastTryFailedAt = time
        self.rows = rows
    }

    // A save went through, so whatever was pending is in the store and nothing is stuck. Cheap when nothing
    // was: it changes no state, so nothing observing it redraws.
    func saveSucceeded() {
        guard refusalsInARow != 0 || lastTryFailedAt != nil || !rows.isEmpty else { return }
        refusalsInARow = 0
        rows = []
        lastTryFailedAt = nil
    }
}
