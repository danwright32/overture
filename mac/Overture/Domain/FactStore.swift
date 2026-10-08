import Foundation
import SwiftData

// #4358 (plan v7 Phase 4, the FactStore): every queue input the store holds, as values, keyed by identity.
//
// The queue engine keeps this instead of the live models, so the value pass reads values that cannot fault the
// store or change underneath it, and so an edit that changed nothing a term reads is recognised by `==` and
// dropped (D2's equality gate). One dictionary per model the pass reads, each keyed by `persistentModelID` and
// never by `naturalKey` (merges and re-keys reassign it) or by `Recipient.id` (one address sits on several
// shows), and each named in `Table` by the model it holds, which is how a saved identifier says which table it
// belongs to (`PersistentIdentifier.entityName`). A contact has no table: it rides inside its show's `RowFacts`.
//
// `extractAll(from:)` is the whole read, over ANY context. The engine fills itself through the same initialiser
// (`init(shows:inquiries:smallTablesFrom:)`), and the verifier (#4358, slice E2) and the change-kind matrix read
// a fresh store through `extractAll` on a context of their own, so the two sides of every comparison share the
// extraction and nothing else (L70): neither ever reads the other's dictionaries.
struct FactStore: Equatable, Sendable {
    var shows: [PersistentIdentifier: RowFacts] = [:]
    var inquiries: [PersistentIdentifier: InquiryRecord] = [:]
    var orgAnswers: [PersistentIdentifier: OrgAnswerRecord] = [:]
    var watchedSources: [PersistentIdentifier: WatchedSourceRecord] = [:]
    var refusedAddresses: [PersistentIdentifier: RefusedAddressRecord] = [:]
    var promotedProducers: [PersistentIdentifier: ProducerOverrideRecord] = [:]
    var demotedHouses: [PersistentIdentifier: ProducerOverrideRecord] = [:]
    var excludedTowns: [PersistentIdentifier: TownRecord] = [:]
    var allowedSeedTowns: [PersistentIdentifier: TownRecord] = [:]

    /// Every table, by the model whose rows it holds. Each case is spelled as its dictionary above, which
    /// `FactStoreTablesTests` holds to the struct's own members by Mirror, and to `AppSchemaInputClass`, so a
    /// model the pass reads cannot be classified without a table to keep it in.
    enum Table: String, CaseIterable, Sendable {
        case shows = "Prospect"
        case inquiries = "Inquiry"
        case orgAnswers = "OrgReachabilityAnswer"
        case watchedSources = "WatchedSource"
        case refusedAddresses = "RefusedContactAddress"
        case promotedProducers = "PromotedProducer"
        case demotedHouses = "DemotedHouse"
        case excludedTowns = "ExcludedTown"
        case allowedSeedTowns = "AllowedSeedTown"

        /// The table holding rows of the model `entityName` names, or nil for a model the pass never reads.
        static func holding(_ entityName: String) -> Table? { Table(rawValue: entityName) }

        /// The live row `id` names in this table, read through `context`, or nil when it is gone. A row the
        /// context already holds is answered from it; any other is FETCHED by identity, because `model(for:)` on
        /// a row deleted and saved hands back a model that reads as live (#4106 probe 2), and a fetch that
        /// finds nothing is a deletion (decision 9). A fetch that fails THROWS rather than answering nil: a
        /// failed read is never a deletion (L215).
        func liveRow(_ id: PersistentIdentifier, in context: ModelContext) throws -> (any PersistentModel)? {
            switch self {
            case .shows: return try FactStore.liveRow(Prospect.self, id, in: context)
            case .inquiries: return try FactStore.liveRow(Inquiry.self, id, in: context)
            case .orgAnswers: return try FactStore.liveRow(OrgReachabilityAnswer.self, id, in: context)
            case .watchedSources: return try FactStore.liveRow(WatchedSource.self, id, in: context)
            case .refusedAddresses: return try FactStore.liveRow(RefusedContactAddress.self, id, in: context)
            case .promotedProducers: return try FactStore.liveRow(PromotedProducer.self, id, in: context)
            case .demotedHouses: return try FactStore.liveRow(DemotedHouse.self, id, in: context)
            case .excludedTowns: return try FactStore.liveRow(ExcludedTown.self, id, in: context)
            case .allowedSeedTowns: return try FactStore.liveRow(AllowedSeedTown.self, id, in: context)
            }
        }
    }

