import Testing

// #1006: main crashed (not an assertion failure) with a SwiftData "PersistentIdentifier ... was
// remapped to a temporary identifier during save: This is a fatal logic error in DefaultStore"
// signature, always right after a real, disk-backed ModelContainer save. Swift Testing runs
// suites concurrently by default, and that crash shape is CoreData's own store-coordinator
// bookkeeping racing across containers, not a specific test's assertion being wrong. A `.serialized`
// suite trait only orders tests WITHIN one suite; the race here is ACROSS suites, so every real-store
// test must instead funnel through one shared, process-wide FIFO lock. These tests prove the lock
// itself actually serializes, before it's wired into any real test.
@Suite("Real-store test lock (#1006)")
struct RealStoreTestLockTests {
    @Test func serializesConcurrentCriticalSections() async throws {
        actor Recorder {
            private(set) var concurrent = 0
            private(set) var maxConcurrent = 0
            func enter() { concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent) }
            func exit() { concurrent -= 1 }
        }
        let recorder = Recorder()
        let lock = RealStoreTestLock()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await lock.acquire()
                    await recorder.enter()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    await recorder.exit()
                    await lock.release()
                }
            }
        }

        #expect(await recorder.maxConcurrent == 1)
    }

    @Test func releaseWakesTheNextWaiterSoNothingHangsForever() async throws {
        let lock = RealStoreTestLock()

        await lock.acquire()
        let secondAcquired = Task { () -> Bool in
            await lock.acquire()
            return true
        }
        // Give the second acquire a moment to actually start waiting, then release the first.
        try await Task.sleep(nanoseconds: 5_000_000)
        await lock.release()

        let acquired = await secondAcquired.value
        #expect(acquired)
        await lock.release()
    }
}
