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
// The verifier and recovery (D7, slice E2) and the launch fill (D6, slice E3) follow.
//
// NOTHING IN THE APP STARTS THIS YET. The cutover (#4358, slice E4) does.

/// What one pass derives from the facts, and the three things the engine needs to know about its answer.
struct QueueEngineDerivation<Value> {
    /// The value pass. Runs on the main actor from a scheduled turn, never from a view body (L471).
    let derive: @MainActor (QueueEnginePassInput) -> Value
    /// The members of two answers that differ, by name only (C7, L222), for the floor's record.
    let differingFields: (Value, Value) -> [String]
    /// The earliest instant at which a rule in the answer comes due, or nil when none is in play.
    let nextChange: (Value) -> Date?
    /// The cards the answer built, so a frame asking only for those is no reason to derive again.
    let builtCardKeys: (Value) -> Set<String>
}

/// One published pass, and which store state and which pass it describes.
struct QueueEngineOutput<Value> {
    let value: Value
    let saveCount: Int
    let generation: Int
    let now: Date
    let reasons: Set<QueueEnginePassReason>
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

        var isEmpty: Bool {
            fired.isEmpty && noted.isEmpty && inserted.isEmpty && updated.isEmpty && deleted.isEmpty
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

    /// A save's identifiers, copied as handed over. Reads no row.
    func saved(_ info: [AnyHashable: Any]?) {
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

/// What the engine registered with notification centres and the deadline's timer, released when it goes.
private final class QueueEngineObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Task<Void, Never>?

    func add(_ token: NSObjectProtocol, on center: NotificationCenter) {
        lock.withLock { tokens.append((center, token)) }
    }

    func replaceTimer(_ task: Task<Void, Never>?) {
        let old: Task<Void, Never>? = lock.withLock {
            defer { timer = task }
            return timer
        }
        old?.cancel()
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
        timer?.cancel()
    }
}

/// A reference to the engine that does not keep it alive, handed to the closures that fire on other threads.
private final class QueueEngineReference<Target: AnyObject>: @unchecked Sendable {
    weak var target: Target?

    init(_ target: Target) {
        self.target = target
    }
}

@MainActor
@Observable
final class QueueEngine<Value> {

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

    // MARK: - What it keeps, keyed by identity (every one is in `identityKeyedState`)

    /// Every queue input as a value.
    @ObservationIgnored private(set) var facts = FactStore()
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

    // MARK: - The turn and the gate

    @ObservationIgnored private var started = false
    @ObservationIgnored private var turnScheduled = false
    @ObservationIgnored private var observedForeignSaves = 0
    @ObservationIgnored private var clockDue: Set<QueueEnginePassReason> = []
    @ObservationIgnored private var viewInputsMoved = false
    @ObservationIgnored private(set) var deadline: QueueEngineDeadline?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var counters = QueueEngineCounters()

    // MARK: - What it publishes

    /// The latest pass. The one property a surface observes.
    private(set) var output: QueueEngineOutput<Value>?
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
         refused: @escaping @MainActor (Int, Int) -> Void = QueueEngineTurns.refuse) {
        self.context = context
        container = context.container
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

    /// Starts watching the store and the clock, reads every row, and asks for the first pass. Saves are watched
    /// BEFORE the read, so no save can land between the two unseen. Once: a second call would register a
    /// second observer and double every intake.
    func start() {
        guard !started else { return }
        started = true
        let intake = self.intake
        let store = ObjectIdentifier(container)
        observers.add(saveCenter.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            // A save into another store is not a change to this one (`StoreSaveCount` keeps them apart too).
            guard let saved = note.object as? ModelContext, ObjectIdentifier(saved.container) == store else { return }
            intake.saved(note.userInfo)
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
        var resolution = QueueEngineResolution()
        readEverything(into: &resolution)
        resolveIdentities(resolution)
        scheduleTurn()
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

    /// The surface's view. Handing in the same view, or asking only for cards the last pass built, is no
    /// reason for a pass (plan v2 Phase 4 step 2).
    func setViewInputs(_ inputs: QueueEngineViewInputs) {
        let built = output.map { derivation.builtCardKeys($0.value) } ?? []
        let moved = inputs.focusedStage != viewInputs.focusedStage || inputs.focusedKeys != viewInputs.focusedKeys
            || !inputs.requestedCardKeys.isSubset(of: built)
        viewInputs = inputs
        guard moved else { return }
        viewInputsMoved = true
        scheduleTurn()
    }

    /// Publishes `incoming` if it is newer than what is on screen, and arms the clock from it; otherwise refuses
    /// it (plan v2 Phase 4 step 3) and changes nothing. Every pass publishes through here, and so will the launch
    /// fill and the verifier's recovery. Returns whether it was applied, because only an applied output is a pass
    /// (L78).
    @discardableResult
    func publish(_ incoming: QueueEngineOutput<Value>) -> Bool {
        switch QueueEngineGenerations.verdict(published: output?.generation, incoming: incoming.generation) {
        case .apply:
            output = incoming
            armDeadline(QueueEngineDeadline.next(now: incoming.now,
                                                 termNextChange: derivation.nextChange(incoming.value)))
            return true
        case .refuse(let published, let incoming):
            refused(published, incoming)
            return false
        }
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
        counters.turns += 1
        let now = clock.now()
        let saveCount = saves.value(for: container)
        let changed = intakeTurn(now: now)
        counters.rowsChanged += changed
        var reasons = clockDue
        clockDue = []
        if changed > 0 { reasons.insert(.factsChanged) }
        if !sourcesFired.isEmpty { reasons.insert(.sourceFired) }
        sourcesFired = []
        if viewInputsMoved { reasons.insert(.viewInputs) }
        viewInputsMoved = false
        if output == nil { reasons.insert(.first) }
        guard !reasons.isEmpty else { return }
        let value = derivation.derive(QueueEnginePassInput(facts: facts, viewInputs: viewInputs, now: now))
        generation += 1
        let previous = output
        guard publish(QueueEngineOutput(value: value, saveCount: saveCount, generation: generation, now: now,
                                        reasons: reasons)) else {
            // Refused: another caller put a newer output on screen first, so nothing on screen changed and this
            // is no pass and no floor change (L78). The clock runs on from the output that IS on screen, so the
            // floor is never left without a timer (L51).
            if let onScreen = output {
                armDeadline(QueueEngineDeadline.next(now: now, termNextChange: derivation.nextChange(onScreen.value)))
            }
            return
        }
        counters.passes += 1
        if reasons == [.clockFloor], let previous {
            let fields = derivation.differingFields(previous.value, value)
            if !fields.isEmpty {
                floorChanges.append(QueueEngineFloorChange(fields: fields, at: now, generation: generation))
                if floorChanges.count > Self.floorChangesKept { floorChanges.removeFirst() }
            }
        }
    }

    // MARK: - Intake and the resolve step

    /// Takes in what the intake holds, resolves identities, and reads again every row it names. Returns how
    /// many stored values changed.
    private func intakeTurn(now: Date) -> Int {
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
        let foreign = saves.foreignSaveCount(for: container)
        if foreign != observedForeignSaves {
            observedForeignSaves = foreign
            counters.foreignSaves.record(at: now)
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#4358)
            AgentLog.note("Queue engine read every row again after a save through another context "
                          + "(\(counters.foreignSaves.times) this session).")
            // copy-inventory:ignore-end
            everything = true
        }

        var second = QueueEngineResolution()
        if !everything {
            for id in shows where readShow(id, now: now, into: &second) { changed += 1 }
            for id in inquiries where readInquiry(id, now: now, into: &second) { changed += 1 }
            for id in small where readSmallTableRow(id, now: now, into: &second) { changed += 1 }
        }
        if everything { changed += readEverything(into: &second) }
        resolveIdentities(second)
        return changed
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
        // A rename under the same identity renames the key everywhere a surface keyed the show by it.
        if let oldKey, let newKey = facts.shows[id]?.naturalKey, newKey != oldKey {
            resolution.rekeyedKeys[oldKey] = newKey
        }
        guard changed else {
            counters.equalValueReads += 1
            return false
        }
        return true
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
        hold(inquiry, id, in: &inquiryMembers)
        holdIfTemporary(inquiry)
        guard facts.record(inquiry) else {
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

    /// Every row in the store read again: at the start, after a save through another context, and after an
    /// insert merged into a stored row. Returns how many stored values changed; anything held that the read no
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
        observers.replaceTimer(Task { [weak self] in
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
            IdentityKeyedState(path: "intake.pending.fired", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.noted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.inserted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.updated", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.deleted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "signals", disposition: .namesInputsNotRows),
            IdentityKeyedState(path: "sourcesFired", disposition: .namesInputsNotRows),
        ]
    }
}
