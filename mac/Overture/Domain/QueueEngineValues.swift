import Foundation
import SwiftData

// #4358 (plan v7 Phase 4, steps 1 to 4): the values the queue engine decides with, kept apart from the engine
// itself so each decision is a plain function over values that a test can drive directly.
//
// The engine (`App/QueueEngine.swift`) owns observation, notifications and timers; everything here is what it
// computes from them: which identities a pass removes or renames (`QueueEngineResolution`), what a pass is
// handed (`QueueEnginePassInput`), why it ran (`QueueEnginePassReason`), when the clock next forces one
// (`QueueEngineDeadline`), and whether an output may replace the one on screen (`QueueEngineGenerations`).

/// What one resolve step removes and renames, applied to every structure the engine keys by identity
/// (`QueueEngine.identityKeyedState`). Built from the step's own evidence, never from a list of structures.
struct QueueEngineResolution: Equatable, Sendable {
    /// Rows that are gone: deleted and saved, deleted before they were ever saved, or a show's contacts gone
    /// with it.
    var deletedIDs: Set<PersistentIdentifier> = []
    /// The natural keys of the shows among them, for the structures a surface keys by show.
    var deletedKeys: Set<String> = []
    /// Temporary identifiers that a first save replaced (#4327 step 0.4), to the identifiers they became.
    var rekeyedIDs: [PersistentIdentifier: PersistentIdentifier] = [:]
    /// Natural keys a re-key changed, from the old key to the new.
    var rekeyedKeys: [String: String] = [:]

    var isEmpty: Bool {
        deletedIDs.isEmpty && deletedKeys.isEmpty && rekeyedIDs.isEmpty && rekeyedKeys.isEmpty
    }
}

extension Dictionary where Key == PersistentIdentifier {
    /// Without the deleted rows, and with every renamed row under its new identifier.
    mutating func resolve(_ resolution: QueueEngineResolution) {
        for id in resolution.deletedIDs { removeValue(forKey: id) }
        for (temporary, permanent) in resolution.rekeyedIDs {
            if let value = removeValue(forKey: temporary) { self[permanent] = value }
        }
    }
}

extension Set where Element == PersistentIdentifier {
    mutating func resolve(_ resolution: QueueEngineResolution) {
        subtract(resolution.deletedIDs)
        for (temporary, permanent) in resolution.rekeyedIDs where remove(temporary) != nil { insert(permanent) }
    }
}

extension Set where Element == String {
    /// Natural keys: without the deleted shows', and with a re-keyed show under its new key.
    mutating func resolve(keys resolution: QueueEngineResolution) {
        subtract(resolution.deletedKeys)
        for (old, new) in resolution.rekeyedKeys where remove(old) != nil { insert(new) }
    }
}

extension Array where Element == String {
    /// Natural keys in their order: the deleted shows' removed, a re-keyed show's renamed in place.
    func resolved(keys resolution: QueueEngineResolution) -> [String] {
        compactMap { key in
            resolution.deletedKeys.contains(key) ? nil : (resolution.rekeyedKeys[key] ?? key)
        }
    }
}

/// The surface's own state the pass reads: which stage is focused, which leads, and which cards the last frame
/// drew. Compared by `==`, so the same inputs handed in again are not a reason for a pass (plan v2 Phase 4
/// step 2).
struct QueueEngineViewInputs: Equatable, Sendable {
    var focusedStage: StageFocus?
    var focusedKeys: [String]?
    var requestedCardKeys: Set<String> = []
}

/// Everything one pass is handed. Values only, so the pass can never reach the store (B2).
struct QueueEnginePassInput: Sendable {
    let facts: FactStore
    let viewInputs: QueueEngineViewInputs
    let now: Date
}

/// Why a pass derived. A pass with no reason does not derive (the generation gate, plan v2 Phase 4 step 2).
enum QueueEnginePassReason: Hashable, Sendable, CaseIterable {
    /// The first pass, which has nothing on screen to keep.
    case first
    /// A stored value the pass reads changed (after the equality gate).
    case factsChanged
    /// The instant a rule in the last output comes due arrived.
    case clockTerm
    /// The 60 second floor arrived with no rule due before it (L51).
    case clockFloor
    /// The Mac woke, its clock or time zone was changed, or the calendar day turned.
    case wake
    case systemClock
    case timeZone
    case calendarDay
    /// An input that is neither a store row nor the clock moved (`QueueContextSignals`).
    case sourceFired
    /// The surface asked for a different view, or for a card the last pass did not build.
    case viewInputs
}

