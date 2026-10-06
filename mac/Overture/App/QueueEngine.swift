import Foundation
import Observation
import SwiftData

// #4358 (plan v7 Phase 4, slice E1a): the queue engine's core. It keeps every queue input as a value and takes
// each store change in by identity, reading again only the rows a change names.
//
// WHAT IT REPLACES, once the cutover wires it (#4358, slice E4). Today every store change re-derives the whole
// queue on the main thread from the live models, inside the view's body, and nothing can tell a change that
// mattered from one that did not. This keeps a value per stored row (`FactStore`), reads a row again only when
// something says it changed, and drops a re-read that changed nothing (the equality gate).
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
// is listed in `identityKeyedState`, and the step applies one `QueueEngineResolution` to each entry: deleted
// rows purged, a temporary identifier a first save replaced re-keyed. The list is checked rather than trusted:
// `EngineIdentityKeyedStateTests` walks this class's stored properties by Mirror and fails on any
// identity-keyed structure the list does not name (L96).
//
// ONE FLAG, so every change made in one main actor turn is taken in by one turn of the engine.
//
// WHAT IS NOT HERE YET. The value pass, the generation gate, the clock and the change-kind matrix are the
// slice after this one (#4358 E1b): the pass needs `QueueRenderPass.make` over these facts, which needs every
// term generic over the facts protocols and a RenderData that holds no model (#4357). The verifier and
// recovery (D7) and the launch fill (D6) follow.
//
// NOTHING IN THE APP STARTS THIS YET. The cutover (#4358, slice E4) does.

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

/// The save observer the engine registered, removed when it goes.
private final class QueueEngineObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func add(_ token: NSObjectProtocol, on center: NotificationCenter) {
        lock.withLock { tokens.append((center, token)) }
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
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
final class QueueEngine {

    // MARK: - What it is built from

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let saves: StoreSaveCount
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let saveCenter: NotificationCenter
    @ObservationIgnored private let schedule: QueueEngineSchedule
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
    @ObservationIgnored private var temporaries: [PersistentIdentifier: any PersistentModel] = [:]
    /// Each temporary identifier a save replaced, to its permanent one, because a tracker armed before the
    /// save still reports the temporary one when it fires.
    @ObservationIgnored private var rekeyedTemporaries: [PersistentIdentifier: PersistentIdentifier] = [:]

    // MARK: - The turn

    @ObservationIgnored private var started = false
    @ObservationIgnored private var turnScheduled = false
    @ObservationIgnored private var observedForeignSaves = 0
    @ObservationIgnored private(set) var counters = QueueEngineCounters()

    init(context: ModelContext,
         saves: StoreSaveCount = .shared,
         now: @escaping @MainActor () -> Date = Date.init,
         saveCenter: NotificationCenter = .default,
         schedule: @escaping QueueEngineSchedule = QueueEngineTurns.nextTurn) {
        self.context = context
        container = context.container
        self.saves = saves
        self.now = now
        self.saveCenter = saveCenter
        self.schedule = schedule
        let engine = QueueEngineReference(self)
        intake.setWake {
            QueueEngineTurns.onMain { engine.target?.scheduleTurn() }
        }
    }

    /// Starts watching the store and reads every row. Saves are watched BEFORE the read, so no save can land
    /// between the two unseen. Once: a second call would register a second observer and double every intake.
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
        observedForeignSaves = saves.foreignSaveCount(for: container)
        var resolution = QueueEngineResolution()
        readEverything(into: &resolution)
        resolveIdentities(resolution)
    }

    /// A change the store has not been told about, from a caller that holds the model: the show resolver
    /// (#4357, slice I2) marks every row an action touches, so an unsaved edit on a row with no tracker yet
    /// still reaches the next turn. Values are read in the turn, like every other change.
    func noteChanged(_ model: any PersistentModel) {
        holdIfTemporary(model)
        intake.noted(model.persistentModelID)
    }

    // MARK: - The turn

    private func scheduleTurn() {
        guard !turnScheduled else { return }
        turnScheduled = true
        schedule { [weak self] in self?.runTurn() }
    }

    private func runTurn() {
        turnScheduled = false
        counters.turns += 1
        counters.rowsChanged += intakeTurn(now: now())
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
        // A contact deleted on its own changes the show it sat under.
        for id in resolution.deletedIDs where Self.isContact(id) {
            if let show = recipientParent[id], !resolution.deletedIDs.contains(show) { shows.insert(show) }
        }
        var changed = resolution.deletedIDs.filter(facts.holds).count
        // Only a row with a tracker armed under its temporary identifier can still report that identifier, so
        // only its re-key is remembered; a small table row, which no tracker watches, needs no entry.
        let reportable = resolution.rekeyedIDs.filter { armed.contains($0.key) }
        resolveIdentities(resolution)
        rekeyedTemporaries.merge(reportable) { _, new in new }

        let fired = Set(pending.fired.map(current))
        armed.subtract(fired)
        let touched = fired.union(pending.noted.map(current)).union(pending.inserted.map(current))
            .union(pending.updated.map(current)).union(resolution.rekeyedIDs.values)
        // A tracker fires once, so a temporary identifier one just reported will never be reported again: the
        // row is re-armed under its permanent identifier below, and the entry has done its only job.
        for id in pending.fired { rekeyedTemporaries.removeValue(forKey: id) }
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
        let inserted = Set(pending.inserted.map(current)).subtracting(resolution.deletedIDs)
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

    /// The identifier a row carries now, for one a tracker armed before its first save still reports.
    private func current(_ id: PersistentIdentifier) -> PersistentIdentifier {
        rekeyedTemporaries[id] ?? id
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
        guard facts.record(show) else {
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
            counters.unreadRows.record(at: now())
            return 0
        }
        let (changed, gone) = facts.differences(to: fresh)
        resolution.deletedIDs.formUnion(gone)
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
}

// MARK: - The structures the resolve step applies to

extension QueueEngine {
    /// What the resolve step does to one structure this engine keys by identity.
    enum IdentityKeyedDisposition {
        /// Purged and re-keyed by every resolution.
        case resolved(@MainActor (QueueEngine, QueueEngineResolution) -> Void)
        /// Emptied at the start of every turn, so nothing in it outlives one.
        case drainedAtEveryTurn
    }

    struct IdentityKeyedState {
        /// The stored property's path from the engine, as `EngineIdentityKeyedStateTests` names it by Mirror.
        let path: String
        let disposition: IdentityKeyedDisposition
    }

    /// Every structure this engine keys by `PersistentIdentifier` or by a `String`, and what the resolve step
    /// does to it. `EngineIdentityKeyedStateTests` walks the stored properties by Mirror and fails on one not
    /// listed here, and on a line here naming nothing (L96).
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
            // Entries are ADDED by the intake turn, for re-keyed rows a tracker still watches; this only purges.
            IdentityKeyedState(path: "rekeyedTemporaries", disposition: .resolved { engine, resolution in
                engine.rekeyedTemporaries = engine.rekeyedTemporaries.filter { temporary, permanent in
                    !resolution.deletedIDs.contains(permanent) && !resolution.deletedIDs.contains(temporary)
                }
            }),
            IdentityKeyedState(path: "intake.pending.fired", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.noted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.inserted", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.updated", disposition: .drainedAtEveryTurn),
            IdentityKeyedState(path: "intake.pending.deleted", disposition: .drainedAtEveryTurn),
        ]
    }
}
