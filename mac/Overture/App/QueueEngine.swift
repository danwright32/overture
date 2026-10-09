import AppKit
import Foundation
import Observation
import SwiftData

// #4358 (plan v7 Phase 4, slices E1a and E1b): the queue engine's core. It keeps every queue input as a value,
// takes each store change in by identity, reading again only the rows a change names, decides whether a pass
// is due, and publishes one output per pass.
//
// WHAT IT REPLACES, once the cutover wires it (#4358, slice E4). Today every store change re-derives the whole
// queue on the main thread from the live models, inside the view's body, and nothing can tell a change that
// mattered from one that did not. This keeps a value per stored row (`FactStore`), reads a row again only when
// something says it changed, drops a re-read that changed nothing (the equality gate), and derives only when a
// stored value, the clock, a context source or the surface's own view actually moved.
//
// HOW A CHANGE ARRIVES (D2, decision 3: trackers plus didSave with the equality gate).
//   * A TRACKER per row (a show, a contact, an inquiry), armed through `ScopeField.arm` on that row's own
//     stored properties as the row is read. It fires on whatever thread wrote, so it does nothing but put the
//     row's IDENTITY in the lock-protected intake and ask for a turn. Values are read later, in the turn, on
//     the main actor (L368). A tracker fires once; the turn re-arms it.
//   * `ModelContext.didSave`, which names what a save inserted, updated and deleted. The observer copies those
//     identifiers into the same intake and reads no row. Posted off the main thread (a save through another
//     context), the copy is made under the lock there and the turn is asked for on the main actor.
//   * A contact's change reaches its show: the contact's tracker marks it, and the turn re-reads the show it
//     sat under (from `recipientParent`, kept as each show is read) and the show it sits under now.
// Every way a value can change is covered by one of the two, and each covers what the other cannot: a
// tracker sees an unsaved edit, and a save sees a write no tracker was armed for.
//
// THE RESOLVE STEP, one place, at the start of the turn (L38). Every structure this engine keys by identity
// or by natural key is listed in `identityKeyedState`, and the step applies one `QueueEngineResolution` to
// each entry: deleted rows purged, a temporary identifier a first save replaced re-keyed, a renamed show's
// natural key renamed. The list is checked rather than trusted: `EngineIdentityKeyedStateTests` walks this
// class's stored properties by Mirror and fails on any identity-keyed structure the list does not name (L96).
//
// THE GENERATION GATE AND COALESCING (plan v2 Phase 4 steps 2 and 3). ONE flag, so every change made in one
// main actor turn is taken in by one turn of the engine, and a whole night dismissed at once is one pass. A
// turn reads the intake, re-reads what it names, and derives only when a reason holds
// (`QueueEnginePassReason`). Each output carries the store's save count and a generation, and an output no
// newer than the one published is refused (`QueueEngineGenerations`).
//
// THE CLOCK (L51, L524). Injected. ONE deadline after each pass, at the earlier of the output's own next change
// and a 60 second floor (`QueueEngineDeadline`). A wake, a clock change, a time zone change and a new calendar
// day each force a pass. When a pass the floor alone forced changes the output, the change is kept as a
// `QueueEngineFloorChange` naming the fields, which is the floor's named cost (L93).
//
// THE VALUE PASS IS INJECTED (`QueueEngineDerivation`). The queue's own, `QueueRenderPass.make` over these
// facts, cannot run yet: `QueueModel.scope`, `AgentInputs.from` (#4357 G3), `RenderData` (#4357 slice I) and the
// pass's inquiry and small table inputs still take or hold models. The cutover (#4358, slice E4) hands it in.
// It is `@Sendable` over Sendable values, because the verifier runs it on its own thread (plan v7 Phase 3 step 8).
//
// WHO NUMBERS AN OUTPUT (#4358, slice E2). The engine, always: every publisher (the turn, the verifier's
// recovery, the launch fill of slice E3) takes its generation from `mintGeneration()` at the moment its inputs are
// fixed, so outputs carry distinct numbers in the order their inputs were taken, and the gate refuses exactly an
// output whose inputs are older than the one on screen. A publisher numbering its own would collide with the
// turn's next number, and the turn's newer output would be the one refused. An output published with a number
// the engine did not mint moves the counter past it, so the next turn is never refused for it.
//
// THE VERIFIER AND RECOVERY (plan v7 D7 and decision 9, slice E2; the values are `Domain/QueueEngineVerifier.swift`).
// After three seconds with no new output, or after twenty outputs whatever the quiet, the engine compares its
// facts and its output with a fresh read of the saved store, on `BlockingWorkThread` (a serial queue outside the
// cooperative pool, L241) under a 30 second deadline. A row that disagrees, and a row a save through another
// context touched, is FAULTED, and recovery fetches it again on the main context once that context holds no
// unsaved change for it (never a rollback, which keeps fetched values, #4106 probe 0c.7), reads it as any other
// change, and checks the result through a throwaway context. A row that will not converge stays faulted, with a
// `healDidNotConverge` record, for the show resolver to refuse actions on (#4357, slice I2, read by the cutover).
//
// THE LAUNCH (plan v7 D6 and decision 4, slice E3; the values are at the end of `Domain/FactStore.swift`). `start()`
// holds the main thread for nothing but registering its observers. The first output comes from one read of the
// SAVED store on the launch thread, its save count and generation taken when that read STARTS, so a save landing
// during it is newer than the output and the gate can never put these older inputs over a newer turn's. Until it
// lands no turn derives, so the queue is never published empty, and what the intake gathers meanwhile is taken in
// by the first turn after. Then the main context's rows, which the trackers watch, are taken in keyset batches of
// 20, ONE per turn, each timed; the inquiries in one fetch; and a read of every stored identifier finds any row the
// keyset skipped, which one fetch admits. The first verification is forced when the fill ends. Each half has a
// working, a failed and a finished state for the surface (`launch`), and `retryLaunch()` is the failed state's way
// on.
//
// NOTHING IN THE APP STARTS THIS YET. The cutover (#4358, slice E4) does.

/// What one pass derives from the facts, and the three things the engine needs to know about its answer.
struct QueueEngineDerivation<Value: Sendable>: Sendable {
    /// The value pass, over values only. The engine runs it on the main actor from a scheduled turn, never from a
    /// view body (L471); the verifier runs it on its own thread over a fresh read.
    let derive: @Sendable (QueueEnginePassInput) -> Value
    /// The members of two answers that differ, by name only (C7, L222), for the floor's and the verifier's records.
    let differingFields: @Sendable (Value, Value) -> [String]
    /// The earliest instant at which a rule in the answer comes due, or nil when none is in play.
    let nextChange: @Sendable (Value) -> Date?
    /// #4358 slice E4b (#4357 step 8): the pass as the engine's own turn runs it, on the main actor, wrapped in what
    /// a main-thread pass records (the queue's counts it and times it for the freeze watch). The verifier runs
    /// `derive` itself, on its own thread, which records nothing: a rebuild nobody waits for is not a pass any
    /// stall was spent in. Nil runs `derive`.
    var onTheMainActor: (@MainActor @Sendable (QueueEnginePassInput) -> Value)? = nil
    /// #4358 slice E4b (#4357 step 9): the card check at publish. One card of an answer about to go on screen, built
    /// again from the row the MAIN CONTEXT holds, never from the facts the answer was derived from (L70), and the
    /// answer with the fresh card in its place when they differ (C1: the correct card wins the render), or nil when
    /// they agree or there was no card to check. Throws when the row could not be read, which the engine counts
    /// rather than reading as agreement (L215). Nil for a derivation that builds no cards, which is every one but
    /// the queue's.
    var checkAtPublish: (@MainActor @Sendable (Value, ModelContext) throws -> QueueEngineCardCheck<Value>?)? = nil
    /// #4358 slice E4b: the verifier's comparison (iv), made on its own thread after the facts and the output agreed.
    /// Every card the answer built, built again from models a context of its own reads from `container`, by the
    /// field names that differ (C7), or none. Nil for a derivation that builds no cards.
    var compareCards: (@Sendable (Value, ModelContainer) throws -> [String])? = nil
}

/// What the card check at publish found: the fields that differ, by name only, how many cards the answer held, and
/// the answer with the fresh card in place of the one it built.
struct QueueEngineCardCheck<Value> {
    let fields: [String]
    let cardsBuilt: Int
    let corrected: Value
}

/// One published pass, and which store state and which pass it describes.
struct QueueEngineOutput<Value> {
    let value: Value
    let saveCount: Int
    let generation: Int
    let now: Date
    let reasons: Set<QueueEnginePassReason>
    /// #4358 slice E4b: the inputs that arrive by a signal, as they were read for this pass, so a verification
    /// rebuilds the output from exactly what it was derived from.
    let context: QueueEngineContextInputs
}

/// #4369 (#4358 slice E4b): one scout landing, open from `QueueEngine.openLanding()` until `closeLanding(_:)`, which
/// every landing entry point calls in a `defer` (the cutover, slice E4d, L514, L515).
struct QueueEngineLanding: Hashable, Sendable {
    /// The engine that opened it, by an identity minted at the engine's birth, never its address (L1019): every
    /// engine numbers its landings from 1, so the number alone cannot say whose landing this is.
    fileprivate let owner: UUID
    fileprivate let number: Int
}

/// #4358 slice E4b (plan item 12): what "Reload this show" did. Every case is produced by a test (L151).
enum QueueEngineReload: Equatable, Sendable, CaseIterable {
    /// The row was fetched again, and a read of the saved store through a context of its own now agrees with it.
    case reloaded
    /// The row is held and was not out of step, so there was nothing to reload.
    case alreadyInStep
    /// #4358 slice E4d: the engine holds no show by this identifier (it was deleted, or merged away, since the card
    /// was drawn), so nothing was compared and nothing was reloaded. Never `alreadyInStep`, which would claim a
    /// match nobody measured (L11).
    case notHeld
    /// The main context holds an unsaved edit on the row, which a fetch would not bring back and Dan would lose.
    case unsavedEdit
    /// The row was fetched again and still does not agree with the saved store. Recovery goes on trying.
    case stillOutOfStep
    /// The store no longer holds the row.
    case gone
    /// The fetch, or the read that checks it, threw. Never read as gone (L215).
    case unreadable
}

/// The clock the engine reads and sleeps on, injected so a test sets it rather than waiting (L524).
struct QueueEngineClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static let system = QueueEngineClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// The two notification centres the clock's own events arrive on. Wake is posted ONLY to the workspace's,
/// which a default-centre observer never hears (`SleepObserver`).
struct QueueEngineSystemEvents {
    let workspace: NotificationCenter
    let system: NotificationCenter

    @MainActor static var live: QueueEngineSystemEvents {
        QueueEngineSystemEvents(workspace: NSWorkspace.shared.notificationCenter, system: .default)
    }

    /// Each event, whether it is the workspace's, and the reason a pass it forces carries.
    static let events: [(name: Notification.Name, workspace: Bool, reason: QueueEnginePassReason)] = [
        (NSWorkspace.didWakeNotification, true, .wake),
        (.NSSystemClockDidChange, false, .systemClock),
        (.NSSystemTimeZoneDidChange, false, .timeZone),
        (.NSCalendarDayChanged, false, .calendarDay),
    ]
}

typealias QueueEngineSchedule = @MainActor (@escaping @MainActor () -> Void) -> Void

enum QueueEngineTurns {
    /// The app's schedule: the next main actor turn, so the engine never runs inside the call that asked for
    /// it, and every change made in the current turn is taken in by the same one.
    static func nextTurn(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    /// `work` on the main actor: at once when already there, else on its next turn.
    static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }

    /// What a refused generation does: stops a Debug build, and logs one line in Release.
    @MainActor static func refuse(published: Int, incoming: Int) {
        // copy-inventory:ignore-start  developer diagnostic log and a Debug stop, never shown to Dan (#4358)
        #if DEBUG
        preconditionFailure("queue engine output \(incoming) would replace \(published)")
        #else
        AgentLog.note("Queue engine refused output \(incoming), older than the published \(published).")
        #endif
        // copy-inventory:ignore-end
    }
}