    init() {}

    /// Every queue input in the store `context` reads, as values. A context of its own sees what is SAVED; the
    /// main context also sees its own unsaved changes.
    static func extractAll(from context: ModelContext) throws -> FactStore {
        try FactStore(shows: context.fetch(FetchDescriptor<Prospect>()),
                      inquiries: context.fetch(FetchDescriptor<Inquiry>()),
                      smallTablesFrom: context)
    }

    /// The store from shows and inquiries the caller already fetched (the engine holds them, to watch them),
    /// with every small table read through `context`.
    nonisolated init(shows: [Prospect], inquiries: [Inquiry], smallTablesFrom context: ModelContext) throws {
        self.shows = Self.keyed(shows, RowFacts.extract)
        self.inquiries = Self.keyed(inquiries, InquiryRecord.init(copying:))
        orgAnswers = try Self.keyed(context.fetch(FetchDescriptor<OrgReachabilityAnswer>()),
                                    OrgAnswerRecord.init(copying:))
        watchedSources = try Self.keyed(context.fetch(FetchDescriptor<WatchedSource>()),
                                        WatchedSourceRecord.init(copying:))
        refusedAddresses = try Self.keyed(context.fetch(FetchDescriptor<RefusedContactAddress>()),
                                          RefusedAddressRecord.init(copying:))
        promotedProducers = try Self.keyed(context.fetch(FetchDescriptor<PromotedProducer>()),
                                           ProducerOverrideRecord.init(copying:))
        demotedHouses = try Self.keyed(context.fetch(FetchDescriptor<DemotedHouse>()),
                                       ProducerOverrideRecord.init(copying:))
        excludedTowns = try Self.keyed(context.fetch(FetchDescriptor<ExcludedTown>()), TownRecord.init(copying:))
        allowedSeedTowns = try Self.keyed(context.fetch(FetchDescriptor<AllowedSeedTown>()),
                                          TownRecord.init(copying:))
    }

    /// Which of `ids` the store really holds, by one FETCH per table, never through the context's registered
    /// objects: a row merged into another by its unique key stays registered and reads as live, and only a
    /// fetch finds that its identifier names no row (#4358). Identifiers of a model with no table are left out.
    nonisolated static func storedIdentifiers(among ids: Set<PersistentIdentifier>,
                                              in context: ModelContext) throws -> Set<PersistentIdentifier> {
        var found: Set<PersistentIdentifier> = []
        let byTable = Dictionary(grouping: ids) { Table.holding($0.entityName) }
        for (table, members) in byTable {
            guard let table else { continue }
            switch table {
            case .shows: found.formUnion(try stored(Prospect.self, members, in: context))
            case .inquiries: found.formUnion(try stored(Inquiry.self, members, in: context))
            case .orgAnswers: found.formUnion(try stored(OrgReachabilityAnswer.self, members, in: context))
            case .watchedSources: found.formUnion(try stored(WatchedSource.self, members, in: context))
            case .refusedAddresses: found.formUnion(try stored(RefusedContactAddress.self, members, in: context))
            case .promotedProducers: found.formUnion(try stored(PromotedProducer.self, members, in: context))
            case .demotedHouses: found.formUnion(try stored(DemotedHouse.self, members, in: context))
            case .excludedTowns: found.formUnion(try stored(ExcludedTown.self, members, in: context))
            case .allowedSeedTowns: found.formUnion(try stored(AllowedSeedTown.self, members, in: context))
            }
        }
        return found
    }

