import Testing
import Foundation
import SwiftData

// #1672. Four suites rehearsed a migration against Dan's real store, each copying the `.store`, its
// `-wal` and its `-shm` one file at a time, with no checkpoint and no lock, while Overture Release may be
// actively writing. A store copied mid-write can land with a `-wal` that does not correspond to the
// `.store` beside it, and a dry run against that answers a question about a torn copy rather than about
// Dan's data.
//
// And nothing structurally stopped a fifth from being written without the copy at all. The rule lived in
// four repeated correct implementations and a comment (L2).
@MainActor
@Suite("Reading the live store goes through one consistent clone (#1672)")
struct LiveStoreCloneTests {
    private func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-clone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // On a machine with no live store there is nothing to rehearse against, and saying so is the point:
    // returning nil is what lets each suite skip, where a throw would turn a fresh clone red.
    @Test func nolivestoreMeansNothingToClone() throws {
        guard LiveStoreClone.liveStoreURL == nil else { return }
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try LiveStoreClone.makeClone(in: dir) == nil)
    }

    // The clone is a real, openable database carrying Dan's rows, and it is NOT the live file. Both halves
    // matter: a copy that will not open is a dry run that proves nothing, and handing back the live path
    // is the accident this whole helper exists to make impossible.
    @Test func thecloneIsAReadableCopyAndNeverTheLiveFile() throws {
        guard let live = LiveStoreClone.liveStoreURL else { return }
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clone = try #require(try LiveStoreClone.makeClone(in: dir))
        #expect(clone.path != live.path)
        #expect(clone.path.hasPrefix(dir.path), "the clone must live in the caller's own directory")

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: clone)])
        let count = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).count
        #expect(count > 0, "a clone of the live store with no shows in it is not a clone worth rehearsing against")
    }

    // The clone is SELF-CONTAINED: it opens read-only, on its own, with nothing beside it.
    //
    // This is the property rather than "no -wal file exists", which is a proxy for it (L63). The online
    // backup preserves the SOURCE's journal mode, and the live store is in WAL, so a clone left that way
    // carries no `-shm` and cannot be opened read-only at all: a read-only connection is not allowed to
    // create the shared-memory file it would need. Every census read here opens read-only on purpose, so
    // the clone is converted to a plain database. Measured through the reader that actually broke.
    @Test func thecloneOpensReadOnlyOnItsOwn() throws {
        guard LiveStoreClone.liveStoreURL != nil else { return }
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clone = try #require(try LiveStoreClone.makeClone(in: dir))
        // #2930: the census names its own refusal now, so a clone that cannot be read read-only reports
        // WHICH refusal (the WAL-without-shm one this conversion exists for reads as couldNotOpen) rather
        // than an absent number that could equally have been a missing column.
        let reading = StoreColumnCensus.nonNullRows(table: "ZPROSPECT", column: "Z_PK",
                                                    inSQLiteFileAt: clone.path)
        if case .unreadable(let why) = reading {
            Issue.record(Comment(rawValue: "the clone could not be read read-only (\(why)), so every "
                                 + "census against it would report nothing"))
        }
    }

    // THE refusal. It can only fire if the directory handed in resolves to the live store's own, and the
    // cost of being wrong there is a test writing to the only copy of Dan's queue.
    @Test func itrefusesToHandBackTheLiveStoreItself() throws {
        guard let live = LiveStoreClone.liveStoreURL else { return }
        #expect(throws: LiveStoreClone.Refusal.self) {
            _ = try LiveStoreClone.makeClone(in: live.deletingLastPathComponent())
        }
    }
}

// The structural half: nothing else copies the store by hand.
@Suite("No test copies the live store by hand (#1672)")
struct LiveStoreCopyGuardTests {
    private static var testsRoot: URL { RepoRoot.mac.appendingPathComponent("OvertureTests") }