/// The intake: what trackers and saves have reported since the last turn, by identity only. Written from any
/// thread, so behind a lock.
final class QueueEngineIntake: @unchecked Sendable {
    struct Pending: Sendable {
        /// Rows whose tracker fired. A fired tracker is spent, so these are re-armed when read.
        var fired: Set<PersistentIdentifier> = []
        /// Rows a caller holding the model said it changed (`QueueEngine.noteChanged`).
        var noted: Set<PersistentIdentifier> = []
        var inserted: Set<PersistentIdentifier> = []
        var updated: Set<PersistentIdentifier> = []
        var deleted: Set<PersistentIdentifier> = []
        /// Every identifier a save through ANOTHER context named, which the turn faults (decision 9(a)).
        var foreign: Set<PersistentIdentifier> = []

        var isEmpty: Bool {
            fired.isEmpty && noted.isEmpty && inserted.isEmpty && updated.isEmpty && deleted.isEmpty && foreign.isEmpty
        }
    }

    private let lock = NSLock()
    private var pending = Pending()
    private var wake: (@Sendable () -> Void)?

    func setWake(_ wake: @escaping @Sendable () -> Void) {
        lock.withLock { self.wake = wake }
    }

    func trackerFired(_ id: PersistentIdentifier) { take { $0.fired.insert(id) } }

    func noted(_ id: PersistentIdentifier) { take { $0.noted.insert(id) } }

    /// A save's identifiers, copied as handed over, and whether a context other than the engine's own made it.
    /// Reads no row.
    func saved(_ info: [AnyHashable: Any]?, foreign: Bool) {
        func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
            info?[key.rawValue] as? [PersistentIdentifier] ?? []
        }
        let inserted = ids(.insertedIdentifiers)
        let updated = ids(.updatedIdentifiers)
        let deleted = ids(.deletedIdentifiers)
        take {
            $0.inserted.formUnion(inserted)
            $0.updated.formUnion(updated)
            $0.deleted.formUnion(deleted)
            // Deletions too: a delete-only foreign save is still ATTRIBUTED, so it never falls to the full read
            // (the turn resolves deleted rows away, and faults none of them).
            if foreign { $0.foreign.formUnion(inserted + updated + deleted) }
        }
    }

    func drain() -> Pending {
        lock.withLock {
            defer { pending = Pending() }
            return pending
        }
    }

    // The wake is called OUTSIDE the lock, because on the main thread it asks for a turn synchronously.
    private func take(_ change: (inout Pending) -> Void) {
        let wake: (@Sendable () -> Void)? = lock.withLock {
            change(&pending)
            return self.wake
        }
        wake?()
    }
}

/// The engine's timers, one per job, each replacing the last of its kind.
enum QueueEngineTimer: Hashable, Sendable {
    /// The clock's one deadline (the next rule due, or the floor).
    case deadline
    /// Three seconds after an output with no other: the verifier's quiet moment.
    case quiet
    /// Ten minutes with no completed comparison.
    case unverified
    /// The next try at a faulted row.
    case recovery
}

/// Where the launch fill is: taking shows batch by batch, then the inquiries in one fetch, then waiting for the
/// shortfall check's identifier read, then done.
enum QueueEngineFillStep: Equatable {
    case shows
    case inquiries
    case checking
    case done
}

/// What the engine registered with notification centres and its timers, released when it goes.
private final class QueueEngineObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var timers: [QueueEngineTimer: Task<Void, Never>] = [:]

    func add(_ token: NSObjectProtocol, on center: NotificationCenter) {
        lock.withLock { tokens.append((center, token)) }
    }

    func replaceTimer(_ slot: QueueEngineTimer, _ task: Task<Void, Never>?) {
        let old: Task<Void, Never>? = lock.withLock {
            defer { timers[slot] = task }
            return timers[slot]
        }
        old?.cancel()
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
        for timer in timers.values { timer.cancel() }
    }
}

/// A reference to the engine that does not keep it alive, handed to the closures that fire on other threads.
private final class QueueEngineReference<Target: AnyObject>: @unchecked Sendable {
    weak var target: Target?

    init(_ target: Target) {
        self.target = target
    }
}

/// Where the verifier's durable records and its lifetime match count go: the existing divergence log and the
/// defaults beside `cardCheckLastRanAt` (plan v7 D7 and D8, one log rather than a second one beside it, L655).
struct QueueEngineVerifierLog {
    let url: URL
    let defaults: UserDefaults
}

/// How recovery brings one faulted row back to the saved values on the main context: true when the store still
/// holds it, false when it is gone (a fetch finding nothing is a deletion, decision 9(a)). `contacts` are the
/// contacts the engine holds under a show, fetched with it.
typealias QueueEngineRefetch = @MainActor (PersistentIdentifier, FactStore.Table, ModelContext,
                                           _ contacts: [PersistentIdentifier]) throws -> Bool

/// Whether the verifier runs on its own triggers, or only when asked.
enum QueueEngineVerifierTriggers: Sendable {
    /// Three seconds of quiet, every twenty outputs, and the ten minute timer (the app's, from the cutover).
    case automatic
    /// Only `verifyNow()`. The engine's gate, clock and intake suites, whose subject is not the verifier and
    /// which count the clock's sleepers; `QueueEngineVerifierTests` drives the automatic triggers.
    case byHand
}

/// Everything the verifier and recovery are built from, injected so a test can hand in a read that throws,
/// blocks or comes back short, and a refetch that never converges.
struct QueueEngineVerifierSetup {
    var triggers: QueueEngineVerifierTriggers = .automatic
    /// The fresh read, made on the verifier's thread through a context of its own.
    var read: @Sendable (ModelContainer) throws -> QueueEngineFreshRead = QueueEngineFreshRead.read
    var refetch: QueueEngineRefetch = QueueEngineRecovery.refetchByIdentifier
    /// The heal check's side: the recovered rows read through a context of its own, never the main one (L345).
    var healCheck: @MainActor (Set<PersistentIdentifier>, ModelContainer) throws -> FactStore = QueueEngineRecovery.readAlone
    /// Nil keeps the records in memory only (`verifierFindings`), for a test that does not ask about the file.
    var log: QueueEngineVerifierLog?
}

/// Everything the launch is built from, injected so a test can hand in a read that throws, blocks or comes back
/// short, an identifier read that fails, a batch that cannot be read, and an uptime it moves by hand.
struct QueueEngineLaunchSetup {
    /// Where the launch's two reads (the first output's and the shortfall check's) are made.
    enum Reads {
        /// On the launch thread, a serial queue outside the cooperative pool (L241) under
        /// `QueueEngineLaunchFill.deadlineSeconds` on the engine's clock: the app's.
        case onLaunchThread
        /// In the next scheduled turn, on the main actor: the engine's gate, clock, intake and verifier suites,
        /// which start the engine and run its turns by hand. Every other step of the launch is the app's own.
        case inTurn
    }

    var reads: Reads = .onLaunchThread
    var read: @Sendable (ModelContainer) throws -> QueueEngineFreshRead = QueueEngineFreshRead.read
    var identifiers: @Sendable (ModelContainer) throws -> Set<PersistentIdentifier> =
        QueueEngineLaunchFill.storedIdentifiers
    var fetchBatch: @MainActor (FetchDescriptor<Prospect>, ModelContext) throws -> [Prospect] = { try $1.fetch($0) }
    /// The shortfall's admission: the missing rows, fetched by identifier.
    var admit: @MainActor (Set<PersistentIdentifier>, ModelContext) throws
        -> (shows: [Prospect], inquiries: [Inquiry]) = QueueEngineLaunchSetup.fetchMissing
    var batchSize = QueueEngineLaunchFill.batchSize
    /// #4358 slice E4d: a press's look for a show the fill has not taken in yet, read from the store. A seam so the
    /// read that THROWS, which no fixture store can be made to do, can be produced (`readFailed`, L215).
    var pressRead: @MainActor (PersistentIdentifier, ModelContext) throws -> Prospect? = {
        try FactStore.Table.shows.liveRow($0, in: $1) as? Prospect
    }
    /// A monotonic clock in seconds, which each batch is timed on. Only measured, never decided from.
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// One fetch per model, each TYPED, and outside the generic engine: a loop over existential `PersistentModel`
    /// values inside that generic class crashes the compiler's IR generation in the app target (Xcode 26, measured
    /// in slice E2).
    @MainActor static func fetchMissing(_ ids: Set<PersistentIdentifier>, _ context: ModelContext) throws
        -> (shows: [Prospect], inquiries: [Inquiry]) {
        let shows = ids.filter { FactStore.Table.holding($0.entityName) == .shows }
        let inquiries = ids.filter { FactStore.Table.holding($0.entityName) == .inquiries }
        return (try FactStore.Table.fetched(Prospect.self, Array(shows), in: context),
                try FactStore.Table.fetched(Inquiry.self, Array(inquiries), in: context))
    }
}

enum QueueEngineRecovery {
    /// The recovery's one mechanism, the one probe 0b.4 proved: a FETCH by identifier on the main context, which
    /// brings a row holding no unsaved change back to the saved values. Never `rollback()`, whose fetched objects
    /// keep the discarded values (#4106 probe 0c.7).
    @MainActor static func refetchByIdentifier(_ id: PersistentIdentifier, _ table: FactStore.Table,
                                               _ context: ModelContext, _ contacts: [PersistentIdentifier]) throws -> Bool {
        guard let row = try table.fetch([id], in: context).first else { return false }
        var contactIDs = contacts
        if let show = row as? Prospect { contactIDs += show.factContacts.map(\.persistentModelID) }
        if !contactIDs.isEmpty { _ = try FactStore.Table.fetched(Recipient.self, contactIDs, in: context) }
        return true
    }

    /// The rows `ids` names, read through a throwaway context.
    @MainActor static func readAlone(_ ids: Set<PersistentIdentifier>, _ container: ModelContainer) throws -> FactStore {
        let checker = ModelContext(container)
        return try FactStore.extract(only: ids, from: checker)
    }

    /// Every model the main context holds an unsaved change on, by identity, and the shows of the contacts among
    /// them. Outside the generic engine on purpose: the same loop inside it crashes the compiler's IR generation
    /// for an existential `PersistentModel` (Xcode 26, measured building #4358 slice E2).
    @MainActor static func unsavedModels(in context: ModelContext)
        -> (ids: [PersistentIdentifier], contactShows: Set<PersistentIdentifier>) {
        var ids: [PersistentIdentifier] = []
        var shows: Set<PersistentIdentifier> = []
        for list in [context.changedModelsArray, context.insertedModelsArray, context.deletedModelsArray] {
            for model in list {
                ids.append(model.persistentModelID)
                if let contact = model as? Recipient, let show = contact.prospect { shows.insert(show.persistentModelID) }
            }
        }
        return (ids, shows)
    }
}

/// One verification in flight: the outputs published while it runs (D7's ring), and whether the engine stopped
/// it. Read from the verifier's thread, so behind a lock.
final class QueueEngineVerifierRun<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [QueueEngineSnapshot<Value>]
    private var stopped = false

    init(first: QueueEngineSnapshot<Value>) {
        ring = [first]
    }

    var snapshots: [QueueEngineSnapshot<Value>] { lock.withLock { ring } }
    var isCancelled: Bool { lock.withLock { stopped } }

    func cancel() { lock.withLock { stopped = true } }

    /// Keeps `snapshot`, or cancels the run when the ring is full: a run that has fallen that far behind the
    /// store would only ever be superseded.
    func add(_ snapshot: QueueEngineSnapshot<Value>) {
        lock.withLock {
            if ring.count >= QueueEngineVerifier.ringCapacity { stopped = true } else { ring.append(snapshot) }
        }
    }
}

@MainActor
@Observable
final class QueueEngine<Value: Sendable> {

    // MARK: - What it is built from

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let derivation: QueueEngineDerivation<Value>
    @ObservationIgnored private let saves: StoreSaveCount
    @ObservationIgnored private let clock: QueueEngineClock
    @ObservationIgnored private let events: QueueEngineSystemEvents
    @ObservationIgnored private let saveCenter: NotificationCenter
    @ObservationIgnored private let schedule: QueueEngineSchedule
    @ObservationIgnored private let refused: @MainActor (Int, Int) -> Void
    @ObservationIgnored private let intake = QueueEngineIntake()
    @ObservationIgnored private let observers = QueueEngineObservers()
    @ObservationIgnored private let verifierSetup: QueueEngineVerifierSetup
    /// The verifier's thread: a serial queue outside the cooperative pool with a deadline, which refuses a new
    /// item while one it gave up on is still running (the shared `BlockingWorkThread`, L241, L110).
    @ObservationIgnored private let verifierThread = BlockingWorkThread(name: "queue-verifier")
    /// The session the verifier's records carry (`CardDivergenceRecord.session`).
    @ObservationIgnored private let session = UUID().uuidString
    @ObservationIgnored private let launchSetup: QueueEngineLaunchSetup
    /// The launch's reads, on a thread of their own, so a read that never returns wedges neither the verifier
    /// nor anything else that shares one.
    @ObservationIgnored private let launchThread = BlockingWorkThread(name: "queue-launch")
    /// #4358 slice E4b: the inputs that arrive by a signal, read on the main actor whenever a pass derives.
    @ObservationIgnored private let contextInputs: @MainActor () -> QueueEngineContextInputs
    @ObservationIgnored private let landingSetup: QueueEngineLandingSetup

