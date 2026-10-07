import Foundation
import SwiftData

// #4358 (plan v7 D7 and decision 9, slice E2): the queue engine's verifier and its recovery, as values a test
// drives directly. The engine (`App/QueueEngine.swift`) owns the thread, the timers and the turn; everything that
// DECIDES lives here.
//
// WHAT THE VERIFIER ASKS. Whether the engine's held facts, and the output it published from them, are what a
// fresh read of the saved store says they should be. The engine keeps a value per row and re-reads a row only
// when something says it changed, so a change that reached the store by a route nothing reported would leave a
// stale value on screen with nothing to notice it. This is what notices.
//
// WHERE ITS SIDE COMES FROM (L345, L70, L721). The fresh read is made through a context of its own, on the
// verifier's thread, through `FactStore.extractAll`; it never reads the engine's facts, its members or its
// intake to build its side. The comparison is plain `==` per row, never the intake's or the equality gate's
// predicate, so a gate that decided wrongly cannot also decide that it decided rightly. And recovery's heal check
// reads the rows it repaired through ANOTHER throwaway context, never the main context it refetched them into.
//
// WHAT IT DOES NOT COMPARE YET, named so nobody reads a match as more than it is. Plan v7 D7 lists four
// comparisons. (i) facts by identity and (iii) the output from fresh facts are here. (ii) ProducerTables built
// cold against the retained copy waits for there to BE a retained copy, which is Phase 4b's T4 (#4362); today the
// pass builds them cold every time, so (iii) covers them. (iv) the card term on background models against cards
// from extracted facts waits for the engine to build cards, the cutover (#4358, slice E4).

/// One fresh read of the SAVED store, made through a context of its own, and what a count said beside it.
struct QueueEngineFreshRead: Sendable {
    let facts: FactStore
    /// How many shows and inquiries a COUNT said the store holds, taken on the same context before the fetch. A
    /// fetch that came back with fewer is a short read, never a store that lost rows (L211).
    let counted: [FactStore.Table: Int]

    /// The verifier's read: a new context on `container`, a count, then the whole read.
    static func read(_ container: ModelContainer) throws -> QueueEngineFreshRead {
        let reader = ModelContext(container)
        let counted: [FactStore.Table: Int] = [
            .shows: try reader.fetchCount(FetchDescriptor<Prospect>()),
            .inquiries: try reader.fetchCount(FetchDescriptor<Inquiry>()),
        ]
        return QueueEngineFreshRead(facts: try FactStore.extractAll(from: reader), counted: counted)
    }

    var isShort: Bool {
        (counted[.shows] ?? 0) > facts.shows.count || (counted[.inquiries] ?? 0) > facts.inquiries.count
    }
}

/// A published output and the facts it was derived from, kept while a verification runs so a read landing at
/// that output's save count has something to be compared with (D7's ring).
struct QueueEngineSnapshot<Value: Sendable>: Sendable {
    let saveCount: Int
    let generation: Int
    let facts: FactStore
    let viewInputs: QueueEngineViewInputs
    let now: Date
    let value: Value
    /// Whether the main context held no unsaved change when this was published. The engine's facts include the
    /// main context's unsaved edits and a fresh read sees only what is saved, so only a clean snapshot can be
    /// compared with one (`unmeasured(busy)` otherwise).
    let clean: Bool
}

/// What one verification found. Every case is produced by a test (L151).
enum QueueEngineVerification: Equatable, Sendable {
    /// The facts and the output both equal what a fresh read derives.
    case match(generation: Int)
    /// Rows whose held value differs from the fresh read, by identity, with the NAMES of what differs (C7).
    case factMismatch(rows: [PersistentIdentifier: [String]], generation: Int)
    /// The facts agree and the published output does not equal the pass over them, by field name.
    case outputMismatch(fields: [String], generation: Int)
    /// Every read straddled a save, or none landed at a save count a snapshot describes.
    case superseded
    /// The engine stopped the run: more changes arrived than the ring holds, or a row was deleted under it.
    case cancelled
    /// Nothing could be measured, and why. None of these faults a row (L215, L211).
    case unmeasured(Unmeasured)

