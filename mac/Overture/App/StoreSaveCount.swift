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
final class StoreSaveCount: @unchecked Sendable {
    static let shared = StoreSaveCount()

    private let lock = NSLock()
    private var counts: [ObjectIdentifier: Int] = [:]
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
            self?.bump(ObjectIdentifier(saved.container))
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    private func bump(_ store: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        counts[store, default: 0] += 1
    }

    /// Saves into `store`, through any of its contexts, since this counter was made. Only ever compared
    /// with an earlier reading of itself.
    func value(for store: ModelContainer) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[ObjectIdentifier(store)] ?? 0
    }
}