    // MARK: - What it keeps, keyed by identity (every one is in `identityKeyedState`)

    /// Every queue input as a value.
    @ObservationIgnored private(set) var facts = FactStore()
    /// #4360 (plan v7 Phase 4b): the terms kept patched between passes, brought up to `facts` before each pass.
    @ObservationIgnored private(set) var patches = QueueEnginePatches()
    /// The main context's rows the trackers are armed on, so a fired row is read again without a fetch.
    @ObservationIgnored private var showMembers: [PersistentIdentifier: Prospect] = [:]
    @ObservationIgnored private var contactMembers: [PersistentIdentifier: Recipient] = [:]
    @ObservationIgnored private var inquiryMembers: [PersistentIdentifier: Inquiry] = [:]
    /// Each contact's show as of the last read, so a contact that moves marks the show it LEFT as well as the
    /// one it joined.
    @ObservationIgnored private var recipientParent: [PersistentIdentifier: PersistentIdentifier] = [:]
    /// Rows with a tracker armed and not yet fired, so a row read for another reason is not armed twice.
    @ObservationIgnored private var armed: Set<PersistentIdentifier> = []
    /// Rows held under a TEMPORARY identifier (inserted, not yet saved), until their first save re-keys them.
    /// A re-keyed row is armed again under its permanent identifier in the same turn, so the tracker armed
    /// before the save, which still reports the temporary one, is only ever a stale fire, dropped unread.
    @ObservationIgnored private var temporaries: [PersistentIdentifier: any PersistentModel] = [:]
    /// The surface's own state (focused stage and leads, the cards the last frame drew).
    @ObservationIgnored private(set) var viewInputs = QueueEngineViewInputs()
    /// The context sources' signals by input name, once started.
    @ObservationIgnored private var signals: [String: ContextSignal] = [:]
    /// The context sources that fired since the last turn, by input name.
    @ObservationIgnored private var sourcesFired: Set<String> = []
    /// Rows known to be out of step with the store, and each one's recovery bounds (D7, decision 9).
    @ObservationIgnored private(set) var faults = QueueEngineFaults()
    /// The verification in flight, if any (single flight).
    @ObservationIgnored private var verification: QueueEngineVerifierRun<Value>?
    /// #4369: rows a landing's capped intake has not read yet, read first in the next turn.
    @ObservationIgnored private var carried: Set<PersistentIdentifier> = []
    /// #4358 slice E4d: rows whose look-up during the launch fill THREW, so a press on one is refused as unreadable.
    @ObservationIgnored private var failedReads: Set<PersistentIdentifier> = []

    // MARK: - The turn and the gate

    @ObservationIgnored private var started = false
    @ObservationIgnored private var turnScheduled = false
    @ObservationIgnored private var observedForeignSaves = 0
    @ObservationIgnored private var clockDue: Set<QueueEnginePassReason> = []
    @ObservationIgnored private var viewInputsMoved = false
    @ObservationIgnored private(set) var deadline: QueueEngineDeadline?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var counters = QueueEngineCounters()

    // MARK: - The landing (#4369)

    /// The landings open now, by number. A set rather than a count, so a landing closed twice cannot close another.
    @ObservationIgnored private var openLandings: Set<Int> = []
    @ObservationIgnored private var landingsOpened = 0
    /// Whose landings these are: a landing another engine opened closes nothing here.
    @ObservationIgnored private let landingOwner = UUID()
    /// The reasons turns held while a landing was open, carried into the one publish that follows.
    @ObservationIgnored private var heldReasons: Set<QueueEnginePassReason> = []
    /// Stored values "Reload this show" changed since the last turn, which that turn derives for at once.
    @ObservationIgnored private var changedByReload = 0

    // MARK: - The verifier's state

    @ObservationIgnored private(set) var verifierCounts = QueueEngineVerifierCounts()
    /// Every record the verifier and recovery wrote this session, newest last, at most `findingsKept`, whether or
    /// not a log file was handed in (the file applies the divergence log's cooldown; this keeps each one).
    @ObservationIgnored private(set) var verifierFindings: [CardDivergenceRecord] = []
    static var findingsKept: Int { 50 }
    @ObservationIgnored private var cooldown = CardDivergenceLog.Cooldown()
    @ObservationIgnored private var findingSequence = 0
    /// The generation the last verification started at, for "every twenty outputs".
    @ObservationIgnored private var verifiedAtGeneration = 0
    @ObservationIgnored private var verifyAgain = false
    /// Verifications in a row that reached no verdict and were retried, for the retries' back off and cap.
    @ObservationIgnored private var consecutiveRetries = 0
    /// The view the output on screen was derived for, which a verification compares at.
    @ObservationIgnored private var publishedViewInputs: QueueEngineViewInputs?
    /// An output mismatch with matching facts, waiting for the pass that heals it.
    @ObservationIgnored private var outputHealFields: [String]?

    // MARK: - The launch (D6, decision 4)

    @ObservationIgnored private var launchAttempts = 0
    @ObservationIgnored private var fillAttempts = 0
    /// The natural key of the last show the fill took: a POSITION in byte order, never an identity, so no deletion
    /// or rename touches it (a row renamed below it is the shortfall check's to find).
    @ObservationIgnored private var fillCursor: String?
    @ObservationIgnored private var fillStep: QueueEngineFillStep = .shows
    /// How far the fill has got and what each batch cost, read when asked (`launch` changes only on a transition).
    @ObservationIgnored private(set) var fillReport = QueueEngineFillReport()
    /// Stored values the shortfall check's admission changed, which the next turn derives for.
    @ObservationIgnored private var fillChanged = 0

    // MARK: - What it publishes

    /// The latest pass. The one property a surface observes.
    private(set) var output: QueueEngineOutput<Value>?
    /// Where the launch has got (D6), for the surface to show while nothing, or not everything, is ready.
    private(set) var launch = QueueEngineLaunchState()
    /// #4358 slice E4d (plan item 12): the shows the engine knows are out of step with the store, OBSERVED, so a card
    /// draws its "Reload this show" row the moment its show is faulted and drops it the moment it heals, whether or
    /// not a pass is published in between. Written only by `refreshOutOfStep`, and only when it changes.
    private(set) var outOfStepShows: Set<PersistentIdentifier> = []
    /// Every floor-only pass that changed the output, newest last, at most `floorChangesKept`.
    @ObservationIgnored private(set) var floorChanges: [QueueEngineFloorChange] = []
    static var floorChangesKept: Int { 50 }

    init(context: ModelContext,
         derivation: QueueEngineDerivation<Value>,
         saves: StoreSaveCount = .shared,
         clock: QueueEngineClock = .system,
         events: QueueEngineSystemEvents,
         saveCenter: NotificationCenter = .default,
         schedule: @escaping QueueEngineSchedule = QueueEngineTurns.nextTurn,
         refused: @escaping @MainActor (Int, Int) -> Void = QueueEngineTurns.refuse,
         verifier: QueueEngineVerifierSetup,
         launch: QueueEngineLaunchSetup,
         // No default, on `StageContext`'s rule: a reader nobody handed in would answer "nobody is a client" and
         // "Gmail is not connected" for every pass, which read as facts rather than as a missing input (L168).
         contextInputs: @escaping @MainActor () -> QueueEngineContextInputs,
         landing: QueueEngineLandingSetup = QueueEngineLandingSetup()) {
        self.context = context
        container = context.container
        verifierSetup = verifier
        launchSetup = launch
        self.contextInputs = contextInputs
        landingSetup = landing
        self.derivation = derivation
        self.saves = saves
        self.clock = clock
        self.events = events
        self.saveCenter = saveCenter
        self.schedule = schedule
        self.refused = refused
        let engine = QueueEngineReference(self)
        intake.setWake {
            QueueEngineTurns.onMain { engine.target?.scheduleTurn() }
        }
    }

