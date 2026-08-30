import Testing
import Foundation

// #3234: the lock that lets suites sharing one piece of process-global state run beside a parallel
// suite without overwriting each other. It is applied as a trait, so nothing about the suites that use
// it proves the lock itself works: they would pass just as well against a lock that let everybody in.
@Suite("A named lock keeps one family of shared state to one holder (#3234)")
struct SharedStateTestLockTests {

    // Counts how many holders are inside at once, and remembers the worst it ever saw. An actor, so the
    // counting itself cannot be the race being measured.
    private actor Occupancy {
        private(set) var current = 0
        private(set) var most = 0
        func enter() { current += 1; most = max(most, current) }
        func leave() { current -= 1 }
    }

    @Test func onlyOneHolderIsEverInsideAtOnce() async {
        let lock = await SharedStateTestLock.named("test-mutual-exclusion")
        let occupancy = Occupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await lock.acquire()
                    await occupancy.enter()
                    // Yields rather than sleeps: a sleep would make this a test about the machine's
                    // speed, and a yield hands the scheduler every chance to let a second holder in if
                    // the lock is not holding them out (L290).
                    for _ in 0..<8 { await Task.yield() }
                    await occupancy.leave()
                    await lock.release()
                }
            }
        }

        #expect(await occupancy.most == 1, "two holders were inside the same named lock at once")
        #expect(await occupancy.current == 0, "every holder released")
    }

    // The control for the line above. Without it, "never more than one at a time" is satisfied just as
    // well by a harness where the twelve tasks never actually overlapped, and the case would pass while
    // measuring nothing (L159).
    @Test func theHarnessReallyDoesRunItsTasksAtTheSameTime() async {
        let occupancy = Occupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await occupancy.enter()
                    for _ in 0..<8 { await Task.yield() }
                    await occupancy.leave()
                }
            }
        }

        #expect(await occupancy.most > 1,
                "with no lock these tasks must overlap, or the case above proves nothing about locking")
    }

    // Two different families of shared state have nothing to do with each other, and must not queue
    // behind one another: that would serialise the whole suite one careless name at a time.
    @Test func adifferentNameIsADifferentLock() async {
        let held = await SharedStateTestLock.named("test-family-one")
        let other = await SharedStateTestLock.named("test-family-two")

        await held.acquire()
        // Waited ON rather than waited OUT: this completes immediately if the names are separate, and
        // hangs rather than failing if they are not, which the test framework's own timeout reports.
        await other.acquire()
        await other.release()
        await held.release()

        #expect(Bool(true), "reaching here at all is the assertion: the second name did not queue")
    }

    @Test func thesameNameHandsBackTheSameLock() async {
        let first = await SharedStateTestLock.named("test-identity")
        let second = await SharedStateTestLock.named("test-identity")
        #expect(first === second, "a name must resolve to one lock, or holders of it never exclude")
    }

    // THE case, and the one the tests above do not reach: they drive the LOCK, and what the suites
    // actually use is the TRAIT. Removing the acquire from the trait left every test above green
    // (measured with scripts/mutate.sh, 2026-08-30), which is a guard proving the wrong thing.
    @Test func thetraitItselfKeepsTwoBodiesFromOverlapping() async {
        let trait = SharesGlobalState(name: "test-trait-exclusion")
        let occupancy = Occupancy()
        let test = Test.current!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await trait.provideScope(for: test, testCase: nil) {
                        await occupancy.enter()
                        for _ in 0..<8 { await Task.yield() }
                        await occupancy.leave()
                    }
                }
            }
        }

        #expect(await occupancy.most == 1, "the trait let two bodies run inside the same name at once")
        #expect(await occupancy.current == 0)
    }

    // The trait releases on the way out of a THROWING body too. A lock left held by a failing test turns
    // one failure into a run that never finishes.
    @Test func alockIsReleasedWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let trait = SharesGlobalState(name: "test-throwing-body")

        await #expect(throws: Boom.self) {
            try await trait.provideScope(for: Test.current!, testCase: nil) { throw Boom() }
        }

        // If the release had been skipped, this acquire would never return.
        let lock = await SharedStateTestLock.named("test-throwing-body")
        await lock.acquire()
        await lock.release()
        #expect(Bool(true), "the lock was free again after a body that threw")
    }
}