    enum Unmeasured: String, Equatable, Sendable, CaseIterable {
        /// The main context held an unsaved change, so the held facts are not the saved store's.
        case busy
        /// The read threw.
        case readFailed
        /// The read came back with fewer rows than a count of the same store said it holds.
        case shortRead
        /// The verifier's thread did not answer within its deadline (`BlockingWorkError.timedOut`).
        case timedOut
        /// An earlier verification has still not returned, so this one was never started (the thread is wedged).
        case wedged
    }
}

enum QueueEngineVerifier {
    /// A read that straddles a save is made again, at most this many times in all, then the run is superseded.
    static let readAttempts = 3
    /// After an output this long with no other, the engine verifies (D7: "after 3 s of quiet").
    static let quietSeconds: TimeInterval = 3
    /// Or after this many generations without a verification, whatever the quiet (D7: "forced every 20").
    static let forcedEveryGenerations = 20
    /// The verifier's thread gets this long (D7: "an engine-owned 30 s deadline").
    static let deadlineSeconds: TimeInterval = 30
    /// The most outputs a running verification keeps; one more cancels it.
    static let ringCapacity = 4
    /// With no completed comparison for this long, the engine records `unverifiedTooLong` (D7).
    static let unverifiedTooLongSeconds: TimeInterval = 600

    /// The verification itself, run on the verifier's thread. `ring` is read AFTER each read, so an output the
    /// engine published while the read ran can still be the one it is compared with.
    static func verify<Value: Sendable>(container: ModelContainer, saves: StoreSaveCount,
                                        read: (ModelContainer) throws -> QueueEngineFreshRead,
                                        ring: () -> [QueueEngineSnapshot<Value>],
                                        derivation: QueueEngineDerivation<Value>,
                                        cancelled: () -> Bool) -> QueueEngineVerification {
        for _ in 0..<readAttempts {
            if cancelled() { return .cancelled }
            let before = saves.value(for: container)
            let fresh: QueueEngineFreshRead
            do {
                fresh = try read(container)
            } catch {
                return .unmeasured(.readFailed)
            }
            // A save landed during the read, so it describes no one save count: read again.
            guard saves.value(for: container) == before else { continue }
            if fresh.isShort { return .unmeasured(.shortRead) }
            if cancelled() { return .cancelled }
            guard let snapshot = ring().last(where: { $0.saveCount == before && $0.clean }) else { return .superseded }
            return compare(snapshot, with: fresh.facts, derivation: derivation)
        }
        return .superseded
    }

    /// What the verifier's thread throwing `error` measured: its deadline passing is `timedOut`, its refusal while
    /// an abandoned run is still going is `wedged`, and anything else is a failure to read, never a wedged thread
    /// nothing measured (L11). The work itself throws nothing; a failed read is its own outcome inside it.
    static func unmeasured(by error: any Error) -> QueueEngineVerification.Unmeasured {
        switch error as? BlockingWorkError {
        case .timedOut: return .timedOut
        case .busy: return .wedged
        case nil: return .readFailed
        }
    }

    /// Whether another verification should follow `result`: one that could not say (superseded or cancelled),
    /// and one that judged an output older than the one now on screen, which would otherwise go unverified until
    /// some later output asked (L710). An unmeasured run is left to the next output's own trigger.
    static func needsAnother(after result: QueueEngineVerification, onScreen: Int?) -> Bool {
        switch result {
        case .superseded, .cancelled: return true
        case .match(let generation), .factMismatch(_, let generation), .outputMismatch(_, let generation):
            return generation < (onScreen ?? generation)
        case .unmeasured: return false
        }
    }

    /// One snapshot against one fresh read: the facts first, then the output a pass over the FRESH facts gives,
    /// at the snapshot's own instant and view.
    static func compare<Value: Sendable>(_ snapshot: QueueEngineSnapshot<Value>, with fresh: FactStore,
                                         derivation: QueueEngineDerivation<Value>) -> QueueEngineVerification {
        let rows = snapshot.facts.mismatches(against: fresh)
        guard rows.isEmpty else { return .factMismatch(rows: rows, generation: snapshot.generation) }
        let rebuilt = derivation.derive(QueueEnginePassInput(facts: fresh, viewInputs: snapshot.viewInputs,
                                                             now: snapshot.now))
        let fields = derivation.differingFields(snapshot.value, rebuilt).sorted()
        guard fields.isEmpty else { return .outputMismatch(fields: fields, generation: snapshot.generation) }
        return .match(generation: snapshot.generation)
    }
}