    /// Stores `model` as its value in the table it belongs to, and says whether the stored value CHANGED. An
    /// equal value is still stored (the same value), so a caller can tell "read and unchanged" from "absent".
    mutating func record(_ model: any PersistentModel) -> Bool {
        switch model {
        case let m as Prospect: return Self.put(RowFacts.extract(m), m.persistentModelID, in: &shows)
        case let m as Inquiry: return Self.put(InquiryRecord(copying: m), m.persistentModelID, in: &inquiries)
        case let m as OrgReachabilityAnswer:
            return Self.put(OrgAnswerRecord(copying: m), m.persistentModelID, in: &orgAnswers)
        case let m as WatchedSource:
            return Self.put(WatchedSourceRecord(copying: m), m.persistentModelID, in: &watchedSources)
        case let m as RefusedContactAddress:
            return Self.put(RefusedAddressRecord(copying: m), m.persistentModelID, in: &refusedAddresses)
        case let m as PromotedProducer:
            return Self.put(ProducerOverrideRecord(copying: m), m.persistentModelID, in: &promotedProducers)
        case let m as DemotedHouse:
            return Self.put(ProducerOverrideRecord(copying: m), m.persistentModelID, in: &demotedHouses)
        case let m as ExcludedTown: return Self.put(TownRecord(copying: m), m.persistentModelID, in: &excludedTowns)
        case let m as AllowedSeedTown:
            return Self.put(TownRecord(copying: m), m.persistentModelID, in: &allowedSeedTowns)
        default: return false
        }
    }

    /// Whether any table holds a row under `id`.
    func holds(_ id: PersistentIdentifier) -> Bool {
        guard let table = Table.holding(id.entityName) else { return false }
        switch table {
        case .shows: return shows[id] != nil
        case .inquiries: return inquiries[id] != nil
        case .orgAnswers: return orgAnswers[id] != nil
        case .watchedSources: return watchedSources[id] != nil
        case .refusedAddresses: return refusedAddresses[id] != nil
        case .promotedProducers: return promotedProducers[id] != nil
        case .demotedHouses: return demotedHouses[id] != nil
        case .excludedTowns: return excludedTowns[id] != nil
        case .allowedSeedTowns: return allowedSeedTowns[id] != nil
        }
    }

    /// How `fresh` differs from this store: the rows whose value changed or appeared, and the identities this
    /// store holds that `fresh` does not. Every table is compared; `FactStoreTablesTests` holds the list below to
    /// the struct's members.
    func differences(to fresh: FactStore) -> (changed: Int, gone: Set<PersistentIdentifier>) {
        var changed = 0
        var gone: Set<PersistentIdentifier> = []
        func compare<R: Equatable>(_ path: KeyPath<FactStore, [PersistentIdentifier: R]>) {
            let old = self[keyPath: path]
            let new = fresh[keyPath: path]
            for (id, value) in new where old[id] != value { changed += 1 }
            for id in old.keys where new[id] == nil {
                gone.insert(id)
                changed += 1
            }
        }
        compare(\.shows)
        compare(\.inquiries)
        compare(\.orgAnswers)
        compare(\.watchedSources)
        compare(\.refusedAddresses)
        compare(\.promotedProducers)
        compare(\.demotedHouses)
        compare(\.excludedTowns)
        compare(\.allowedSeedTowns)
        return (changed, gone)
    }

    private static func put<R: Equatable>(_ value: R, _ id: PersistentIdentifier,
                                          in table: inout [PersistentIdentifier: R]) -> Bool {
        table.updateValue(value, forKey: id) != value
    }

    private nonisolated static func keyed<M: PersistentModel, R>(_ rows: [M],
                                                                 _ make: (M) -> R) -> [PersistentIdentifier: R] {
        var out: [PersistentIdentifier: R] = [:]
        out.reserveCapacity(rows.count)
        for row in rows { out[row.persistentModelID] = make(row) }
        return out
    }