    /// Starts watching the store and the clock, and begins the launch: the first read off the main thread, then
    /// the fill (D6). Saves are watched BEFORE the read, so no save can land between the two unseen. Once: a
    /// second call would register a second observer and double every intake.
    func start() {
        guard !started else { return }
        started = true
        let intake = self.intake
        let store = ObjectIdentifier(container)
        let own = ObjectIdentifier(context)
        observers.add(saveCenter.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            // A save into another store is not a change to this one (`StoreSaveCount` keeps them apart too).
            guard let saved = note.object as? ModelContext, ObjectIdentifier(saved.container) == store else { return }
            intake.saved(note.userInfo, foreign: ObjectIdentifier(saved) != own)
        }, on: saveCenter)
        let engine = QueueEngineReference(self)
        for event in QueueEngineSystemEvents.events {
            let center = event.workspace ? events.workspace : events.system
            let reason = event.reason
            observers.add(center.addObserver(forName: event.name, object: nil, queue: nil) { _ in
                QueueEngineTurns.onMain { engine.target?.clockEvent(reason) }
            }, on: center)
        }
        observedForeignSaves = saves.foreignSaveCount(for: container)
        armUnverifiedTimer()
        beginFirstRead()
    }

    /// The way on from a failed launch: the first read again when it failed, else the fill from where it stopped.
    /// Anything else is a launch that has not failed, and this does nothing.
    func retryLaunch() {
        if case .failed = launch.firstPaint {
            beginFirstRead()
        } else if case .failed = launch.fill {
            fillAttempts += 1
            launch.fill = .filling(since: clock.now())
            scheduleTurn()
        }
    }

    /// Starts the context sources' signals (`QueueContextSignals`); each one that fires forces a pass.
    func startSignals(_ sources: QueueContextSignals.Sources) {
        stopSignals()
        signals = QueueContextSignals.start(sources) { [weak self] input in self?.sourceFired(input) }
    }

    /// Stops them, so a polled one does not outlive the surface that started it.
    func stopSignals() {
        for signal in signals.values { signal.cancel() }
        signals = [:]
    }

    // MARK: - What callers tell it

    /// A change the store has not been told about, from a caller that holds the model: the show resolver
    /// (#4357, slice I2) marks every row an action touches, so an unsaved edit on a row with no tracker yet
    /// still reaches the next turn. Values are read in the turn, like every other change.
    func noteChanged(_ model: any PersistentModel) {
        holdIfTemporary(model)
        intake.noted(model.persistentModelID)
    }

    /// A context source moved (`QueueContextSignals` names it).
    func sourceFired(_ input: String) {
        sourcesFired.insert(input)
        scheduleTurn()
    }

    /// The surface's view. Handing in the same view is no reason for a pass (plan v2 Phase 4 step 2), and nor is
    /// asking for cards: #4358 slice E4d, the cards a frame drew are kept for the NEXT pass to prebuild and force
    /// none of their own. A card the pass did not build is built where it is drawn, from the values the pass's
    /// store holds, so a pass only to prebuild it costs the whole queue for nothing; measured on the hosted queue, a
    /// show revealed by one dismiss made every action two passes rather than one (`OneChangeDerivesTheQueueOnceTests`).
    func setViewInputs(_ inputs: QueueEngineViewInputs) {
        let moved = inputs.focusedStage != viewInputs.focusedStage || inputs.focusedKeys != viewInputs.focusedKeys
        viewInputs = inputs
        guard moved else { return }
        viewInputsMoved = true
        scheduleTurn()
    }

    /// Publishes `incoming` if it is newer than what is on screen, and arms the clock from it; otherwise refuses
    /// it (plan v2 Phase 4 step 3) and changes nothing. Every pass publishes through here, the launch's first output
    /// included; the recovery's passes are the turn's own. Returns whether it was applied, because only an
    /// applied output is a pass (L78). An applied output claims to describe the engine's facts as they stand, and
    /// is what the verifier compares with a fresh read.
    @discardableResult
    func publish(_ arriving: QueueEngineOutput<Value>) -> Bool {
        switch QueueEngineGenerations.verdict(published: output?.generation, incoming: arriving.generation) {
        case .apply:
            // The card check runs BEFORE the output goes on screen, so a card it proves wrong is never drawn (C1).
            let incoming = checkedCard(arriving)
            output = incoming
            // A number the engine did not mint moves the counter past it, so the next turn is not refused for it.
            generation = max(generation, incoming.generation)
            publishedViewInputs = viewInputs
            armDeadline(QueueEngineDeadline.next(now: incoming.now,
                                                 termNextChange: derivation.nextChange(incoming.value)))
            published(incoming)
            return true
        case .refuse(let published, let incoming):
            refused(published, incoming)
            return false
        }
    }

    /// One pass in the engine's own turn: the derivation's main actor form when it has one, so what a main-thread
    /// pass records is recorded, and the plain pass otherwise.
    private func mainPass(_ input: QueueEnginePassInput) -> Value {
        derivation.onTheMainActor?(input) ?? derivation.derive(input)
    }

    /// #4360: what the engine's own pass is handed: the facts, the view, the clock and the signals, and every patched
    /// term brought up to the facts first, from the shows that changed since the last pass (built cold the first time).
    /// #4363: and T7 to this pass's instant and signals, from the deadlines that passed and the fields that moved.
    private func passInput(now: Date, context: QueueEngineContextInputs) -> QueueEnginePassInput {
        patches.bringUp(to: facts, now: now, context: context)
        return QueueEnginePassInput(facts: facts, viewInputs: viewInputs, now: now, context: context, patches: patches)
    }

    /// The next generation, for an output whose inputs are being fixed NOW. Every publisher takes its number here
    /// (see "WHO NUMBERS AN OUTPUT" above), so no publisher's output can collide with another's.
    func mintGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Compares the facts and the output on screen with a fresh read now, whatever the triggers say. The cutover
    /// calls it when the launch fill ends (D6); a test calls it to produce each outcome. Single flight: a call
    /// while one runs asks for another after it.
    func verifyNow() {
        startVerification()
    }

    /// Whether the show resolver must refuse an action on `id`: its held value is known to be out of step with the
    /// store, and saving the main context's object would write the stale fields back (D7; read by #4357 slice I2).
    func isFaulted(_ id: PersistentIdentifier) -> Bool { faults.contains(id) }

    /// #4358 slice E4d: the main context the engine reads and every action saves through, for the host's own reads of
    /// the small tables the surfaces draw.
    var modelContext: ModelContext { context }

    /// Brings `outOfStepShows` to the faulted shows, writing only on a change so an unchanged set redraws nothing.
    func refreshOutOfStep() {
        let now = Set(faults.entries.keys.filter { FactStore.Table.holding($0.entityName) == .shows })
        if now != outOfStepShows { outOfStepShows = now }
    }

    /// How many rows are faulted, since when, and how many for over an hour (stuck), for the launch notice the
    /// cutover adds beside the verifier's match count (D7).
    var faultSummary: QueueEngineFaults.Summary { faults.summary(at: clock.now()) }

    // MARK: - The landing (#4369, plan item 4)

    /// Opens a landing: until every landing opened is closed, the intake reads at most the landing batch size of
    /// rows a turn and carries the rest, and no output is published unless Dan acts (a row an action noted, a view
    /// input, a reload), which then publishes his change with everything taken in so far. Every landing entry point
    /// opens one and closes it in a `defer` (the cutover, slice E4d), so a landing that throws still closes.
    func openLanding() -> QueueEngineLanding {
        landingsOpened += 1
        openLandings.insert(landingsOpened)
        return QueueEngineLanding(owner: landingOwner, number: landingsOpened)
    }

    /// Closes `landing`. When it was the last one open, a turn follows, which reads what is still carried a batch
    /// at a time and then publishes ONCE. Closing a landing twice, or one this engine did not open, does nothing.
    func closeLanding(_ landing: QueueEngineLanding) {
        guard landing.owner == landingOwner, openLandings.remove(landing.number) != nil,
              openLandings.isEmpty else { return }
        scheduleTurn()
    }

    /// Whether a landing holds the intake and the publish: one is open, or rows it brought are still carried.
    var isHoldingForALanding: Bool { !openLandings.isEmpty || !carried.isEmpty }

    // MARK: - Reload this show (plan item 12)

    /// "Reload this show": the recovery's own proven refetch (`QueueEngineRecovery.refetchByIdentifier`, #4106 probe
    /// 0b.4) for one faulted show, asked for by Dan rather than waited for, and checked the way recovery checks it,
    /// through a context of its own (L345). Refused, by name, while the main context holds an unsaved edit on the
    /// row: a fetch does not bring a dirty row back, and the edit is Dan's (decision 9(a)). A reload that changed a
    /// stored value is Dan acting, so the next turn publishes it even while a landing holds the queue.
    func reload(_ identity: ShowIdentity) -> QueueEngineReload {
        let id = identity.showID
        let now = clock.now()
        defer { refreshOutOfStep() }
        guard facts.shows[id] != nil else { return .notHeld }
        guard faults.contains(id) else { return .alreadyInStep }
        guard !rowsWithUnsavedChanges().contains(id) else { return .unsavedEdit }
        let contacts = recipientParent.filter { $0.value == id }.map(\.key)
        var resolution = QueueEngineResolution()
        var changed = 0
        let found: Bool
        do {
            found = try verifierSetup.refetch(id, .shows, context, contacts)
        } catch {
            counters.unreadRows.record(at: now)
            return .unreadable
        }
        if !found {
            // A fetch finding nothing is a deletion (decision 9(a)); the resolve step takes the fault with it.
            if remove(id, into: &resolution) { changed += 1 }
            resolveIdentities(resolution)
            reloaded(changed)
            return .gone
        }
        if readRow(id, table: .shows, now: now, into: &resolution) { changed += 1 }
        resolveIdentities(resolution)
        faults.attempted([id], at: now)
        reloaded(changed)
        let stored: FactStore
        do {
            stored = try verifierSetup.healCheck([id], container)
        } catch {
            // The check could not be read, which says nothing about the row (L11).
            counters.unreadRows.record(at: now)
            return .unreadable
        }
        guard facts.sameRow(id, as: stored), let entry = faults.healed(id) else { return .stillOutOfStep }
        verifierCounts.healed += 1
        writeFinding(.healed, fields: entry.fields, at: now)
        armRecoveryTimer()
        return .reloaded
    }

    private func reloaded(_ changed: Int) {
        guard changed > 0 else { return }
        changedByReload += changed
        scheduleTurn()
    }

    // MARK: - The turn

    private func scheduleTurn() {
        guard !turnScheduled else { return }
        turnScheduled = true
        schedule { [weak self] in self?.runTurn() }
    }

    /// Takes in what changed, then derives and publishes only when a reason holds (the generation gate).
    private func runTurn() {
        turnScheduled = false
        defer { refreshOutOfStep() }
        // Nothing is taken in or derived before the launch's first read lands: a pass now would publish an empty
        // queue (D6). What the intake holds meanwhile waits for the first turn after it.
        guard case .ready = launch.firstPaint else { return }
        // The fill's next step, if it has one, gets the next turn: one batch per turn, never the table in one. So
        // do rows a landing's capped intake carried (#4369).
        defer { if fillWantsATurn || !carried.isEmpty { scheduleTurn() } }
        counters.turns += 1
        let now = clock.now()
        drainHeldRepeats(at: now)
        let saveCount = saves.value(for: container)
        let filled = fillTurn(now: now)
        let intook = intakeTurn(now: now)
        let reloadChanged = changedByReload
        changedByReload = 0
        // Recovery runs after the intake, so a faulted row a save touched this turn is tried again at once.
        let changed = filled + intook.changed + reloadChanged + recover(now: now, touched: intook.touched)
        counters.rowsChanged += changed
        var reasons = clockDue
        clockDue = []
        if changed > 0 { reasons.insert(.factsChanged) }
        if !sourcesFired.isEmpty { reasons.insert(.sourceFired) }
        sourcesFired = []
        if viewInputsMoved { reasons.insert(.viewInputs) }
        // Dan acted when an action noted a row, the surface asked for a different view, or he reloaded a show.
        let danActed = intook.danActed || viewInputsMoved || reloadChanged > 0
        viewInputsMoved = false
        let healing = outputHealFields
        if healing != nil { reasons.insert(.recovery) }
        // #4369 (decision 8, C4): while a landing holds the queue, nothing is published unless Dan acted, so every
        // surface waits for one redraw at the end. What a held turn had a reason to derive is kept for that redraw.
        if isHoldingForALanding, !danActed {
            if !reasons.isEmpty {
                heldReasons.formUnion(reasons)
                counters.heldTurns += 1
            }
            return
        }
        reasons.formUnion(heldReasons)
        heldReasons = []
        guard !reasons.isEmpty else { return }
        let context = contextInputs()
        let value = mainPass(passInput(now: now, context: context))
        let previous = output
        guard publish(QueueEngineOutput(value: value, saveCount: saveCount, generation: mintGeneration(), now: now,
                                        reasons: reasons, context: context)) else {
            // Unreachable while every publisher mints: a minted number is newer than everything published, minted
            // or not. `publish` has already reported the refusal (a Debug stop), and an output never applied is no
            // pass (L78).
            return
        }
        counters.passes += 1
        if let healing {
            outputHealFields = nil
            verifierCounts.healed += 1
            writeFinding(.healed, fields: healing, at: now)
        }
        if reasons == [.clockFloor], let previous {
            let fields = derivation.differingFields(previous.value, value)
            if !fields.isEmpty {
                floorChanges.append(QueueEngineFloorChange(fields: fields, at: now, generation: generation))
                if floorChanges.count > Self.floorChangesKept { floorChanges.removeFirst() }
            }
        }
    }

    // MARK: - The launch (D6, decision 4)

    /// Starts one attempt at the first output. Its inputs are fixed HERE, before the read: the save count, so the
    /// output never claims a save that landed during the read (the verifier compares at exactly that count), and the
    /// generation, so a turn published after it is never replaced by these older inputs (E2's `mintGeneration`).
    private func beginFirstRead() {
        launchAttempts += 1
        let attempt = launchAttempts
        launch.firstPaint = .loading(since: clock.now(), attempt: attempt)
        let saveCount = saves.value(for: container)
        let generation = mintGeneration()
        let read = launchSetup.read
        let container = self.container
        offMain({ try read(container) }) { [weak self] result in
            // An answer to an attempt a retry has replaced is not this launch's.
            guard let self, self.launchAttempts == attempt else { return }
            self.landFirstRead(result, saveCount: saveCount, generation: generation, attempt: attempt)
        }
    }

    /// The first read's answer: the first output, published, or the reason there is none.
    private func landFirstRead(_ result: Result<QueueEngineFreshRead, QueueEngineLaunchFailure>, saveCount: Int,
                               generation: Int, attempt: Int) {
        let now = clock.now()
        let fresh: QueueEngineFreshRead
        switch result {
        case .failure(let why):
            launch.firstPaint = .failed(why, attempts: attempt, at: now)
            return
        case .success(let read):
            fresh = read
        }
        guard !fresh.isShort else {
            launch.firstPaint = .failed(.shortRead, attempts: attempt, at: now)
            return
        }
        counters.fullReads += 1
        facts = fresh.facts
        // #4360: replaced whole, so every patched term is built cold by the pass below.
        patches.invalidate()
        // This pass is the one every reason gathered while loading asked for: the clock's, a source's, the view's.
        clockDue = []
        sourcesFired = []
        viewInputsMoved = false
        let context = contextInputs()
        let value = mainPass(passInput(now: now, context: context))
        // Nothing is on screen yet, so the gate applies it whatever its number.
        publish(QueueEngineOutput(value: value, saveCount: saveCount, generation: generation, now: now,
                                  reasons: [.first], context: context))
        counters.passes += 1
        launch.firstPaint = .ready(at: now, attempts: attempt)
        fillAttempts = 1
        launch.fill = .filling(since: now)
        scheduleTurn()
    }

    /// Whether the fill's next step needs a turn of its own: a batch, or the inquiries.
    private var fillWantsATurn: Bool {
        guard case .filling = launch.fill else { return false }
        return fillStep == .shows || fillStep == .inquiries
    }

    /// The fill's step in this turn, and whatever the shortfall check admitted since the last one. Returns how many
    /// stored values it changed.
    private func fillTurn(now: Date) -> Int {
        var changed = fillChanged
        fillChanged = 0
        guard case .filling = launch.fill else { return changed }
        var resolution = QueueEngineResolution()
        switch fillStep {
        case .shows: changed += fillShows(now: now, into: &resolution)
        case .inquiries: changed += fillInquiries(now: now, into: &resolution)
        case .checking, .done: break
        }
        resolveIdentities(resolution)
        return changed
    }

    /// One keyset batch of shows after the cursor, each held, armed and recorded, timed against the budget.
    private func fillShows(now: Date, into resolution: inout QueueEngineResolution) -> Int {
        let started = launchSetup.uptime()
        let batch: [Prospect]
        do {
            batch = try launchSetup.fetchBatch(QueueEngineLaunchFill.batch(after: fillCursor,
                                                                           limit: launchSetup.batchSize), context)
        } catch {
            fillFailed(at: now)
            return 0
        }
        var changed = 0
        for show in batch where take(show, show.persistentModelID, into: &resolution) { changed += 1 }
        if let last = batch.last { fillCursor = last.naturalKey }
        fillReport.shows += batch.count
        fillReport.batches += 1
        fillReport.batchSeconds.append(launchSetup.uptime() - started)
        if batch.count < launchSetup.batchSize { fillStep = .inquiries }
        return changed
    }

    /// Every inquiry in one fetch (they have no stored unique key to page on), then the shortfall check.
    private func fillInquiries(now: Date, into resolution: inout QueueEngineResolution) -> Int {
        let started = launchSetup.uptime()
        let inquiries: [Inquiry]
        do {
            inquiries = try context.fetch(FetchDescriptor<Inquiry>())
        } catch {
            fillFailed(at: now)
            return 0
        }
        var changed = 0
        for inquiry in inquiries where take(inquiry, inquiry.persistentModelID) { changed += 1 }
        fillReport.inquiries = inquiries.count
        fillReport.inquirySeconds = launchSetup.uptime() - started
        fillStep = .checking
        let identifiers = launchSetup.identifiers
        let container = self.container
        offMain({ try identifiers(container) }) { [weak self] result in self?.finishFill(result) }
        return changed
    }

    /// A step that could not be read stops the fill, counted, with the output left on screen (L215: a failed read
    /// is not an empty table). `retryLaunch()` resumes it at the same step.
    private func fillFailed(at now: Date) {
        counters.unreadRows.record(at: now)
        launch.fill = .failed(.readFailed, attempts: fillAttempts, at: now)
    }

    /// The shortfall check's answer (D6, L16, L211): every row the store holds that no member is was skipped by
    /// the keyset and reached by no change since, so one fetch admits them all and the count is recorded. Then the
    /// fill is done, and the first verification is forced.
    private func finishFill(_ result: Result<Set<PersistentIdentifier>, QueueEngineLaunchFailure>) {
        let now = clock.now()
        switch result {
        case .failure(let why):
            fillReport.shortfall = .unmeasured(why)
        case .success(let stored):
            let missing = stored.subtracting(showMembers.keys).subtracting(inquiryMembers.keys)
            if missing.isEmpty {
                fillReport.shortfall = .measured(missing: 0, admitted: 0)
            } else {
                do {
                    let found = try launchSetup.admit(missing, context)
                    var resolution = QueueEngineResolution()
                    for show in found.shows where take(show, show.persistentModelID, into: &resolution) {
                        fillChanged += 1
                    }
                    for inquiry in found.inquiries where take(inquiry, inquiry.persistentModelID) { fillChanged += 1 }
                    resolveIdentities(resolution)
                    // A missing row the fetch did not find was deleted since; one it found is admitted.
                    fillReport.shortfall = .measured(missing: missing.count,
                                                     admitted: found.shows.count + found.inquiries.count)
                } catch {
                    // A failed fetch is not a deletion (L215): the rows are stored and not held, said so. The
                    // verifier's fresh read finds them, and recovery takes them from there.
                    counters.unreadRows.record(at: now)
                    fillReport.shortfall = .unadmitted(missing: missing.count, .readFailed)
                }
            }
        }
        fillStep = .done
        launch.fill = .done(fillReport)
        // D6: the first verification is forced when the fill ends, rather than left to the next quiet moment. One of
        // the automatic triggers, so a suite that verifies only by hand is not handed one it did not ask for. It
        // takes the place of the quiet timer the first output armed, which would otherwise verify the same output
        // again three seconds later.
        if verifierSetup.triggers == .automatic {
            observers.replaceTimer(.quiet, nil)
            verifyNow()
        }
        if fillChanged > 0 { scheduleTurn() }
    }

    /// `work` off the main actor, its answer handed back on it: on the launch thread under its deadline, or, for
    /// the suites that run the engine's turns by hand, in the next scheduled turn.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T,
                                      then: @escaping @MainActor (Result<T, QueueEngineLaunchFailure>) -> Void) {
        switch launchSetup.reads {
        case .inTurn:
            schedule { then(Result { try work() }.mapError(QueueEngineLaunchFailure.from)) }
        case .onLaunchThread:
            let thread = launchThread
            let clock = self.clock
            Task { @MainActor in
                let result: Result<T, QueueEngineLaunchFailure>
                do {
                    result = .success(try await thread.run(deadlineSeconds: QueueEngineLaunchFill.deadlineSeconds,
                                                           sleep: { try? await clock.sleep($0) }, work))
                } catch {
                    result = .failure(.from(error))
                }
                then(result)
            }
        }
    }

    // MARK: - Intake and the resolve step

    /// Takes in what the intake holds, resolves identities, and reads again every row it names, at most a landing
    /// batch of them while a landing holds the intake. Returns how many stored values changed, the rows (as the
    /// FactStore keys them) the intake named, and whether an action Dan took noted one.
    private func intakeTurn(now: Date) -> (changed: Int, touched: Set<PersistentIdentifier>, danActed: Bool) {
        let pending = intake.drain()
        var resolution = QueueEngineResolution()
        for (temporary, model) in temporaries {
            if !StoreRows.isLive(model) {
                resolution.deletedIDs.insert(temporary)
            } else if model.persistentModelID != temporary {
                resolution.rekeyedIDs[temporary] = model.persistentModelID
            }
        }
        resolution.deletedIDs.formUnion(pending.deleted)
        // A show's contacts go with it.
        for (contact, show) in recipientParent where resolution.deletedIDs.contains(show) {
            resolution.deletedIDs.insert(contact)
        }
        var shows: Set<PersistentIdentifier> = []
        var inquiries: Set<PersistentIdentifier> = []
        var small: Set<PersistentIdentifier> = []
        var everything = false
        for id in resolution.deletedIDs {
            if let row = facts.shows[id] { resolution.deletedKeys.insert(row.naturalKey) }
            // A contact deleted on its own changes the show it sat under.
            if Self.isContact(id), let show = recipientParent[id], !resolution.deletedIDs.contains(show) {
                shows.insert(show)
            }
        }
        var changed = resolution.deletedIDs.filter(facts.holds).count
        resolveIdentities(resolution)

        // An identifier reported before the save that re-keyed it in this turn reads as its permanent one. A
        // temporary one that no row holds any more is a stale fire, from a tracker armed before an earlier save
        // re-keyed its row, which was armed again under its permanent identifier then: it is dropped unread.
        let rekeyed = resolution.rekeyedIDs
        let temporaries = self.temporaries
        func current(_ id: PersistentIdentifier) -> PersistentIdentifier? {
            if let permanent = rekeyed[id] { return permanent }
            return id.storeIdentifier == nil && temporaries[id] == nil ? nil : id
        }
        let fired = Set(pending.fired.compactMap(current))
        armed.subtract(fired)
        // A re-keyed row is read again below and armed afresh under its permanent identifier, so no tracker is
        // left that only the temporary one could name.
        armed.subtract(rekeyed.values)
        let touched = fired.union(pending.noted.compactMap(current)).union(pending.inserted.compactMap(current))
            .union(pending.updated.compactMap(current)).union(rekeyed.values)
        for id in touched where !resolution.deletedIDs.contains(id) {
            switch AppSchemaInputClass.byModel[id.entityName] {
            case .perRowFact(parent: nil, _):
                if FactStore.Table.holding(id.entityName) == .shows { shows.insert(id) } else { inquiries.insert(id) }
            case .perRowFact(parent: _?, _):
                if let previous = recipientParent[id] { shows.insert(previous) }
                if let contact = liveContact(id), let show = contact.prospect { shows.insert(show.persistentModelID) }
            case .smallTableInput:
                small.insert(id)
            case .notAQueueInput:
                continue
            case nil:
                counters.unclassifiedSaves.record(at: now)
                everything = true
            }
        }
        // A row a save names as INSERTED that the store does not hold, and no save deleted, was merged into a
        // row already stored that shares its unique key. That row changed IN PLACE, the save did not name it,
        // and no tracker fired; the newcomer stays registered in the context and reads as live (#4106 probe 2;
        // measured for #4358 in memory and on disk: the save names only the newcomer's identifier, and only a
        // FETCH by it finds nothing). Which row it was cannot be read from here, so everything is read again.
        let inserted = Set(pending.inserted.compactMap(current)).subtracting(resolution.deletedIDs)
            .filter { FactStore.Table.holding($0.entityName) != nil }
        if !everything, !inserted.isEmpty {
            do {
                if try FactStore.storedIdentifiers(among: inserted, in: context) != inserted {
                    counters.insertsMergedAway.record(at: now)
                    everything = true
                }
            } catch {
                // A failed read is not a merge, and not nothing either (L215): read everything, counted.
                counters.unreadRows.record(at: now)
                everything = true
            }
        }
        // A save through ANOTHER context (decision 9(a)). The main context's own copies of what it touched may be
        // stale (#4106 probe 2), so those rows are FAULTED, and recovery fetches each one again in this same turn
        // once the main context holds no unsaved change for it. The identifiers come from the save itself; the
        // counter, a separate source, is the net under them (L345): it moving with no identifier attributed
        // means a save this observer never saw, and only then is every row read again.
        let foreignRows = rowsOwning(pending.foreign.compactMap(current)).subtracting(resolution.deletedIDs)
        if !foreignRows.isEmpty {
            // Each row is faulted under its TABLE's name, the one the foreignSave record carries, so the heal or the
            // give-up that follows names what was faulted rather than a placeholder word.
            faults.admit(Dictionary(uniqueKeysWithValues: foreignRows.map { id in
                (id, FactStore.Table.holding(id.entityName).map { ["\($0)"] } ?? [])
            }), origin: .foreignSave, at: now)
            writeFinding(.foreignSave, fields: foreignRows.compactMap { FactStore.Table.holding($0.entityName) }
                            .map { "\($0)" }, at: now)
        }
        let foreign = saves.foreignSaveCount(for: container)
        if foreign != observedForeignSaves {
            observedForeignSaves = foreign
            counters.foreignSaves.record(at: now)
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#4358)
            AgentLog.note("Queue engine faulted the rows a save through another context touched "
                          + "(\(counters.foreignSaves.times) this session).")
            // copy-inventory:ignore-end
            if pending.foreign.isEmpty { everything = true }
        }

        var second = QueueEngineResolution()
        // The rows an action Dan took noted, as the FactStore keys them: read first, whatever a landing's cap says.
        let actedOn = rowsOwning(pending.noted.compactMap(current))
        if everything {
            // Every row is read, so nothing a landing carried is still owed.
            carried = []
            changed += readEverything(into: &second)
        } else {
            for id in rowsThisTurn(shows.union(inquiries).union(small), actedOn: actedOn) {
                guard let table = FactStore.Table.holding(id.entityName) else { continue }
                if readRow(id, table: table, now: now, into: &second) { changed += 1 }
            }
        }
        resolveIdentities(second)
        return (changed, shows.union(inquiries).union(small).union(foreignRows), !pending.noted.isEmpty)
    }

    /// The rows this turn reads: every one named, and every one a landing carried. While a landing holds the intake
    /// (#4369), at most `landingSetup.batchSize`, Dan's own first and always, the rest in identifier order so a
    /// carry is deterministic; what does not fit is carried to the next turn, which `runTurn` asks for.
    private func rowsThisTurn(_ named: Set<PersistentIdentifier>,
                              actedOn: Set<PersistentIdentifier>) -> [PersistentIdentifier] {
        let holding = isHoldingForALanding
        let all = named.union(carried)
        carried = []
        guard holding else { return Array(all) }
        let first = all.intersection(actedOn)
        let rest = all.subtracting(first).sorted()
        let room = max(0, landingSetup.batchSize - first.count)
        carried = Set(rest.dropFirst(room))
        let taken = Array(first) + rest.prefix(room)
        if !taken.isEmpty { counters.landingBatches += 1 }
        return taken
    }

    /// The rows, as the FactStore keys them, that `ids` belong to: a contact's is its show's, and a model the pass
    /// never reads belongs to none.
    private func rowsOwning(_ ids: [PersistentIdentifier]) -> Set<PersistentIdentifier> {
        var rows: Set<PersistentIdentifier> = []
        for id in ids {
            if Self.isContact(id) {
                if let show = recipientParent[id] ?? liveContact(id)?.prospect?.persistentModelID { rows.insert(show) }
            } else if FactStore.Table.holding(id.entityName) != nil {
                rows.insert(id)
            }
        }
        return rows
    }

    // MARK: - Recovery (D7, decision 9)

    /// Tries every faulted row that is due: one whose main-context object holds an unsaved change is left alone
    /// and counted once (`waitedForEdit`), because a fetch does not refresh a dirty row and the edit is Dan's (#4106
    /// probe 0b.4); every other is fetched again by identifier and read as any change is. Then a throwaway context
    /// reads the same rows, and each that now equals it is healed; each that does not has failed one attempt.
    /// Returns how many stored values the recovery changed.
    private func recover(now: Date, touched: Set<PersistentIdentifier>) -> Int {
        let due = faults.due(at: now, touched: touched)
        guard !due.isEmpty else {
            // Nothing is due yet, which may be the hour's cap: the next wake still comes from the fault set.
            armRecoveryTimer()
            return 0
        }
        let dirty = rowsWithUnsavedChanges()
        var changed = 0
        var tried: Set<PersistentIdentifier> = []
        var resolution = QueueEngineResolution()
        for id in due {
            guard !dirty.contains(id) else {
                if faults.waitingForEdit(id) { verifierCounts.waitedForEdit += 1 }
                continue
            }
            guard let table = FactStore.Table.holding(id.entityName) else { continue }
            let contacts = recipientParent.filter { $0.value == id }.map(\.key)
            do {
                if try verifierSetup.refetch(id, table, context, contacts) {
                    if readRow(id, table: table, now: now, into: &resolution) { changed += 1 }
                } else if remove(id, into: &resolution) {
                    changed += 1
                }
            } catch {
                // A failed fetch is not a deletion (L215), and not a heal either: it is a failed attempt.
                counters.unreadRows.record(at: now)
            }
            tried.insert(id)
        }
        resolveIdentities(resolution)
        faults.attempted(tried, at: now)
        guard !tried.isEmpty else {
            armRecoveryTimer()
            return changed
        }
        // The heal check's side, through a context of its own and never the main one it is checking (L345).
        let stored: FactStore
        do {
            stored = try verifierSetup.healCheck(tried, container)
        } catch {
            // The check could not be read, which measures nothing about the rows (L11): no heal and no failed
            // attempt, so a failed read can never be recorded as a row that would not converge.
            counters.unreadRows.record(at: now)
            armRecoveryTimer()
            return changed
        }
        for id in tried {
            if facts.sameRow(id, as: stored) {
                if let entry = faults.healed(id) {
                    verifierCounts.healed += 1
                    writeFinding(.healed, fields: entry.fields, at: now)
                }
            } else if let entry = faults.failed(id, at: now) {
                verifierCounts.healDidNotConverge += 1
                writeFinding(.healDidNotConverge, fields: entry.fields, at: now)
            }
        }
        armRecoveryTimer()
        return changed
    }

    /// The rows, as the FactStore keys them, whose main-context object holds an unsaved change, read from the
    /// context's own lists and never from anything the engine marked (L345).
    private func rowsWithUnsavedChanges() -> Set<PersistentIdentifier> {
        guard context.hasChanges else { return [] }
        let unsaved = QueueEngineRecovery.unsavedModels(in: context)
        return rowsOwning(unsaved.ids).union(unsaved.contactShows)
    }

    private func readRow(_ id: PersistentIdentifier, table: FactStore.Table, now: Date,
                         into resolution: inout QueueEngineResolution) -> Bool {
        switch table {
        case .shows: return readShow(id, now: now, into: &resolution)
        case .inquiries: return readInquiry(id, now: now, into: &resolution)
        default: return readSmallTableRow(id, now: now, into: &resolution)
        }
    }

    /// Asks for a turn when the next try at a faulted row comes due: soon while a round is open, else at the
    /// retry interval. A save touching a faulted row asks for its own turn sooner.
    private func armRecoveryTimer() {
        let now = clock.now()
        guard let next = faults.nextTry(at: now) else {
            observers.replaceTimer(.recovery, nil)
            return
        }
        armTimer(.recovery, after: next.timeIntervalSince(now)) { $0.scheduleTurn() }
    }

    // MARK: - The verifier (D7)

    /// After an applied output: kept in the ring of a verification in flight, or the verifier's triggers armed.
    private func published(_ incoming: QueueEngineOutput<Value>) {
        if let verification {
            verification.add(snapshot(of: incoming))
            return
        }
        guard verifierSetup.triggers == .automatic else { return }
        // A new output starts a new episode: the store moved, so runs that could not say before say nothing about
        // this one, and an episode that is stuck again is capped, and recorded, again (L710).
        consecutiveRetries = 0
        if generation - verifiedAtGeneration >= QueueEngineVerifier.forcedEveryGenerations {
            startVerification()
        } else {
            let at = generation
            armTimer(.quiet, after: QueueEngineVerifier.quietSeconds) { engine in
                // Quiet means no output since: a newer one re-armed this timer and this one is stale.
                if engine.generation == at { engine.startVerification() }
            }
        }
    }

    private func snapshot(of output: QueueEngineOutput<Value>) -> QueueEngineSnapshot<Value> {
        // #4360: the patched terms brought up to the facts this snapshot carries, so the verifier holds each term to
        // its oracle over the same store the facts are compared with (a landing can hold facts no pass has read yet).
        patches.bringUp(to: facts)
        return QueueEngineSnapshot(saveCount: output.saveCount, generation: output.generation, facts: facts,
                                   viewInputs: publishedViewInputs ?? viewInputs, context: output.context,
                                   now: output.now, value: output.value, clean: !context.hasChanges, patches: patches)
    }

    /// The card check at publish (#4357 step 9): the output as it should go on screen, with the card the check
    /// proved wrong replaced (C1), and the finding recorded and counted. Unchanged when the derivation builds no
    /// cards or the card agrees.
    private func checkedCard(_ incoming: QueueEngineOutput<Value>) -> QueueEngineOutput<Value> {
        guard let check = derivation.checkAtPublish else { return incoming }
        let checked: QueueEngineCardCheck<Value>?
        do {
            checked = try check(incoming.value, context)
        } catch {
            counters.unreadRows.record(at: incoming.now)
            return incoming
        }
        guard let found = checked else { return incoming }
        verifierCounts.cardDivergences += 1
        writeFinding(.cardDivergence, fields: found.fields, at: incoming.now, judged: incoming.generation,
                     cardsBuilt: found.cardsBuilt)
        return QueueEngineOutput(value: found.corrected, saveCount: incoming.saveCount, generation: incoming.generation,
                                 now: incoming.now, reasons: incoming.reasons, context: incoming.context)
    }

    private func startVerification() {
        guard verification == nil else {
            verifyAgain = true
            return
        }
        guard let output else { return }
        verifiedAtGeneration = generation
        verifierCounts.started += 1
        // The held facts include the main context's unsaved edits and a fresh read sees only what is saved, so
        // nothing comparable can be read while it holds one.
        guard !context.hasChanges else {
            finishVerification(.unmeasured(.busy))
            return
        }
        let run = QueueEngineVerifierRun(first: snapshot(of: output))
        verification = run
        let container = self.container
        let saves = self.saves
        let read = verifierSetup.read
        let derivation = self.derivation
        let thread = verifierThread
        let clock = self.clock
        Task { [weak self] in
            let result: QueueEngineVerification
            do {
                result = try await thread.run(deadlineSeconds: QueueEngineVerifier.deadlineSeconds,
                                              sleep: { try? await clock.sleep($0) }) {
                    QueueEngineVerifier.verify(container: container, saves: saves, read: read, ring: { run.snapshots },
                                               derivation: derivation, cancelled: { run.isCancelled })
                }
            } catch {
                result = .unmeasured(QueueEngineVerifier.unmeasured(by: error))
            }
            guard let self, self.verification === run else { return }
            self.verification = nil
            self.finishVerification(result)
        }
    }

    private func finishVerification(_ result: QueueEngineVerification) {
        let now = clock.now()
        defer { refreshOutOfStep() }
        switch result {
        case .match:
            verifierCounts.matches += 1
            verifierCounts.lastMatchedAt = now
            if let log = verifierSetup.log {
                log.defaults.set(log.defaults.integer(forKey: CardDivergenceLog.verifierMatchCountKey) + 1,
                                 forKey: CardDivergenceLog.verifierMatchCountKey)
                log.defaults.set(now, forKey: CardDivergenceLog.verifierLastMatchedKey)
            }
            armUnverifiedTimer()
        case .factMismatch(let rows, let judged):
            verifierCounts.factMismatches += 1
            writeFinding(.factMismatch, fields: rows.values.flatMap { $0 }, at: now, judged: judged)
            faults.admit(rows, origin: .verifier, at: now)
            armUnverifiedTimer()
            scheduleTurn()
        case .cardMismatch(let fields, let judged):
            // Comparison (iv): the facts and the output agreed with the store, and a card built from them did not
            // agree with the same card built from the saved show. The term disagrees with itself over facts and
            // over models, which no refetch can heal, so it is recorded and counted, never faulted.
            verifierCounts.cardMismatches += 1
            writeFinding(.cardMismatch, fields: fields, at: now, judged: judged)
            armUnverifiedTimer()
        case .outputMismatch(let fields, let judged):
            verifierCounts.outputMismatches += 1
            writeFinding(.outputMismatch, fields: fields, at: now, judged: judged)
            // The facts agree, so a pass over them is the heal and carries no stale object (D7).
            outputHealFields = fields
            armUnverifiedTimer()
            scheduleTurn()
        case .patchMismatch(let fields, let judged):
            // #4360: the facts agreed and a patched term did not equal its oracle over them, so the term missed a
            // change. Its heal is a cold build from the facts, in the pass that publishes the heal.
            verifierCounts.patchMismatches += 1
            writeFinding(.patchMismatch, fields: fields, at: now, judged: judged)
            patches.invalidate()
            outputHealFields = fields
            armUnverifiedTimer()
            scheduleTurn()
        case .superseded:
            verifierCounts.superseded += 1
        case .cancelled:
            verifierCounts.cancelled += 1
        case .unmeasured(let why):
            verifierCounts.unmeasured[why, default: 0] += 1
            switch why {
            case .timedOut: writeFinding(.verifierTimedOut, fields: [], at: now)
            case .wedged: writeFinding(.verifierWedged, fields: [], at: now)
            case .busy, .readFailed, .shortRead: break
            }
        }
        // Asked again while this ran, or this one could not say, or it judged an output older than the one now
        // on screen: once more after the next quiet moment (L710).
        let verdict: Bool
        switch result {
        case .match, .factMismatch, .outputMismatch, .cardMismatch, .patchMismatch: verdict = true
        case .superseded, .cancelled, .unmeasured: verdict = false
        }
        if verdict { consecutiveRetries = 0 }
        if QueueEngineVerifier.needsAnother(after: result, onScreen: output?.generation) { verifyAgain = true }
        guard verifyAgain, verifierSetup.triggers == .automatic else { return }
        verifyAgain = false
        var delay = QueueEngineVerifier.quietSeconds
        if !verdict {
            // Runs that cannot say, in a row, back off and then stop (L704): each is a whole read of the store, and
            // saves landing during every read would otherwise repeat it every three seconds for as long as they
            // went on. The next output's own quiet moment, or a verdict, starts it again.
            consecutiveRetries += 1
            guard let backoff = QueueEngineVerifier.retryDelay(afterConsecutive: consecutiveRetries) else {
                if consecutiveRetries == QueueEngineVerifier.maxConsecutiveRetries + 1 {
                    verifierCounts.retriesCapped += 1
                    writeFinding(.verifierRetriesCapped, fields: [], at: now)
                }
                return
            }
            delay = backoff
        }
        let at = generation
        armTimer(.quiet, after: delay) { engine in
            if engine.generation == at { engine.startVerification() }
        }
    }

    /// Ten minutes with no comparison that reached a verdict writes `unverifiedTooLong`, and arms again (D7).
    private func armUnverifiedTimer() {
        guard verifierSetup.triggers == .automatic else { return }
        armTimer(.unverified, after: QueueEngine.unverifiedSeconds) { engine in
            engine.verifierCounts.unverifiedTooLong += 1
            engine.writeFinding(.unverifiedTooLong, fields: [], at: engine.clock.now())
            engine.armUnverifiedTimer()
        }
    }

    private static var unverifiedSeconds: TimeInterval { QueueEngineVerifier.unverifiedTooLongSeconds }

    /// One record into the divergence log, through its cooldown (D8), and into `verifierFindings`. Field NAMES
    /// only, never a show (C7, L222). #4583: it names the output it is about, `judged` for a verification's
    /// verdict and the one on screen otherwise; the log's write stamps the build.
    private func writeFinding(_ kind: CardDivergenceRecord.Kind, fields: [String], at now: Date, judged: Int? = nil,
                              cardsBuilt: Int = 0) {
        findingSequence += 1
        let record = CardDivergenceRecord(session: session, sequence: findingSequence, at: now,
                                          fields: Array(Set(fields)).sorted(), cardsBuilt: cardsBuilt, stage: nil,
                                          kind: kind,
                                          generation: judged ?? output?.generation)
        verifierFindings.append(record)
        if verifierFindings.count > Self.findingsKept { verifierFindings.removeFirst() }
        if let log = verifierSetup.log { CardDivergenceLog.append(record, to: log.url, through: &cooldown) }
    }

    /// Writes every cooldown window that has ended still holding repeats, so a burst followed by quiet keeps its
    /// count (D8's contract: the owner drains). Every turn, which the clock's floor makes at least once a minute.
    private func drainHeldRepeats(at now: Date) {
        guard let log = verifierSetup.log else { return }
        for held in cooldown.drainEnded(at: now) {
            findingSequence += 1
            CardDivergenceLog.appendDrained(held, session: session, sequence: findingSequence, at: now, to: log.url)
        }
    }

    /// One timer per job on the injected clock, replacing the last of its kind (L524).
    private func armTimer(_ slot: QueueEngineTimer, after seconds: TimeInterval,
                          _ fire: @escaping @MainActor (QueueEngine<Value>) -> Void) {
        let clock = self.clock
        observers.replaceTimer(slot, Task { [weak self] in
            do {
                try await clock.sleep(max(0, seconds))
            } catch {
                return
            }
            if let self { fire(self) }
        })
    }

    /// Applies one resolution to every structure registered in `identityKeyedState`.
    private func resolveIdentities(_ resolution: QueueEngineResolution) {
        guard !resolution.isEmpty else { return }
        for entry in Self.identityKeyedState {
            if case .resolved(let apply) = entry.disposition { apply(self, resolution) }
        }
    }

    private static func isContact(_ id: PersistentIdentifier) -> Bool {
        if case .perRowFact(parent: _?, _) = AppSchemaInputClass.byModel[id.entityName] { return true }
        return false
    }

    // MARK: - Reading rows

    /// Reads one show again, re-arms what fired, and stores it. Returns whether the stored value changed. A show
    /// that is gone is resolved away instead.
    private func readShow(_ id: PersistentIdentifier, now: Date, into resolution: inout QueueEngineResolution) -> Bool {
        let held = showMembers[id] ?? (temporaries[id] as? Prospect)
        let show: Prospect
        switch lookUp(id, held: held, table: .shows, now: now) {
        case .live(let model as Prospect): show = model
        case .live, .gone: return remove(id, into: &resolution)
        case .unread: return false
        }
        counters.rowsReread += 1
        guard take(show, id, into: &resolution) else {
            counters.equalValueReads += 1
            return false
        }
        return true
    }

    /// Holds `show` and its contacts as members, armed, and records its value. Returns whether the stored value
    /// changed. The intake's re-read and the launch fill both take a show through here.
    private func take(_ show: Prospect, _ id: PersistentIdentifier, into resolution: inout QueueEngineResolution) -> Bool {
        hold(show, id, in: &showMembers)
        holdIfTemporary(show)
        for contact in show.factContacts {
            let contactID = contact.persistentModelID
            hold(contact, contactID, in: &contactMembers)
            recipientParent[contactID] = id
            holdIfTemporary(contact)
        }
        let oldKey = facts.shows[id]?.naturalKey
        let changed = facts.record(show)
        // #4360: the one place a show's value is recorded, so the one place a patched term learns it changed.
        if changed { patches.noteChanged(id) }
        // A rename under the same identity renames the key everywhere a surface keyed the show by it.
        if let oldKey, let newKey = facts.shows[id]?.naturalKey, newKey != oldKey {
            resolution.rekeyedKeys[oldKey] = newKey
        }
        return changed
    }

    private func take(_ inquiry: Inquiry, _ id: PersistentIdentifier) -> Bool {
        hold(inquiry, id, in: &inquiryMembers)
        holdIfTemporary(inquiry)
        return facts.record(inquiry)
    }

    private func readInquiry(_ id: PersistentIdentifier, now: Date,
                             into resolution: inout QueueEngineResolution) -> Bool {
        let held = inquiryMembers[id] ?? (temporaries[id] as? Inquiry)
        let inquiry: Inquiry
        switch lookUp(id, held: held, table: .inquiries, now: now) {
        case .live(let model as Inquiry): inquiry = model
        case .live, .gone: return remove(id, into: &resolution)
        case .unread: return false
        }
        counters.rowsReread += 1
        guard take(inquiry, id) else {
            counters.equalValueReads += 1
            return false
        }
        return true
    }

    private func readSmallTableRow(_ id: PersistentIdentifier, now: Date,
                                   into resolution: inout QueueEngineResolution) -> Bool {
        guard let table = FactStore.Table.holding(id.entityName) else { return false }
        let model: any PersistentModel
        switch lookUp(id, held: temporaries[id], table: table, now: now) {
        case .live(let found): model = found
        case .gone: return remove(id, into: &resolution)
        case .unread: return false
        }
        counters.rowsReread += 1
        holdIfTemporary(model)
        guard facts.record(model) else {
            counters.equalValueReads += 1
            return false
        }
        return true
    }

    /// A row found gone while being read. Returns whether the store held it.
    private func remove(_ id: PersistentIdentifier, into resolution: inout QueueEngineResolution) -> Bool {
        if let row = facts.shows[id] { resolution.deletedKeys.insert(row.naturalKey) }
        resolution.deletedIDs.insert(id)
        for (contact, show) in recipientParent where show == id { resolution.deletedIDs.insert(contact) }
        return facts.holds(id)
    }

    private func liveContact(_ id: PersistentIdentifier) -> Recipient? {
        if let held = contactMembers[id] ?? (temporaries[id] as? Recipient) {
            return StoreRows.isLive(held) ? held : nil
        }
        let found: Recipient? = context.registeredModel(for: id)
        return found.flatMap { StoreRows.isLive($0) ? $0 : nil }
    }

    /// What a look for one row found.
    private enum Lookup {
        case live(any PersistentModel)
        case gone
        /// The read THREW. Not a deletion (L215): the row's last value stands, and the failure is counted.
        case unread
    }

    /// The live row `id` names: the one held if it is still live, else whatever the store reads.
    private func lookUp(_ id: PersistentIdentifier, held: (any PersistentModel)?, table: FactStore.Table,
                        now: Date) -> Lookup {
        if let held { return StoreRows.isLive(held) ? .live(held) : .gone }
        do {
            return try table.liveRow(id, in: context).map(Lookup.live) ?? .gone
        } catch {
            counters.unreadRows.record(at: now)
            return .unread
        }
    }

    /// Every row in the store read again, on the main context: after a save through another context none of whose
    /// identifiers reached the engine, an unclassified save, and an insert merged into a stored row (the launch
    /// reads off the main thread instead). Returns how many stored values changed; anything held that the read no
    /// longer finds is resolved away.
    @discardableResult
    private func readEverything(into resolution: inout QueueEngineResolution) -> Int {
        counters.fullReads += 1
        let fresh: FactStore
        let shows: [Prospect]
        let inquiries: [Inquiry]
        do {
            shows = try context.fetch(FetchDescriptor<Prospect>())
            inquiries = try context.fetch(FetchDescriptor<Inquiry>())
            fresh = try FactStore(shows: shows, inquiries: inquiries, smallTablesFrom: context)
        } catch {
            // A failed read is not an empty store (L215): everything held stays as it was, and it is counted.
            counters.unreadRows.record(at: clock.now())
            return 0
        }
        let (changed, gone) = facts.differences(to: fresh)
        for id in gone {
            if let row = facts.shows[id] { resolution.deletedKeys.insert(row.naturalKey) }
            resolution.deletedIDs.insert(id)
        }
        for (id, row) in fresh.shows {
            if let old = facts.shows[id], old.naturalKey != row.naturalKey {
                resolution.rekeyedKeys[old.naturalKey] = row.naturalKey
            }
        }
        let contactsBefore = contactMembers
        facts = fresh
        // #4360: replaced whole, so every patched term is built cold at the next pass.
        patches.invalidate()
        var contactsNow: Set<PersistentIdentifier> = []
        for show in shows {
            let id = show.persistentModelID
            hold(show, id, in: &showMembers)
            for contact in show.factContacts {
                let contactID = contact.persistentModelID
                contactsNow.insert(contactID)
                hold(contact, contactID, in: &contactMembers)
                recipientParent[contactID] = id
            }
        }
        for inquiry in inquiries { hold(inquiry, inquiry.persistentModelID, in: &inquiryMembers) }
        // A contact held from before that the read no longer finds is gone with its show, or deleted alone.
        for (id, contact) in contactsBefore where !contactsNow.contains(id) && !StoreRows.isLive(contact) {
            resolution.deletedIDs.insert(id)
        }
        // A main-context read includes rows inserted and not yet saved, whose identifiers are temporary.
        for model in context.insertedModelsArray where facts.holds(model.persistentModelID)
            || contactsNow.contains(model.persistentModelID) {
            holdIfTemporary(model)
        }
        counters.rowsReread += shows.count + inquiries.count
        return changed
    }

    /// Keeps a row that has never been saved, so its first save can re-key it. A temporary identifier carries
    /// no store identifier, and a saved one always does (`EngineTemporaryIdentifierTests`).
    private func holdIfTemporary(_ model: any PersistentModel) {
        let id = model.persistentModelID
        if id.storeIdentifier == nil { temporaries[id] = model }
    }

    /// Keeps `row` as the member for `id` and makes sure a tracker is armed on IT. A read that hands back a
    /// different object for the same identity leaves the old object's tracker watching a row nobody edits, so
    /// the new object is armed afresh.
    private func hold<Row: ScopeObserved>(_ row: Row, _ id: PersistentIdentifier,
                                          in members: inout [PersistentIdentifier: Row]) {
        if let previous = members[id], previous !== row { armed.remove(id) }
        members[id] = row
        arm(row, id)
    }

    /// One tracker on `row`'s own stored properties, through `ScopeField.arm`, unless one is already armed.
    private func arm<Row: ScopeObserved>(_ row: Row, _ id: PersistentIdentifier) {
        guard armed.insert(id).inserted else { return }
        let intake = self.intake
        withObservationTracking {
            for field in Row.scopeFields { field.arm(row) }
        } onChange: {
            intake.trackerFired(id)
        }
    }

    // MARK: - The clock

    /// ONE timer, replacing the last, sleeping on the injected clock until `next` (L524).
    private func armDeadline(_ next: QueueEngineDeadline) {
        deadline = next
        let clock = self.clock
        observers.replaceTimer(.deadline, Task { [weak self] in
            do {
                try await clock.sleep(max(0, next.at.timeIntervalSince(clock.now())))
            } catch {
                return
            }
            self?.deadlineArrived(next)
        })
    }

    private func deadlineArrived(_ arrived: QueueEngineDeadline) {
        guard deadline == arrived else { return }
        clockDue.insert(arrived.kind == .floor ? .clockFloor : .clockTerm)
        scheduleTurn()
    }

    private func clockEvent(_ reason: QueueEnginePassReason) {
        clockDue.insert(reason)
        scheduleTurn()
    }
}

