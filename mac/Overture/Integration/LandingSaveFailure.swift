import Foundation

// #4334 (A5): a scout landing's failed save, classified ONCE (L35, L527), into the two things a landing can do
// next.
//
//   SOURCE level   the refusal is confined to the rows one source wrote. That source is put back
//                  (`ScoutLandingStore.revertFailedSave`) and the landing carries on: "N landed, 1 could not
//                  be saved".
//   STORE level    anything else, including every error nobody has classified. The source is put back, the
//                  landing STOPS, and every source after it is reported `notAttempted`. Unclassified goes to
//                  stop because stopping cannot corrupt data and continuing might.
//
// What decides it is a REPRODUCTION, never a guess (L82, L681): `LandingSaveFailureTests` reaches every real
// refusal a save can be made to throw on this SDK and classifies each. As measured on 2026-09-29 (#4327 step
// 0.8) and again by #4334, none is confined to one source: a read only or immutable store refuses every save
// the container makes, a duplicate natural key does not refuse at all (`.unique` upserts), and a SQLite
// trigger that aborts a write ends the process before any catch runs. So the source level table is EMPTY and
// every failure stops the landing. A refusal later proved confined is added here with its reproduction.
enum LandingSaveFailure {
    enum Scope: Equatable, Sendable { case source, store }

    // The refusals proved confined to one source's rows, by error domain and code. Empty: see above.
    static let sourceLevel: [(domain: String, code: Int)] = []

    static func classify(_ error: Error) -> Scope {
        let ns = error as NSError
        return sourceLevel.contains { $0.domain == ns.domain && $0.code == ns.code } ? .source : .store
    }
}

// #4334 (A5): why a scout landing stopped before it had landed every source, or never started. Each is its
// own outcome with its own sentence (`ScoutWarningCopy`), because each leaves the store in a different state
// (L11).
enum LandingStop: Equatable, Sendable {
    // The entry flush: edits pending in the main context before the landing could not be saved, so the
    // landing did not start and nothing from it was applied. The edits are left exactly as they were. Names
    // the rows the refused save was carrying.
    case recentEditsUnsaved(rows: [String])
    // A source's save failed at store level: the source was put back, and nothing after it was attempted.
    case storeRefusedASave(source: String)
    // A source's save failed and what it wrote could not all be put back (`LandingRevert.Report.notRestorable`).
    // Nothing after it was attempted and no further save was made, so nothing it could not restore is saved.
    case notReverted(source: String, why: [String])
    // #4335 (A6): the landing's journal (`LandingJournals.start`) could not be written, so the landing did not
    // start and nothing from it was applied (L258): a landing a crash could not be recovered from is not
    // begun. Names why the write failed.
    case journalNotWritten(why: String)

    // A stop that came BEFORE anything was applied, so no source after it went unlanded: the results are
    // kept to land later (the ingest) or read again by the next scout (runScout), and saying "N calendars
    // after it were not landed" would describe a landing that never began.
    var refusedBeforeAnything: Bool {
        switch self {
        case .recentEditsUnsaved, .journalNotWritten: return true
        case .storeRefusedASave, .notReverted: return false
        }
    }
}