    private nonisolated static func stored<M: PersistentModel>(_ type: M.Type, _ ids: [PersistentIdentifier],
                                                               in context: ModelContext) throws -> [PersistentIdentifier] {
        try context.fetch(FetchDescriptor<M>(predicate: #Predicate<M> { ids.contains($0.persistentModelID) }))
            .map(\.persistentModelID)
    }

    private nonisolated static func liveRow<M: PersistentModel>(_ type: M.Type, _ id: PersistentIdentifier,
                                                                in context: ModelContext) throws -> M? {
        if let held: M = context.registeredModel(for: id) { return StoreRows.isLive(held) ? held : nil }
        var descriptor = FetchDescriptor<M>(predicate: #Predicate<M> { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// #4358 (plan v7 Phase 4, steps 1 to 4): the values the queue engine decides with, kept beside the store whose
// identities they are about, so each decision is a plain function over values a test drives directly: which
// identities a turn removes or renames (`QueueEngineResolution`), what a pass is handed (`QueueEnginePassInput`),
// why it ran (`QueueEnginePassReason`), when the clock next forces one (`QueueEngineDeadline`), and whether an
// output may replace the one on screen (`QueueEngineGenerations`). The engine (`App/QueueEngine.swift`) owns
// the observation, notifications and timers that feed them.

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
    /// Shows whose natural key changed under the same identity (a rename), from the old key to the new.
    var rekeyedKeys: [String: String] = [:]

    var isEmpty: Bool { deletedIDs.isEmpty && deletedKeys.isEmpty && rekeyedIDs.isEmpty && rekeyedKeys.isEmpty }
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
        compactMap { key in resolution.deletedKeys.contains(key) ? nil : (resolution.rekeyedKeys[key] ?? key) }
    }
}

/// The surface's own state the pass reads: which stage is focused, which leads, and which cards the last frame
/// drew. Compared by `==`, so the same inputs handed in again are no reason for a pass (plan v2 Phase 4 step 2).
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
    /// #4358 slice E4b: the inputs that arrive by a signal, as the engine read them for this pass.
    let context: QueueEngineContextInputs
}

/// #4358 slice E4b: every input of the queue's pass that is neither a store row, the clock nor the surface's view,
/// which is every input `QueueInputSource.byInput` names `.signal` (`QueueEngineContextInputsTests` holds the two
/// to one list, L96). The engine reads these on the main actor when a pass derives and carries them on the output,
/// so the verifier's rebuild on its own thread derives from exactly what the output on screen was derived from: a
/// rebuild that read them again could disagree with the screen for a reason that is not a fault (L70).
///
/// `clients` is REQUIRED, on `StageContext`'s rule: `ClientWindow.none` is a real answer ("nobody is a client"),
/// so a caller has to ask for it by name rather than arrive at it by forgetting.
struct QueueEngineContextInputs: Equatable, Sendable {
    var clients: ClientWindow
    var gmailConnected = false
    var runInFlight: RunKind?
    var prepSlotRunning = false
    var checkSlotRunning = false
    var checkRunSince: Date?
    var checkLookups: Int?
    var replyRunAlive = false

    init(clients: ClientWindow, gmailConnected: Bool = false, runInFlight: RunKind? = nil,
         prepSlotRunning: Bool = false, checkSlotRunning: Bool = false, checkRunSince: Date? = nil,
         checkLookups: Int? = nil, replyRunAlive: Bool = false) {
        self.clients = clients
        self.gmailConnected = gmailConnected
        self.runInFlight = runInFlight
        self.prepSlotRunning = prepSlotRunning
        self.checkSlotRunning = checkSlotRunning
        self.checkRunSince = checkRunSince
        self.checkLookups = checkLookups
        self.replyRunAlive = replyRunAlive
    }
}

/// Why a pass derived. A turn with no reason does not derive (the generation gate, plan v2 Phase 4 step 2).
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
    /// The verifier found the output on screen unequal to a pass over facts that agree with the store, and this
    /// pass is its heal (plan v7 D7).
    case recovery
}

/// When the clock next forces a pass, and which of the two deadlines it is (plan v2 Phase 4 step 4).
struct QueueEngineDeadline: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A rule in the last output comes due (`DueWork.nextChange`'s shape).
        case term
        /// No rule is due sooner than the floor, so the pass is forced anyway.
        case floor
    }

    let at: Date
    let kind: Kind

    /// The floor every deadline is held to. One minute: the longest a clock-driven change may wait unseen.
    static let floorInterval: TimeInterval = 60

