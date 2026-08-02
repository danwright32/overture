import Foundation
import Observation

// #1964: the ONE held answer to "which rooms has Dan shot before".
//
// `VenueShootHistory.current(today:)` opens and decodes two files, the shoot-history import and the
// Downbeat export. It was being called inside `QueueModel.items`, which runs on every render pass, so a
// dismiss, a keystroke, or any re-render read and parsed both files again on the main thread. Measured
// with `sample` against the live Release build on 2026-08-01: about 430 samples, and a sample count
// understates blocking I/O. Its own doc comment says callers build it once per PASS and never per row;
// the queue honoured that literally while a pass was happening constantly.
//
// The same shape as #1770's Gmail answer, for the same reason: it is one fact about the app, identical
// for every card, and it changes only at moments the app already knows about. @Observable, so a surface
// reading it re-renders when the history actually changes rather than because it happened to be rebuilt.
//
// Refreshed from `ReconcileScheduler.runSafeReconcilesOnce`, which is launch, the periodic tick, and the
// Downbeat export watcher firing, the same free tick the cached Gmail signature rides (#1158). The
// shoot-history half is written by a manual import (`scripts/import-shoot-history.ts`) that the app never
// runs itself, so that tick is also what picks up an import Dan runs while the app is open.
//
// Two failures this design could introduce, and what stops each:
//
// - Serving yesterday's answer across midnight. The history counts only shoots strictly BEFORE today, so
//   a stale `today` would count tonight's show as one already shot. The held value knows which day it was
//   built for and rebuilds itself when asked for a different one, which is a string comparison and no I/O.
// - Invalidating the queue on every tick. The assignment only happens on a real change, so a refresh that
//   finds the same history notifies nobody. #1930's whole complaint is an idle app paying for work, and a
//   cache that announced itself every thirty minutes would be a new instance of it.
@MainActor
@Observable
final class VenueShootHistoryCache {
    static let shared = VenueShootHistoryCache()

    private let load: @MainActor (String) -> VenueShootHistory

    private(set) var current: VenueShootHistory
    // The Eastern date `current` was built for, never the wall clock at read time.
    private(set) var builtFor: String

    init(today: String = EasternDate.today(),
         load: @escaping @MainActor (String) -> VenueShootHistory = { VenueShootHistory.current(today: $0) }) {
        self.load = load
        self.builtFor = today
        self.current = load(today)
    }

    // Go back to the files. Callers are the state transitions above, never a render path: the whole point
    // of this type is that drawing a card asks the filesystem nothing.
    func refresh(today: String = EasternDate.today()) {
        let fresh = load(today)
        builtFor = today
        // Only on a real change (#1930). @Observable's generated setter notifies on every assignment
        // rather than on every change, and one of the surfaces reading this is the queue, whose body
        // derives every prospect on its first line.
        if fresh != current { current = fresh }
    }

    // What a render reads. Free, except on the first read of a new day.
    func history(today: String = EasternDate.today()) -> VenueShootHistory {
        if today != builtFor { refresh(today: today) }
        return current
    }
}