extension FactStore {
    /// Every row whose value differs between this store and `fresh`, by identity, with the names of what
    /// differs as `table.member` (C7: names only, never a value, L222). A row only one side holds is named
    /// `table.heldNotStored` or `table.storedNotHeld`.
    func mismatches(against fresh: FactStore) -> [PersistentIdentifier: [String]] {
        var out: [PersistentIdentifier: [String]] = [:]
        func compare<R: Equatable>(_ table: Table, _ path: KeyPath<FactStore, [PersistentIdentifier: R]>) {
            let held = self[keyPath: path]
            let stored = fresh[keyPath: path]
            for (id, value) in held {
                guard let other = stored[id] else {
                    out[id] = ["\(table).heldNotStored"]
                    continue
                }
                guard value != other else { continue }
                let members = Self.differingMembers(value, other)
                out[id] = (members.isEmpty ? ["value"] : members).map { "\(table).\($0)" }
            }
            for id in stored.keys where held[id] == nil { out[id] = ["\(table).storedNotHeld"] }
        }
        compare(.shows, \.shows)
        compare(.inquiries, \.inquiries)
        compare(.orgAnswers, \.orgAnswers)
        compare(.watchedSources, \.watchedSources)
        compare(.refusedAddresses, \.refusedAddresses)
        compare(.promotedProducers, \.promotedProducers)
        compare(.demotedHouses, \.demotedHouses)
        compare(.excludedTowns, \.excludedTowns)
        compare(.allowedSeedTowns, \.allowedSeedTowns)
        return out
    }

    /// The stored members of two values of one type that differ, by label, read by Mirror so a member added to
    /// a record is compared without anybody listing it (L96).
    static func differingMembers<R>(_ a: R, _ b: R) -> [String] {
        let left = Mirror(reflecting: a).children
        let right = Array(Mirror(reflecting: b).children)
        var out: [String] = []
        for (index, child) in left.enumerated() where index < right.count {
            guard let label = child.label, !sameValue(child.value, right[index].value) else { continue }
            out.append(label)
        }
        return out.sorted()
    }

    /// Whether this store and `other` hold the same value for `id`, absence included.
    func sameRow(_ id: PersistentIdentifier, as other: FactStore) -> Bool {
        guard let table = Table.holding(id.entityName) else { return true }
        switch table {
        case .shows: return shows[id] == other.shows[id]
        case .inquiries: return inquiries[id] == other.inquiries[id]
        case .orgAnswers: return orgAnswers[id] == other.orgAnswers[id]
        case .watchedSources: return watchedSources[id] == other.watchedSources[id]
        case .refusedAddresses: return refusedAddresses[id] == other.refusedAddresses[id]
        case .promotedProducers: return promotedProducers[id] == other.promotedProducers[id]
        case .demotedHouses: return demotedHouses[id] == other.demotedHouses[id]
        case .excludedTowns: return excludedTowns[id] == other.excludedTowns[id]
        case .allowedSeedTowns: return allowedSeedTowns[id] == other.allowedSeedTowns[id]
        }
    }

    private static func sameValue(_ a: Any, _ b: Any) -> Bool {
        if let equatable = a as? any Equatable { return equatable.isEqual(toAny: b) }
        return String(reflecting: a) == String(reflecting: b)
    }

    /// The rows `ids` name, read through `context`, as values: the heal check's side of a recovery, read through a
    /// throwaway context and never the main one it is checking (L345).
    static func extract(only ids: Set<PersistentIdentifier>, from context: ModelContext) throws -> FactStore {
        var out = FactStore()
        let byTable = Dictionary(grouping: ids) { Table.holding($0.entityName) }
        for (table, members) in byTable {
            guard let table else { continue }
            for model in try table.fetch(members, in: context) { _ = out.record(model) }
        }
        return out
    }
}

private extension Equatable {
    func isEqual(toAny other: Any) -> Bool { (other as? Self).map { $0 == self } ?? false }
}

