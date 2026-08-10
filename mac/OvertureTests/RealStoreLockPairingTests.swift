import Testing
import Foundation

// #2198: twenty test files take `RealStoreTestLock` by hand, and each hand-pairs the acquire with a
// release on every exit path. That pairing is load-bearing: #1006 exists because two disk-backed
// SwiftData containers built at the same moment crash the whole test process, not one assertion.
//
// The mistake it invites has already been made twice. #2190 released the lock from a
// `defer { Task { await ... } }`, which hands the release to an unstructured task that runs AFTER the
// test returns, so the critical section was never exclusive: the process died partway and three
// consecutive runs each reported a DIFFERENT innocent test as failing while 600 to 1,500 tests silently
// never ran (#2195). Two more copies of that exact shape were still in the tree when this was written,
// in ListingLinkLabelLiveStoreTests, and nothing could have told anybody: the rule lived in prose and in
// nineteen correct examples to copy from.
//
// The issue asked for a helper that owns the pairing. It cannot be one: `RealStoreTestLock` deliberately
// takes no closure, because some callers are `@MainActor` and some are not, and sending a caller's body
// across would demand a Sendable it legitimately is not (the reasoning in `RealStoreTestLock.swift` is
// still true). So the pairing stays at the call site and this is what checks it.
@Suite("The real-store lock is released on every path (#2198)")
struct RealStoreLockPairingTests {

    // This file is excluded because it QUOTES every pattern it looks for, in its own checks and in the
    // messages naming them. A guard that cannot tell a line describing the mistake from a line making it
    // reports itself, which is the same trap the style hook has with a forbidden character.
    private static let guardFileName = "RealStoreLockPairingTests.swift"

    private var lockUsers: [AppSourceWalk.File] {
        AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("OvertureTests"), floor: 100)
            .filter { $0.name != Self.guardFileName }
            .filter { $0.text.contains("RealStoreTestLock.shared.acquire()") }
    }

    // The scan has to find the callers, or every check below passes by measuring nothing (#2311).
    @Test func theScanFindsTheFilesThatTakeTheLock() {
        #expect(lockUsers.count > 10, "found \(lockUsers.count) files taking the lock, which is too few")
    }

    // THE defect, in the exact shape it has taken both times. A release inside a `Task` is not a release
    // on this path at all: it is a promise to release later, after the test has already returned and the
    // next suite has already started building its container.
    @Test func noFileHandsTheReleaseToATask() {
        let offenders = lockUsers.filter { file in
            file.text.components(separatedBy: "\n").contains { line in
                line.contains("RealStoreTestLock.shared.release()") && line.contains("Task {")
            }
        }.map(\.name).sorted()

        #expect(offenders.isEmpty, """
            These release the real-store lock from inside a Task, so the critical section is not \
            exclusive and two suites can build a disk-backed container at once, which crashes the whole \
            process and reports an innocent test (#2190/#2195). Release inline on both paths instead, \
            with a do/catch: \(offenders.joined(separator: ", "))
            """)
    }

    // A file that takes the lock and never releases it deadlocks every later suite that wants it, which
    // presents as a run that hangs rather than one that fails.
    @Test func everyFileThatTakesTheLockAlsoReleasesIt() {
        let offenders = lockUsers
            .filter { !$0.text.contains("RealStoreTestLock.shared.release()") }
            .map(\.name).sorted()

        #expect(offenders.isEmpty,
                "these take the real-store lock and never release it: \(offenders.joined(separator: ", "))")
    }

    // Released on the THROWING path too, not only the happy one. A test that throws mid-critical-section
    // while holding the lock leaves every later suite waiting forever, and the run reads as a hang with
    // no failing test to point at. Counted rather than merely present: one release for a body that can
    // throw is one path covered out of two.
    @Test func aFileWhoseBodyCanThrowReleasesOnBothPaths() {
        let offenders = lockUsers.filter { file in
            // Only the files whose critical section can actually throw. A body that cannot has one path,
            // and demanding two of it would be a guard nobody could satisfy honestly.
            guard file.text.contains("try ") else { return false }
            let releases = file.text.components(separatedBy: "RealStoreTestLock.shared.release()").count - 1
            let acquires = file.text.components(separatedBy: "RealStoreTestLock.shared.acquire()").count - 1
            return releases < acquires * 2
        }.map(\.name).sorted()

        #expect(offenders.isEmpty, """
            These take the lock around a body that can throw but do not release it on both paths. A throw \
            while holding it leaves every later suite waiting forever, which reads as a hung run with no \
            failing test to point at: \(offenders.joined(separator: ", "))
            """)
    }
}