    /// ONE deadline: the earlier of the output's own next change and the floor. A rule already due is due now.
    static func next(now: Date, termNextChange: Date?) -> QueueEngineDeadline {
        let floorAt = now.addingTimeInterval(floorInterval)
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
    /// Turns the engine ran, and the stored values those turns changed (the equality gate's other side).
    var turns = 0
    var rowsChanged = 0
    /// Turns that derived an output. A turn with no reason derives nothing (the generation gate).
    var passes = 0
    /// Rows read again from the store, and how many of those the equality gate dropped as unchanged.
    var rowsReread = 0
    var equalValueReads = 0
    /// Whole-store reads: at the start, after an unclassified save or an insert merged away, and after a foreign
    /// save only when none of its identifiers reached the engine.
    var fullReads = 0
    /// A save through a context other than the main one. Never happens in the app (only the main context
    /// writes, `OnlyTheMainContextWritesGuardTests`). Since #4358 slice E2 each one faults the rows it named and
    /// recovery fetches them again (decision 9(a)); it costs a full read only when its identifiers never reached
    /// the engine.
    var foreignSaves: QueueEngineAnomaly = .neverFired
    /// A saved identifier whose model `AppSchemaInputClass` does not classify, which also costs a full read.
    var unclassifiedSaves: QueueEngineAnomaly = .neverFired
    /// A row a save named as inserted that the store does not hold: merged by its unique key into a row already
    /// stored, which changed in place unnamed, so this costs a full read. The app's own writers find a row by
    /// its key before writing (`ScoutService.upsertTarget`), so this is the unique constraint's net.
    var insertsMergedAway: QueueEngineAnomaly = .neverFired
    /// A read that THREW, left as it was rather than read as deleted (L215).
    var unreadRows: QueueEngineAnomaly = .neverFired
    /// #4369 (#4358 slice E4b): turns in which a landing's capped intake read rows, and turns that had a reason to
    /// derive and held it because a landing was still open or still carried rows (the held publish).
    var landingBatches = 0
    var heldTurns = 0
}

/// #4369 (#4358 slice E4b, plan item 4): the scout landing as a declared BULK change kind in the engine's own
/// intake. Measured on #4603's probe over the frozen 4x store: one landing's intake took 328.7 to 344.1 ms of main
/// actor time in one turn, about 0.33 ms a row, against plan v7's 50 ms bulk turn budget. So while a landing is open
/// the intake reads at most `batchSize` rows a turn and carries the rest to the next (decision 10's batch of 150,
/// about 49 ms at 4x on that reading), and publishes nothing until it closes unless Dan acts.
struct QueueEngineLandingSetup: Sendable {
    /// Rows read per turn while a landing holds the intake. A test forces 1 so every landing it drives takes the
    /// multi-batch path, which at the default only a landing over 150 rows would (L101).
    var batchSize = 150
}

// MARK: - The launch (#4358 slice E3, plan v7 D6 and decision 4)

// How the engine fills itself at launch, as values. The first output comes from ONE read of the saved store made off
// the main thread, and nothing is published before it lands, so the queue is never shown empty while it loads. Then
// the rows the engine watches (the main context's own, each with a tracker armed) are taken in keyset batches of 20
// on a byte order sort, one batch per main actor turn, so no turn holds the main thread for the whole table (0b.3:
// batches of 25 had a worst sample of 17.5 ms at 5,376, so 20, against plan v7's 16 ms). The inquiries follow in
// one fetch (they have no stored unique key to page on). Last, a read of every stored identifier on its own context
// finds any row the keyset skipped: `naturalKey` is mutable, so a row renamed below the cursor while the fill runs is
// never reached by it (L15, L16, L211).

/// Why a read the launch made could not be used. Every case is produced by a test (L151).
enum QueueEngineLaunchFailure: String, Error, Equatable, Sendable, CaseIterable {
    /// The read threw.
    case readFailed
    /// The read came back with fewer rows than a count of the same store said it holds (D6: a short read is a
    /// failure, never a shorter queue).
    case shortRead
    /// The launch thread did not answer within its deadline.
    case timedOut
    /// An earlier read on the launch thread has still not returned, so this one was never started.
    case wedged

    /// What the launch thread throwing `error` measured: its deadline passing, its refusal while an abandoned read
    /// still runs, or the read's own failure.
    static func from(_ error: any Error) -> QueueEngineLaunchFailure {
        switch error as? BlockingWorkError {
        case .timedOut: return .timedOut
        case .busy: return .wedged
        case nil: return .readFailed
        }
    }
}

/// What the surface can show while the engine fills, as two halves that move separately: the first output, which
/// Dan waits for, and the fill behind it, which he does not. Each half has working, failed and finished as distinct
/// states, and the working state carries when it began, so the surface can show the time it has taken (Dan's rule
/// for anything that takes time). Assigned only when a state CHANGES, never per batch, so a surface observing it is
/// not drawn again for every batch of the fill.
struct QueueEngineLaunchState: Equatable, Sendable {
    enum FirstPaint: Equatable, Sendable {
        case notStarted
        /// The first read is under way, since `since`, on its `attempt`th try.
        case loading(since: Date, attempt: Int)
        /// It could not be used, after `attempts` tries. Nothing is on screen; `retryLaunch()` tries again.
        case failed(QueueEngineLaunchFailure, attempts: Int, at: Date)
        /// The first output is on screen.
        case ready(at: Date, attempts: Int)
    }

