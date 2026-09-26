import Foundation
import SwiftData

// #4106: how many times ANY `ModelContext` in this process has saved.
//
// WHY A MEMO NEEDS IT. `ScopeMemo` notices an edit in place through observation tracking, and that only
// sees a write made to the very model objects the derivation read. A write saved through a DIFFERENT
// context (in this app only ever a test's own; see below) reaches the main context as a merge and
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
// #4252: AND WHETHER ANY SAVE CAME THROUGH ANOTHER CONTEXT. A memo may now serve an answer when observation
// says stale and no save has happened since its build, because that is SwiftData's refetch re-announcing
// rows that did not change. One write breaks that reasoning: one saved through ANOTHER context before the
// build, whose merge reaches the main context after it, changing rows with no save since the build. So a
// store that has ever taken a save through a context other than its main one never has a refetch served
// (`hasForeignSaves`), and its memos rebuild on every observed change, as they all did before.
//
// A SECOND CONTEXT MAY ONLY READ. Measured by #4102's agent on 2026-09-25: a second context that fetched a
// row and saved an edit to one field, after the main context had saved another field on the same row,
// wrote the whole object back and reverted the main context's field. So in the running app every save is
// the main context's and this never trips; `OnlyTheMainContextWritesGuardTests` keeps it that way
// (`StoreRows.readInBackground` reads through one and never saves). Tests that write through a second
// context are what trip it.
//
// WHY NOT COMPARE THE WRITTEN VALUES INSTEAD, which was built (Dan's call, 2026-09-25 in chat: compare
// values). Reading another context's rows inside its own save notification tripped an assertion inside
// SwiftData's `getValue` and killed the test host in the full suite, and in the app it would only ever
// guard a path the guard above forbids. A fact that needs no read cannot fail that way.
final class StoreSaveCount: @unchecked Sendable {
    static let shared = StoreSaveCount()

    private let lock = NSLock()
    private var counts: [ObjectIdentifier: Int] = [:]
    private var foreign: Set<ObjectIdentifier> = []
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
            self?.record(saved)
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    private func record(_ saved: ModelContext) {
        let store = ObjectIdentifier(saved.container)
        // A store's main context only ever saves on the main thread, and only there may it be asked for, so
        // a save anywhere else is foreign by construction.
        let savedID = ObjectIdentifier(saved)
        let container = saved.container
        let isMain = Thread.isMainThread
            && MainActor.assumeIsolated { ObjectIdentifier(container.mainContext) == savedID }
        lock.lock(); defer { lock.unlock() }
        counts[store, default: 0] += 1
        if !isMain { foreign.insert(store) }
    }

    /// Whether `store` has ever taken a save through a context other than its main one.
    func hasForeignSaves(in store: ModelContainer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return foreign.contains(ObjectIdentifier(store))
    }

    /// Saves into `store`, through any of its contexts, since this counter was made. Only ever compared
    /// with an earlier reading of itself.
    func value(for store: ModelContainer) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[ObjectIdentifier(store)] ?? 0
    }
}