    // A file that both reaches for the live store path AND copies files is doing by hand what the shared
    // clone exists to do once, correctly. The helper itself is the one place allowed to.
    //
    // Named as a rule about the two things TOGETHER, because either alone is legitimate: several suites
    // read the live store read-only and never copy, and plenty of tests copy fixtures around.
    @Test func nothingButTheHelperCopiesTheLiveStore() throws {
        var offenders: [String] = []
        for dir in ["", "../OvertureHostedTests"] {
            let root = Self.testsRoot.appendingPathComponent(dir).standardizedFileURL
            // #2311: through the shared walk, so a root that stops resolving refuses instead of
            // reporting that nothing copies the live store.
            for file in AppSourceWalk.files(under: root, floor: 20) {
                // The helper itself, and its own tests, which name the live path to assert the refusal
                // and to skip when there is no live store.
                guard !["LiveStoreClone.swift", "LiveStoreCloneTests.swift"].contains(file.name)
                else { continue }
                guard file.text.contains("StoreLocation.storeURL(appSupport:") else { continue }
                if file.text.contains("copyItem(") { offenders.append(file.name) }
            }
        }
        #expect(offenders.sorted().isEmpty,
                """
                these copy the live store by hand instead of going through LiveStoreClone: \
                \(offenders.sorted().joined(separator: ", ")). Three file copies raced against a live \
                writer can land with a -wal that does not match the .store beside it, and a dry run \
                against that says nothing about Dan's data (#1672).
                """)
    }

    // And the suites that rehearse a migration really do go through it, so the rule above is not being
    // satisfied by nobody cloning at all (L1).
    //
    // #3035: TWO sanctioned routes now, not one. The four dry runs reach the clone through
    // `MigrationRehearsal.begin`, which exists so a rehearsal that rehearsed NOTHING says so instead of
    // leaving the same green tick as one that examined Dan's whole store. That is an indirection, and an
    // indirection is exactly how a rule like this gets quietly satisfied by nobody, so the helper's own
    // use of `makeClone` is asserted below rather than assumed: without that line, "route through the
    // helper" would be a check on a name and not on what the name does.
    @Test func thesuitesThatRehearseAMigrationUseTheHelper() throws {
        for name in ["OrgAnswerMigrationDryRunTests", "InquiryMigrationDryRunTests",
                     "JointSendMigrationDryRunTests", "ReplyAudienceMigrationDryRunTests",
                     "CatchAllFitReasonRetirementTests", "ContactFormReachabilityTests",
                     "CancelledShootMigrationDryRunTests"] {
            let url = Self.testsRoot.appendingPathComponent("\(name).swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("LiveStoreClone.makeClone(in:")
                        || text.contains("MigrationRehearsal.begin("),
                    "\(name) no longer clones the live store through the shared helper")
        }
    }

    // #3035: and the indirection really does end at `makeClone`. Asserted separately rather than folded
    // into the loop above, because a single check written as two conditions over one body of text is
    // satisfied by two unrelated places in it and so proves neither half (L178).
    @Test func theRehearsalHelperItselfClonesThroughTheSharedHelper() throws {
        let url = Self.testsRoot.appendingPathComponent("MigrationRehearsal.swift")
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains("LiveStoreClone.makeClone(in:"))
        #expect(!text.contains("copyItem("))
    }
}

// #3349: the clone WAITS for a contended lock instead of giving up on the first attempt.
//
// Found by running. On the first complete parallel run of the whole suite the only failure was
// `SameNightRoomVariantMergeLiveStoreTests.everySurvivingRowStillNamesItsRoom()`, and the result bundle
// gives the reason as `LiveStoreClone.swift: Caught error: ... Error: database is locked`. Serially it
// had never happened, because nothing else was cloning at the same moment: Swift Testing runs the tests
// of one process concurrently, and twenty-two suites here take their own clone of Dan's real store.
//
// It is NOT a lock that fixes it, and the reason is worth keeping. Thirteen of the suites that clone
// never took `RealStoreTestLock`, six of them reaching the clone through `MigrationRehearsal` rather
// than naming it, so a lock would have been a convention repeated at thirty-seven call sites with
// thirteen already forgetting it (L274, L96). A busy timeout is answered by the one thing every one of
// them goes through, and it also covers the contention no test lock can reach, which is Dan's live app
// writing while a suite clones.
//
// WHAT THESE MEASURE, and it is deliberately not "several clones at once". That was written first and
// it did not discriminate: twelve simultaneous clones of a scratch database passed with the timeout set
// to ZERO, which is the configuration the defect lives in, so the test would have been green whether
// the fix was there or not (L159). Contention is a property of the source's lock, not of the number of
// callers, so these hold the lock EXPLICITLY and measure the one thing the timeout changes: whether the
// backup waits for it. Measured in a shell before it was written, against a source held by an exclusive
// transaction: `.timeout 0` fails in 0.00 seconds, `.timeout 800` fails after 0.891, and both say
// `Error: database is locked`.
//
// The corpus is a scratch database rather than the live store, deliberately: this must measure the same
// thing on a machine that has no live store at all, and a test of lock contention has no business
// opening Dan's queue (L2).
@Suite("The clone waits for a contended lock (#3349)")
struct ContendedLiveStoreCloneTests {