// MARK: - The structures the resolve step applies to

extension QueueEngine {
    /// What the resolve step does to one structure this engine keys by identity or by natural key.
    enum IdentityKeyedDisposition {
        /// Purged and re-keyed by every resolution.
        case resolved(@MainActor (QueueEngine<Value>, QueueEngineResolution) -> Void)
        /// Emptied at the start of every turn, so nothing in it outlives one.
        case drainedAtEveryTurn
        /// Keyed by the NAME of a context input, never by a row, so no deletion or re-key reaches it.
        case namesInputsNotRows
        /// Holds the NAMES of an output's fields (C7), never a row's identity or key, so nothing reaches it.
        case namesFieldsNotRows
    }

    struct IdentityKeyedState {
        /// The stored property's path from the engine, as `EngineIdentityKeyedStateTests` names it by Mirror.
        let path: String
        let disposition: IdentityKeyedDisposition
    }

    /// Every structure this engine keys by `PersistentIdentifier` or by a `String` (a natural key or an input's
    /// name), and what the resolve step does to it. `EngineIdentityKeyedStateTests` walks the stored properties
    /// by Mirror and fails on one not listed here, and on a line here naming nothing (L96).
    static var identityKeyedState: [IdentityKeyedState] {
        [
            IdentityKeyedState(path: "facts.shows", disposition: .resolved { $0.facts.shows.resolve($1) }),
            IdentityKeyedState(path: "facts.inquiries", disposition: .resolved { $0.facts.inquiries.resolve($1) }),
            IdentityKeyedState(path: "facts.orgAnswers", disposition: .resolved { $0.facts.orgAnswers.resolve($1) }),
            IdentityKeyedState(path: "facts.watchedSources",
                               disposition: .resolved { $0.facts.watchedSources.resolve($1) }),
            IdentityKeyedState(path: "facts.refusedAddresses",
                               disposition: .resolved { $0.facts.refusedAddresses.resolve($1) }),
            IdentityKeyedState(path: "facts.promotedProducers",
                               disposition: .resolved { $0.facts.promotedProducers.resolve($1) }),
            IdentityKeyedState(path: "facts.demotedHouses",
                               disposition: .resolved { $0.facts.demotedHouses.resolve($1) }),
            IdentityKeyedState(path: "facts.excludedTowns",
                               disposition: .resolved { $0.facts.excludedTowns.resolve($1) }),
            IdentityKeyedState(path: "facts.allowedSeedTowns",
                               disposition: .resolved { $0.facts.allowedSeedTowns.resolve($1) }),
            // #4360: after `facts.shows` above, so a re-keyed show is read under its new identifier. A deleted or re-keyed
            // show leaves the pending set and is applied to every patched term at once, rather than waiting for a pass.
            // The terms' own indexes (`patches.showLink`, `patches.producerTables`) are keyed by identity too, inside
            // a type this registry's walk does not enter; this entry is what brings them to every resolution.
            IdentityKeyedState(path: "patches.pending", disposition: .resolved { engine, resolution in
                engine.patches.resolve(resolution, shows: engine.facts.shows)
            }),
            IdentityKeyedState(path: "showMembers", disposition: .resolved { $0.showMembers.resolve($1) }),
            IdentityKeyedState(path: "contactMembers", disposition: .resolved { $0.contactMembers.resolve($1) }),
            IdentityKeyedState(path: "inquiryMembers", disposition: .resolved { $0.inquiryMembers.resolve($1) }),
            IdentityKeyedState(path: "recipientParent", disposition: .resolved { engine, resolution in
                var next: [PersistentIdentifier: PersistentIdentifier] = [:]
                for (contact, show) in engine.recipientParent {
                    let newContact = resolution.rekeyedIDs[contact] ?? contact
                    let newShow = resolution.rekeyedIDs[show] ?? show
                    if resolution.deletedIDs.contains(contact) || resolution.deletedIDs.contains(show)
                        || resolution.deletedIDs.contains(newContact) || resolution.deletedIDs.contains(newShow) {
                        continue
                    }
                    next[newContact] = newShow
                }
                engine.recipientParent = next
            }),
            IdentityKeyedState(path: "armed", disposition: .resolved { $0.armed.resolve($1) }),
            // #4369: a deleted row is no longer owed a read, and a re-keyed one is owed it under its new identifier.
            IdentityKeyedState(path: "carried", disposition: .resolved { $0.carried.resolve($1) }),
            // #4358 slice E4d: a deleted row is no longer a read that failed, and a re-keyed one is under its new id.
            IdentityKeyedState(path: "failedReads", disposition: .resolved { $0.failedReads.resolve($1) }),
            // A deleted row is out of step with nothing, and a re-keyed one is faulted under its new identifier.
            IdentityKeyedState(path: "faults.entries", disposition: .resolved { $0.faults.resolve($1) }),
            // Derived from the fault set just above, so it is brought to it after that entry resolves.
            IdentityKeyedState(path: "outOfStepShows", disposition: .resolved { engine, _ in engine.refreshOutOfStep() }),
            // A run in flight compares outputs as they WERE, whole, so nothing in its ring is purged; a deletion
            // stops it instead, because the read it is making may already miss the row (plan v7 Phase 4 step 1).
            IdentityKeyedState(path: "verification", disposition: .resolved { engine, resolution in
                if !resolution.deletedIDs.isEmpty { engine.verification?.cancel() }
            }),
            // A temporary row leaves this the moment its first save re-keys it, or it is gone.
            IdentityKeyedState(path: "temporaries", disposition: .resolved { engine, resolution in
                for id in resolution.deletedIDs { engine.temporaries.removeValue(forKey: id) }
                for temporary in resolution.rekeyedIDs.keys { engine.temporaries.removeValue(forKey: temporary) }
            }),
            IdentityKeyedState(path: "viewInputs.focusedKeys", disposition: .resolved { engine, resolution in
                engine.viewInputs.focusedKeys = engine.viewInputs.focusedKeys?.resolved(keys: resolution)
            }),
            IdentityKeyedState(path: "viewInputs.requestedCardKeys", disposition: .resolved {
                $0.viewInputs.requestedCardKeys.resolve(keys: $1)
            }),
            // The view the output on screen was derived for, resolved as the live view is: a resolution that
            // changes a key also changes a fact, so a pass follows and publishes this again.
            IdentityKeyedState(path: "publishedViewInputs.focusedKeys", disposition: .resolved { engine, resolution in
                let keys = engine.publishedViewInputs?.focusedKeys?.resolved(keys: resolution)
                engine.publishedViewInputs?.focusedKeys = keys
            }),
            IdentityKeyedState(path: "publishedViewInputs.requestedCardKeys", disposition: .resolved {
                $0.publishedViewInputs?.requestedCardKeys.resolve(keys: $1)
            }),
            IdentityKeyedState(path: "outputHealFields", disposition: .namesFieldsNotRows),
            IdentityKeyedState(path: "intake.pending.fired", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.noted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.inserted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.updated", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.deleted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.foreign", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "signals", disposition: .namesInputsNotRows),
            IdentityKeyedState(path: "sourcesFired", disposition: .namesInputsNotRows),
        ]
    }
}