/// When the clock next forces a pass, and which of the two deadlines it is (plan v2 Phase 4 step 4).
struct QueueEngineDeadline: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A rule in the last output comes due (`DueWork.nextChange`'s shape).
        case term
        /// The floor: no rule is due sooner than `floor` from now, so the pass is forced anyway.
        case floor
    }

    let at: Date
    let kind: Kind

    /// The floor every deadline is held to. One minute: the longest a clock-driven change may wait unseen.
    static let floorInterval: TimeInterval = 60

    /// ONE deadline: the earlier of the output's own next change and the floor.
    static func next(now: Date, termNextChange: Date?,
                     floorInterval interval: TimeInterval = floorInterval) -> QueueEngineDeadline {
        let floorAt = now.addingTimeInterval(interval)
        guard let term = termNextChange, term < floorAt else { return QueueEngineDeadline(at: floorAt, kind: .floor) }
        return QueueEngineDeadline(at: max(term, now), kind: .term)
    }
}

/// Whether a pass's output may replace the one published (plan v2 Phase 4 step 3).
enum QueueEngineGenerations {
    enum Verdict: Equatable, Sendable {
        case apply
        /// An output no newer than the one on screen. Applying it would put an older store state over a newer
        /// one, so it is refused, loudly in Debug and by a routine log line in Release.
        case refuse(published: Int, incoming: Int)
    }

    static func verdict(published: Int?, incoming: Int) -> Verdict {
        guard let published, incoming <= published else { return .apply }
        return .refuse(published: published, incoming: incoming)
    }
}

/// One floor-only pass that changed the output: the 60 second floor's named cost (L93). Field NAMES only, never
/// a value (C7, L222).
struct QueueEngineFloorChange: Equatable, Sendable {
    let fields: [String]
    let at: Date
    let generation: Int
}

/// An event that should never happen in the running app, kept as a value so that zero reads as "never fired"
/// rather than as health (L557, L544).
enum QueueEngineAnomaly: Equatable, Sendable {
    case neverFired
    case fired(times: Int, lastAt: Date)

    mutating func record(at instant: Date) {
        switch self {
        case .neverFired: self = .fired(times: 1, lastAt: instant)
        case .fired(let times, _): self = .fired(times: times + 1, lastAt: instant)
        }
    }

    var times: Int {
        switch self {
        case .neverFired: return 0
        case .fired(let times, _): return times
        }
    }
}

/// What the engine has done, counted where it happens, so a test asserts the quantity rather than a proxy
/// for it (L63).
struct QueueEngineCounters: Equatable, Sendable {
    /// Passes that derived an output.
    var passes = 0
    /// Turns that read the intake and found no reason to derive.
    var intakeOnlyTurns = 0
    /// Rows read again from the store, and how many of those the equality gate dropped as unchanged.
    var rowsReread = 0
    var equalValueReads = 0
    /// Whole-store reads, at the start and after every save through another context.
    var fullReads = 0
    /// A save through a context other than the main one. Never happens in the app (only the main context
    /// writes, `OnlyTheMainContextWritesGuardTests`); each one costs a full read.
    var foreignSaves: QueueEngineAnomaly = .neverFired
    /// A saved identifier whose model `AppSchemaInputClass` does not classify, which also costs a full read.
    var unclassifiedSaves: QueueEngineAnomaly = .neverFired
    /// A row a save named as inserted that the store does not hold: merged by its unique key into a row already
    /// stored, which changed in place unnamed, so this costs a full read. The app's own writers find a row by
    /// its key before writing (`ScoutService.upsertTarget`), so this is the unique constraint's net.
    var insertsMergedAway: QueueEngineAnomaly = .neverFired
    /// A row whose read THREW, left as it was rather than read as deleted (L215).
    var unreadRows: QueueEngineAnomaly = .neverFired
}