    enum Fill: Equatable, Sendable {
        /// It begins once the first output is on screen.
        case waiting
        /// Under way since `since`. How far it has got is `QueueEngine.fillReport`, read when asked.
        case filling(since: Date)
        /// A batch could not be read, after `attempts` tries. The output stays on screen and every row not yet
        /// taken is still reached by a save that names it; `retryLaunch()` resumes from where it stopped.
        case failed(QueueEngineLaunchFailure, attempts: Int, at: Date)
        case done(QueueEngineFillReport)
    }

    var firstPaint: FirstPaint = .notStarted
    var fill: Fill = .waiting
}

/// Whether the fill missed a row the store holds.
enum QueueEngineShortfall: Equatable, Sendable {
    /// Rows the store holds that the fill did not reach, and how many of those one fetch then admitted (the rest
    /// were deleted since).
    case measured(missing: Int, admitted: Int)
    /// Rows the store holds that the fill did not reach, and the one fetch that would have admitted them failed:
    /// they are stored and not held, which is never read as deleted (L215, L11). The verifier's fresh read finds
    /// them stored and not held, and recovery takes them from there.
    case unadmitted(missing: Int, QueueEngineLaunchFailure)
    /// The identifier read could not be made, so whether the fill missed a row is not known. Never read as none
    /// (L215).
    case unmeasured(QueueEngineLaunchFailure)
}

/// What one fill did and what each batch cost the main thread, counted where it happens (L63), so the budget is
/// read off the run itself.
struct QueueEngineFillReport: Equatable, Sendable {
    var shows = 0
    var inquiries = 0
    /// Keyset batches taken, the last of which comes back short or empty.
    var batches = 0
    /// Each batch's main thread time in seconds (the fetch, arming each row, and recording its value), in order.
    var batchSeconds: [TimeInterval] = []
    /// The one fetch of every inquiry.
    var inquirySeconds: TimeInterval = 0
    /// Nil until the identifier read has answered.
    var shortfall: QueueEngineShortfall?

    var slowestBatch: TimeInterval { batchSeconds.max() ?? 0 }
    var batchesOverBudget: Int { batchSeconds.filter { $0 > QueueEngineLaunchFill.batchBudgetSeconds }.count }
}

enum QueueEngineLaunchFill {
    /// Rows per keyset batch (decision 4).
    static let batchSize = 20
    /// What one batch may cost the main thread (plan v7 section 14: "Launch: batches of 20 under 16 ms"). A batch
    /// over it is counted (`batchesOverBudget`), never hidden; nothing is decided from it.
    static let batchBudgetSeconds: TimeInterval = 0.016
    /// How long the launch thread gets for one read. The whole read took 3,237 ms at 5,376 shows in Debug on the
    /// main thread (#4358 slice E1a), so this is about ten times the slowest read measured.
    static let deadlineSeconds: TimeInterval = 30

    /// The next `limit` shows after `cursor` in BYTE order. The predicate compares stored bytes, so the sort must
    /// too: `.lexical`, never the default `.localizedStandard`, which orders numbers, case and accents otherwise
    /// and made a fill miss 60 rows and repeat 120 at 5,376 while every count looked plausible (0b.3).
    static func batch(after cursor: String?, limit: Int) -> FetchDescriptor<Prospect> {
        var descriptor = FetchDescriptor<Prospect>(sortBy: [SortDescriptor(\Prospect.naturalKey, comparator: .lexical)])
        if let cursor { descriptor.predicate = #Predicate<Prospect> { $0.naturalKey > cursor } }
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Every show and inquiry identifier the SAVED store holds, read through a context of its own (D6: a separate
    /// read, so an unsaved delete on the main context cannot mask a missing row).
    static func storedIdentifiers(_ container: ModelContainer) throws -> Set<PersistentIdentifier> {
        let reader = ModelContext(container)
        return Set(try reader.fetchIdentifiers(FetchDescriptor<Prospect>()))
            .union(try reader.fetchIdentifiers(FetchDescriptor<Inquiry>()))
    }
}
