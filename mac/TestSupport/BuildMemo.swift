import Foundation

// One value, built at most once per process, for the expensive whole-tree scans the test suite makes
// over and over (#3235).
//
// Two things about it are the whole safety of the idea, and both are the caller's to supply.
//
// `keepIf` decides what is worth remembering, and every caller passes the same shape of question: did
// this scan actually see anything. A scan that read no files is the one result that must never be
// kept, because downstream it is indistinguishable from a clean tree, so remembering it would turn a
// single broken path into every guard in the suite passing over nothing at once (L286, L98). A result
// it refuses is returned to the caller unchanged and simply not stored, so the next call re-scans and
// the guards that judge a scan's size go on seeing a real one.
//
// `buildsPerformed` exists so the memo can be PROVED rather than assumed. A memo that silently stopped
// working is invisible from the outside: the fallback is correct and merely slower, so every test stays
// green while the saving quietly stops happening (L289).
//
// A class behind a lock rather than a `static var`, so this stays correct when the suite runs its tests
// in parallel. The build itself is deliberately NOT held under the lock: it can take seconds and can
// throw, and holding a lock across it would serialise every caller behind the first one and leave the
// lock held if it threw. The cost of that choice is that two callers racing on a cold memo can both
// build; they agree on the answer, and one of the two results is discarded.
final class BuildMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var builds = 0

    var buildsPerformed: Int {
        lock.lock(); defer { lock.unlock() }
        return builds
    }

    func value(keepIf shouldKeep: (Value) -> Bool, build: () throws -> Value) rethrows -> Value {
        lock.lock()
        if let hit = stored { lock.unlock(); return hit }
        builds += 1
        lock.unlock()

        let built = try build()
        guard shouldKeep(built) else { return built }

        lock.lock(); stored = built; lock.unlock()
        return built
    }
}
