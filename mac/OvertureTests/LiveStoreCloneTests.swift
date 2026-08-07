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
        #expect(StoreColumnCensus.nonNullCount(table: "ZPROSPECT", column: "Z_PK",
                                               inSQLiteFileAt: clone.path) != nil,
                "the clone could not be read read-only, so every census against it would report nothing")
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
    private static var testsRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    // A file that both reaches for the live store path AND copies files is doing by hand what the shared
    // clone exists to do once, correctly. The helper itself is the one place allowed to.
    //
    // Named as a rule about the two things TOGETHER, because either alone is legitimate: several suites
    // read the live store read-only and never copy, and plenty of tests copy fixtures around.
    @Test func nothingButTheHelperCopiesTheLiveStore() throws {
        let fm = FileManager.default
        var offenders: [String] = []
        for dir in ["", "../OvertureHostedTests"] {
            let root = Self.testsRoot.appendingPathComponent(dir).standardizedFileURL
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // The helper itself, and its own tests, which name the live path to assert the refusal
                // and to skip when there is no live store.
                guard !["LiveStoreClone.swift", "LiveStoreCloneTests.swift"].contains(url.lastPathComponent)
                else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard text.contains("StoreLocation.storeURL(appSupport:") else { continue }
                if text.contains("copyItem(") { offenders.append(url.lastPathComponent) }
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

    // And the four suites that rehearse a migration really do go through it, so the rule above is not
    // being satisfied by nobody cloning at all (L1).
    @Test func thesuitesThatRehearseAMigrationUseTheHelper() throws {
        for name in ["OrgAnswerMigrationDryRunTests", "InquiryMigrationDryRunTests",
                     "CatchAllFitReasonRetirementTests", "ContactFormReachabilityTests"] {
            let url = Self.testsRoot.appendingPathComponent("\(name).swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("LiveStoreClone.makeClone(in:"),
                    "\(name) no longer clones the live store through the shared helper")
        }
    }
}
