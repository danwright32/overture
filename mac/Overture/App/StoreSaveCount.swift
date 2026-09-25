import Foundation
import SwiftData

// #4106: how many times ANY `ModelContext` in this process has saved.
//
// WHY A MEMO NEEDS IT. `ScopeMemo` notices an edit in place through observation tracking, and that only
// sees a write made to the very model objects the derivation read. A write saved through a DIFFERENT
// context (a background run, a reconcile, a test's own context) reaches the main context as a merge and
// a refetch, which can leave every object the queue read untouched and every identity where it was. So
// the fingerprint matched, no observed field fired, and the memo served the answer from before the
// save: measured, `FeltWaitCostTests` wrote through a second context and the queue never rebuilt at all
// (L40: stale rows are worse than a slow screen).
//
// A count of saves is the cheapest thing that moves on every one of those, and it is what a memo keys on
// to be told "the store changed, whatever you observed". It over-reports rather than under-reports: a
// save that touched nothing a surface reads still counts, which costs that surface one derivation, never
// a stale answer.
//
// PER CONTAINER, because the process holds more than one store (every test builds its own in-memory
// container, and the suite runs them concurrently), and a count shared across them would make one store's
// save a change to every other store's memos: correct but noisy in the app, and a race in the suite.
//
// Posted on whatever thread saved, so the counts are behind a lock.
//
// #4252: AND WHAT A SAVE THROUGH ANOTHER CONTEXT WROTE. A memo may now serve an answer when observation
// says stale and no save has happened since its build, because that is SwiftData's refetch re-announcing
// rows that did not change. One write breaks that reasoning: one saved through ANOTHER context before the
// build, whose merge reaches the main context after it. The main context's rows then change with no save
// since the build. So for every save that did not come through a store's main context, the values of every
// row it inserted or updated are read HERE, on the saving thread, from the saving context, and kept, and a
// memo compares the main context's copy of each row with them (Dan's call, 2026-09-25 in chat: compare
// values, with supported API only). In the running app every save is the main context's, so this records
// nothing there today; it is the net under a background context (#4250), and under every test that writes
// through a second one.
final class StoreSaveCount: @unchecked Sendable {
    static let shared = StoreSaveCount()

    /// One save through a context other than its store's main one: the rows it wrote, as that context
    /// read them straight after writing.
    struct ForeignWrite {
        /// The store's save count straight after this save, so a memo can tell whether it built before or
        /// after it.
        let index: Int
        let rows: [ForeignRow]
    }

    struct ForeignRow {
        let id: PersistentIdentifier
        let type: any ScopeCompared.Type
        let values: [Any]
    }

    /// How many foreign writes are kept per store. A memo that has fallen further behind than this cannot
    /// know what it missed, and `foreignWrites(after:in:)` says so rather than answering with a partial list.
    static let foreignWritesKept = 256

    private let lock = NSLock()
    private var counts: [ObjectIdentifier: Int] = [:]
    private var foreign: [ObjectIdentifier: [ForeignWrite]] = [:]
    // The index of the newest foreign write dropped from `foreign`, per store.
    private var droppedThrough: [ObjectIdentifier: Int] = [:]
    private var token: NSObjectProtocol?
    private let center: NotificationCenter

    /// `center` is injected so a test can post its own notification without touching the default center
    /// the running app shares.
    init(center: NotificationCenter = .default) {
        self.center = center
        token = center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] note in
            // A save notification with no context behind it cannot be attributed to a store, so it is
            // counted against nothing rather than guessed at.
            guard let saved = note.object as? ModelContext else { return }
            self?.record(saved, userInfo: note.userInfo)
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    // On the saving context's own thread, which is the only place its rows may be read.
    private func record(_ saved: ModelContext, userInfo: [AnyHashable: Any]?) {
        let store = ObjectIdentifier(saved.container)
        // A store's main context only ever saves on the main thread, and only there may it be asked for, so
        // a save anywhere else is foreign by construction.
        let savedID = ObjectIdentifier(saved)
        let container = saved.container
        let isMain = Thread.isMainThread
            && MainActor.assumeIsolated { ObjectIdentifier(container.mainContext) == savedID }
        // Read OUTSIDE the lock: reading rows takes as long as the save wrote rows, and nothing else needs
        // to wait for it.
        let rows = isMain ? [] : Self.rowsUpdated(by: saved, userInfo: userInfo)
        lock.lock(); defer { lock.unlock() }
        counts[store, default: 0] += 1
        guard !isMain else { return }
        var writes = foreign[store] ?? []
        writes.append(ForeignWrite(index: counts[store] ?? 0, rows: rows))
        if writes.count > Self.foreignWritesKept {
            let dropped = writes.prefix(writes.count - Self.foreignWritesKept)
            droppedThrough[store] = dropped.last?.index
            writes.removeFirst(dropped.count)
        }
        foreign[store] = writes
    }

    // UPDATED rows only. An inserted or deleted row reaches a memo as an identity its query results gain or
    // lose, which the fingerprint already sees whenever the merge lands; only a row that stays and changes
    // can leave every identity where it was.
    private static func rowsUpdated(by saved: ModelContext, userInfo: [AnyHashable: Any]?) -> [ForeignRow] {
        let ids = userInfo?[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
        return ids.compactMap { id in
            guard let row = saved.model(for: id) as? any ScopeCompared else { return nil }
            return ForeignRow(id: id, type: type(of: row), values: row.scopeValues)
        }
    }

    /// Every foreign write into `store` with an index above `index`, oldest first. `nil` when some of them
    /// have already been dropped, which a caller must treat as "something was written that cannot be
    /// checked", never as "nothing was written" (L98).
    func foreignWrites(after index: Int, in store: ModelContainer) -> [ForeignWrite]? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(store)
        if let dropped = droppedThrough[key], dropped > index { return nil }
        return (foreign[key] ?? []).filter { $0.index > index }
    }

    /// Saves into `store`, through any of its contexts, since this counter was made. Only ever compared
    /// with an earlier reading of itself.
    func value(for store: ModelContainer) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[ObjectIdentifier(store)] ?? 0
    }
}