extension FactStore.Table {
    /// The rows `ids` name in this table, FETCHED through `context` whatever it already holds. A fetch is what
    /// brings a main-context object back to the saved values when it holds no unsaved change (#4106 probe 0b.4).
    func fetch(_ ids: [PersistentIdentifier], in context: ModelContext) throws -> [any PersistentModel] {
        switch self {
        case .shows: return try Self.fetched(Prospect.self, ids, in: context)
        case .inquiries: return try Self.fetched(Inquiry.self, ids, in: context)
        case .orgAnswers: return try Self.fetched(OrgReachabilityAnswer.self, ids, in: context)
        case .watchedSources: return try Self.fetched(WatchedSource.self, ids, in: context)
        case .refusedAddresses: return try Self.fetched(RefusedContactAddress.self, ids, in: context)
        case .promotedProducers: return try Self.fetched(PromotedProducer.self, ids, in: context)
        case .demotedHouses: return try Self.fetched(DemotedHouse.self, ids, in: context)
        case .excludedTowns: return try Self.fetched(ExcludedTown.self, ids, in: context)
        case .allowedSeedTowns: return try Self.fetched(AllowedSeedTown.self, ids, in: context)
        }
    }

    static func fetched<M: PersistentModel>(_ type: M.Type, _ ids: [PersistentIdentifier],
                                            in context: ModelContext) throws -> [M] {
        try context.fetch(FetchDescriptor<M>(predicate: #Predicate<M> { ids.contains($0.persistentModelID) }))
    }
}

/// The rows the engine knows to be out of step with the store, and the recovery's bounds for each (D7, decision
/// 9). Keyed by the row the FactStore keys (a show, an inquiry, a small table row; a contact's fault is its show's).
struct QueueEngineFaults: Equatable, Sendable {
    /// How the engine came to know.
    enum Origin: String, Equatable, Sendable {
        /// The verifier's fresh read disagreed with the held value.
        case verifier
        /// A save through a context other than the main one touched the row (decision 9(a)).
        case foreignSave
    }

    struct Entry: Equatable, Sendable {
        let origin: Origin
        let fields: [String]
        let since: Date
        /// When the round of attempts now open began, or nil between rounds.
        var roundStartedAt: Date?
        var attempts = 0
        /// When each round in the last hour began, for the per hour cap.
        var rounds: [Date] = []
        /// When the last round gave up, or nil while one is open or none has run.
        var gaveUpAt: Date?
        /// When recovery last tried the row, so an open round's attempts are spaced rather than spent by a burst
        /// of unrelated turns.
        var lastAttemptAt: Date?
        /// Whether recovery has found the row waiting on an unsaved edit, so the wait is counted once per fault
        /// rather than once per turn (L344).
        var waitedForEdit = false
    }

    /// Attempts in one round, and how long one round may run (D7: "3 attempts or 60 s per round"), and how long
    /// the engine waits between attempts in an open round when nothing else asks for a turn sooner.
    static let attemptsPerRound = 3
    static let roundSeconds: TimeInterval = 60
    static let attemptSpacingSeconds: TimeInterval = 20
    /// A row whose round gave up is tried again this long after, or on the next save that touches it.
    static let retrySeconds: TimeInterval = 300
    /// At most this many rounds per row in any hour (D7: "a per-hour cap").
    static let roundsPerHour = 4
    /// A fault older than this is reported as stuck (L665, L110).
    static let stuckSeconds: TimeInterval = 3600

    private(set) var entries: [PersistentIdentifier: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    func contains(_ id: PersistentIdentifier) -> Bool { entries[id] != nil }

    /// Faults `rows`, each with the field names that brought it here. A row already faulted keeps its own
    /// history, so a repeat finding cannot restart its bounds.
    mutating func admit(_ rows: [PersistentIdentifier: [String]], origin: Origin, at now: Date) {
        for (id, fields) in rows where entries[id] == nil {
            entries[id] = Entry(origin: origin, fields: fields.sorted(), since: now)
        }
    }

    /// The rows a recovery should try now: any whose round is open or has not started, and any whose round gave
    /// up that a save has touched since or whose retry interval has passed, while the hour's cap allows.
    func due(at now: Date, touched: Set<PersistentIdentifier>) -> [PersistentIdentifier] {
        entries.compactMap { id, entry in
            guard let gaveUp = entry.gaveUpAt else {
                guard let last = entry.lastAttemptAt else { return id }
                return now.timeIntervalSince(last) >= Self.attemptSpacingSeconds ? id : nil
            }
            guard touched.contains(id) || now.timeIntervalSince(gaveUp) >= Self.retrySeconds else { return nil }
            let lastHour = entry.rounds.filter { now.timeIntervalSince($0) < 3600 }
            return lastHour.count < Self.roundsPerHour ? id : nil
        }
    }

    /// One failed attempt. Returns the entry when that attempt ENDED its round (attempts or time spent), which is
    /// the moment `healDidNotConverge` is written.
    mutating func failed(_ id: PersistentIdentifier, at now: Date) -> Entry? {
        guard var entry = entries[id] else { return nil }
        if entry.roundStartedAt == nil || entry.gaveUpAt != nil {
            entry.roundStartedAt = now
            entry.attempts = 0
            entry.gaveUpAt = nil
            entry.rounds = entry.rounds.filter { now.timeIntervalSince($0) < 3600 } + [now]
        }
        entry.attempts += 1
        let spent = now.timeIntervalSince(entry.roundStartedAt ?? now)
        let ended = entry.attempts >= Self.attemptsPerRound || spent >= Self.roundSeconds
        if ended { entry.gaveUpAt = now }
        entries[id] = entry
        return ended ? entry : nil
    }

    /// When the next try at any row comes due: soon while a round is open, else the retry interval after its
    /// give-up, held back to when the hour's cap frees a round. Nil when nothing is faulted.
    /// Never sooner than the attempt spacing: a row that is due and was not tried (it holds Dan's unsaved edit) is
    /// woken for again at that pace, not at once, which would run turns back to back until he saves (L110, L704);
    /// the save that clears the edit asks for its own turn sooner.
    func nextTry(at now: Date) -> Date? {
        let soonest = now.addingTimeInterval(Self.attemptSpacingSeconds)
        return entries.values.map { entry -> Date in
            guard let gaveUp = entry.gaveUpAt else {
                return max((entry.lastAttemptAt ?? now).addingTimeInterval(Self.attemptSpacingSeconds), soonest)
            }
            var at = gaveUp.addingTimeInterval(Self.retrySeconds)
            let lastHour = entry.rounds.filter { now.timeIntervalSince($0) < 3600 }.sorted()
            if lastHour.count >= Self.roundsPerHour, let oldest = lastHour.first {
                at = max(at, oldest.addingTimeInterval(3600))
            }
            return max(at, soonest)
        }.min()
    }

    /// Recovery tried these rows now, whatever the outcome.
    mutating func attempted(_ ids: Set<PersistentIdentifier>, at now: Date) {
        for id in ids { entries[id]?.lastAttemptAt = now }
    }

    /// Recovery found the row holding an unsaved edit. True the first time for this fault, which is the one
    /// that is counted.
    mutating func waitingForEdit(_ id: PersistentIdentifier) -> Bool {
        guard let entry = entries[id], !entry.waitedForEdit else { return false }
        entries[id]?.waitedForEdit = true
        return true
    }

    /// The row matches again: it leaves the set, and its entry is handed back for the `healed` record.
    mutating func healed(_ id: PersistentIdentifier) -> Entry? { entries.removeValue(forKey: id) }

    /// Applies a resolve step: a deleted row is no longer out of step with anything, and a re-keyed one moves.
    mutating func resolve(_ resolution: QueueEngineResolution) { entries.resolve(resolution) }

    /// What the verifier summary reports: how many rows are faulted, since when, and how many are stuck.
    struct Summary: Equatable, Sendable {
        let count: Int
        let oldestSince: Date?
        let stuck: Int
    }

    func summary(at now: Date) -> Summary {
        Summary(count: entries.count, oldestSince: entries.values.map(\.since).min(),
                stuck: entries.values.filter { now.timeIntervalSince($0.since) >= Self.stuckSeconds }.count)
    }
}

/// What the verifier has found this session, counted where it happens (L63, L557): zero matches reads as "never
/// verified", never as clean.
struct QueueEngineVerifierCounts: Equatable, Sendable {
    var started = 0
    var matches = 0
    var factMismatches = 0
    var outputMismatches = 0
    var superseded = 0
    var cancelled = 0
    var unmeasured: [QueueEngineVerification.Unmeasured: Int] = [:]
    var healed = 0
    var healDidNotConverge = 0
    /// Faulted rows recovery left alone because the main context held an unsaved edit on them, once per fault.
    var waitedForEdit = 0
    var unverifiedTooLong = 0
    var lastMatchedAt: Date?
}