// MARK: - The show resolver (#4358 slice E4b, plan item 11)

// What an action resolves its show THROUGH once the cutover (slice E4d) hands the engine to the surfaces: the rows
// the engine holds, by identifier, never by key, and never through a render pass's captured list (#3690).
//
// THE FILL'S FALLBACK. While the launch fill is still taking shows in, a row it has not reached is not held, yet
// the first output is already on screen and Dan can press it. Such a row is found through the main context by its
// identifier (`FactStore.Table.liveRow`, which fetches rather than trusting `model(for:)`, whose answer for a row
// deleted and saved reads as live, #4106 probe 2) and noted dirty, so the next turn takes it in and arms it.
//
// THE FAULT REFUSAL. A row the verifier or a foreign save faulted is found and then refused (`isOutOfStep`), so an
// action can never save the main context's stale copy over the stored one (D7).
extension QueueEngine: ShowResolver {
    func liveShow(_ id: PersistentIdentifier) -> Prospect? {
        if let held = showMembers[id] ?? (temporaries[id] as? Prospect) {
            // Held now, so whatever an earlier look during the fill found no longer describes it.
            failedReads.remove(id)
            return StoreRows.isLive(held) ? held : nil
        }
        guard isStillFilling else { return nil }
        do {
            guard let show = try launchSetup.pressRead(id, context) else {
                failedReads.remove(id)
                return nil
            }
            failedReads.remove(id)
            noteChanged(show)
            return show
        } catch {
            // A failed read is not a deletion (L215): counted, and remembered so the press is refused as a read that
            // failed (`readFailed`, `ShowIdentity.Refusal.unreadable`) rather than as a show that is gone (L11).
            counters.unreadRows.record(at: clock.now())
            failedReads.insert(id)
            return nil
        }
    }