    private func sqlite(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0,
                "the fixture's own sqlite3 call failed, so nothing below measures anything")
    }

    /// A source in ROLLBACK JOURNAL mode, held by an exclusive transaction in another process.
    ///
    /// Rollback journal rather than WAL on purpose: in WAL a writer does not block a reader, so an
    /// exclusive transaction there contends with nothing and the fixture would prove the opposite of
    /// what it claims. Measured, not assumed: the WAL version of this was tried first and every backup
    /// succeeded while the lock was held.
    private final class ExclusiveHolder {
        private let process = Process()
        private let input = Pipe()
        init(holding database: URL) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [database.path]
            process.standardInput = input
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            // Left UNCOMMITTED and the pipe left open, which is what holds the lock.
            try input.fileHandleForWriting.write(contentsOf: Data("BEGIN EXCLUSIVE;\nINSERT INTO t VALUES(99);\n".utf8))
        }
        /// Commits and lets the process end. Idempotent, so `defer` can call it after the test already has.
        ///
        /// The wait is BOUNDED and ends in a `terminate()`. `Process.waitUntilExit()` has no deadline, so
        /// a holder that did not exit on EOF would hang the suite while holding the machine-wide
        /// xcodebuild lock, which is worse than any failure this fixture can report (L110).
        func release() {
            try? input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(10)
            while process.isRunning && ContinuousClock.now < deadline {
                usleep(2_000)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        /// The last resort, so a fixture that fails early cannot leave a process holding a lock behind it.
        func endWhateverHappened() {
            if process.isRunning { process.terminate() }
            release()
        }
    }

    /// Returns the refusal a clone made, or nil when it succeeded, with how long the attempt took.
    private func attemptClone(of source: URL, into dir: URL, timeoutMilliseconds: Int)
        -> (failure: String?, elapsed: Duration) {
        let started = ContinuousClock.now
        do {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try LiveStoreClone.makeClone(ofBackupAt: source, in: dir,
                                             timeoutMilliseconds: timeoutMilliseconds)
            return (nil, ContinuousClock.now - started)
        } catch {
            return ("\(error)", ContinuousClock.now - started)
        }
    }

    // The shipped path really asks for a retry window. Asserted on the arguments rather than on a
    // comment, because the whole defect was a wait nobody had asked for (L3).
    @Test func thebackupAsksSqliteToWaitForTheLock() {
        let arguments = LiveStoreClone.backupArguments(source: URL(fileURLWithPath: "/tmp/a.store"),
                                                       clone: URL(fileURLWithPath: "/tmp/b.store"),
                                                       timeoutMilliseconds: 1234)
        #expect(arguments.contains(".timeout 1234"),
                "the backup does not pass a busy timeout, so the first contended attempt fails outright: \(arguments)")
        // Before the database, because `-cmd` runs ahead of what follows it: a timeout set afterwards
        // would be set on a connection that has already failed.
        let timeoutAt = arguments.firstIndex(of: ".timeout 1234")
        let databaseAt = arguments.firstIndex(of: "/tmp/a.store")
        #expect(timeoutAt != nil && databaseAt != nil && timeoutAt! < databaseAt!,
                "the timeout must be set before the database is opened: \(arguments)")
        #expect(LiveStoreClone.busyTimeoutMilliseconds > 0,
                "a zero busy timeout is the same as none at all, which is the defect this fixes")
    }

    @Test func acontendedCloneWaitsForTheLockRatherThanGivingUpAtOnce() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clone-contention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("Overture.store")
        try sqlite([source.path, "PRAGMA journal_mode=DELETE; CREATE TABLE t(a INTEGER); INSERT INTO t VALUES(1);"])

        let holder = try ExclusiveHolder(holding: source)
        defer { holder.endWhateverHappened() }

        // Both attempts are made against the SAME held lock, so the only difference between them is the
        // timeout. Comparing them against each other rather than against a fixed number is what keeps
        // this a measurement of the wait and not of the machine (L224).
        let withoutWaiting = attemptClone(of: source, into: root.appendingPathComponent("no-wait"),
                                          timeoutMilliseconds: 0)
        let waiting = attemptClone(of: source, into: root.appendingPathComponent("waits"),
                                   timeoutMilliseconds: 400)

        // Both still FAIL, because the lock is never released here. That is the point: the timeout buys
        // a wait, not an exemption, and a clone that could not be taken must still say so rather than
        // hand back a torn copy (L11).
        #expect(withoutWaiting.failure?.contains("locked") == true,
                "a clone with no busy timeout should be refused by the held lock: \(withoutWaiting.failure ?? "it succeeded")")
        #expect(waiting.failure?.contains("locked") == true,
                "a clone whose wait ran out should still be refused: \(waiting.failure ?? "it succeeded")")

        #expect(waiting.elapsed > withoutWaiting.elapsed,
                "the clone with a 1500ms timeout took \(waiting.elapsed) against \(withoutWaiting.elapsed) with none, so it did not wait at all")
        // A floor far below the 400ms asked for, and it cannot be reached by a slow machine, because
        // what is being waited on is a sleep rather than work. 400 rather than a comfortable few seconds
        // because this is real time the suite pays on every run, and the measured separation is wide:
        // with no timeout the same call returned in 0.07 seconds (L290).
        #expect(waiting.elapsed > .milliseconds(150),
                "the clone waited only \(waiting.elapsed) for a lock it was told to wait 400ms for")

        // And with the lock gone the same clone succeeds, so the refusals above are the lock and not a
        // fixture that could never have worked (L1).
        holder.release()
        let afterRelease = attemptClone(of: source, into: root.appendingPathComponent("released"),
                                        timeoutMilliseconds: LiveStoreClone.busyTimeoutMilliseconds)
        #expect(afterRelease.failure == nil,
                "the clone failed even with nothing holding the lock, so this fixture proves nothing: \(afterRelease.failure ?? "")")
    }
}