    /// #4358 slice E4d: whether the last look for this row, during the launch fill, THREW, so a press that found
    /// nothing is said as a read that failed rather than as a show that is gone. Only while the fill runs: once it is
    /// done every row the store holds is held, so a row the engine cannot find has gone, whatever a look during the
    /// fill once said (the lessons review of E4d1, L11).
    func readFailed(_ id: PersistentIdentifier) -> Bool { isStillFilling && failedReads.contains(id) }

    func identities(forKeys keys: Set<String>) -> [String: ShowIdentity] {
        var out: [String: ShowIdentity] = [:]
        // Two rows hold one key only between an insert and the save that refuses it; the lower identifier wins, so
        // the answer does not depend on dictionary order.
        for (id, row) in facts.shows where keys.contains(row.naturalKey) {
            if let held = out[row.naturalKey], held.showID < id { continue }
            out[row.naturalKey] = ShowIdentity(showID: id, naturalKey: row.naturalKey)
        }
        let missing = keys.subtracting(out.keys)
        guard isStillFilling, !missing.isEmpty else { return out }
        do {
            let wanted = Array(missing)
            // In key order where it is read (#4406): two rows holding one key resolve the same way on every read.
            let found = Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>(predicate: #Predicate<Prospect> { wanted.contains($0.naturalKey) })))
            for show in found where out[show.naturalKey] == nil && StoreRows.isLive(show) {
                noteChanged(show)
                out[show.naturalKey] = ShowIdentity(show)
            }
        } catch {
            counters.unreadRows.record(at: clock.now())
        }
        return out
    }

    /// Every held show in key order (L343). While the fill runs, the held shows are not yet every show, so the main
    /// context is read whole instead: this serves only the bulk actions, which already paid a whole read.
    var everyShow: [Prospect] {
        if isStillFilling {
            do {
                return Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>()))
            } catch {
                // Counted, and the shows held so far stand in: a failed read is not an empty store (L215).
                counters.unreadRows.record(at: clock.now())
            }
        }
        return Prospect.inKeyOrder(showMembers.values.filter { StoreRows.isLive($0) })
    }

    /// #4358 slice E4d: every held inquiry, oldest first and then by identifier (L343), for the surfaces that read the
    /// inquiries the engine holds rather than a query of their own (#4370). While the fill runs the inquiries are
    /// not yet held, so the main context is read instead, as `everyShow` does.
    var everyInquiry: [Inquiry] {
        let rows: [Inquiry]
        if isStillFilling {
            do {
                rows = try context.fetch(FetchDescriptor<Inquiry>())
            } catch {
                counters.unreadRows.record(at: clock.now())
                rows = Array(inquiryMembers.values)
            }
        } else {
            rows = Array(inquiryMembers.values)
        }
        return rows.filter { StoreRows.isLive($0) }.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.persistentModelID < $1.persistentModelID
        }
    }

    func isOutOfStep(_ id: PersistentIdentifier) -> Bool { isFaulted(id) }

    /// Whether the launch has not yet taken every show in: the first read has not landed, or the fill is under way
    /// or failed part way.
    private var isStillFilling: Bool {
        if case .done = launch.fill { return false }
        return true
    }
}
