import Testing
import Foundation

// #2342: two protections stand around the handoff directory, and they answer different questions from
// different inputs. #2097 redirects the path a test WRITES to; `HandoffCleanup`'s pin refuses to DELETE
// from it. That folder holds the Gmail tokens, the booking history, and in Release the live SwiftData
// store, so the answer to "is this out of bounds?" must not depend on which guard is asked (L55).
//
// It already did. The pin compared its argument against `StoreLocation.handoffDirectory`, which since
// the redirect resolves to a temp folder under test, so it had quietly stopped naming Dan's real folder.
@Suite("The two handoff directory guards agree (#2342)")
struct HandoffOutOfBoundsAgreementTests {

    private let appSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support",
                                 isDirectory: true)

    private func live(debug: Bool) -> URL {
        StoreLocation.handoffDirectory(appSupport: appSupport, isDebugBuild: debug)
    }

    // Both builds' folders are out of bounds. The test bundle is always Debug, so a rule that named only
    // the Debug folder would leave the RELEASE one, which holds the live store, unprotected by the guard
    // written to protect it.
    @Test func bothBuildsLiveFoldersAreOutOfBounds() {
        #expect(StoreLocation.isLiveHandoffDirectory(live(debug: true), appSupport: appSupport))
        #expect(StoreLocation.isLiveHandoffDirectory(live(debug: false), appSupport: appSupport))
    }

    // A trailing slash names the same directory, and a guard that answered differently would fail in the
    // one direction that deletes files.
    @Test func aTrailingSlashIsTheSameDirectory() {
        let withSlash = URL(fileURLWithPath: live(debug: false).path + "/", isDirectory: true)
        #expect(StoreLocation.isLiveHandoffDirectory(withSlash, appSupport: appSupport))
    }

    // A test's own scratch folder is not out of bounds, which is what keeps every existing test that
    // passes a temp directory working rather than silently refused.
    @Test func aTestsOwnTempFolderIsNotOutOfBounds() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-2342-\(UUID().uuidString)", isDirectory: true)
        #expect(!StoreLocation.isLiveHandoffDirectory(temp, appSupport: appSupport))
        #expect(!StoreLocation.isLiveHandoffDirectory(StoreLocation.testRunHandoffDirectory,
                                                      appSupport: appSupport))
    }

    // The agreement itself, which is what the issue asked for: for every directory either guard could be
    // handed, the write redirect and the delete refusal must reach the same verdict. Written as a table
    // so a third guard, or a fourth directory, is one line rather than a new test nobody writes.
    @Test func theWriteRedirectAndTheDeleteRefusalNeverDisagree() {
        let cases: [(name: String, url: URL, outOfBounds: Bool)] = [
            ("the Release live folder", live(debug: false), true),
            ("the Debug live folder", live(debug: true), true),
            ("the per-test-run folder", StoreLocation.testRunHandoffDirectory, false),
            ("a folder a test named itself",
             FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere", isDirectory: true),
             false),
        ]
        for c in cases {
            // The delete side: what the sweep's pin decides about this directory.
            let refusesToDelete = StoreLocation.isLiveHandoffDirectory(c.url, appSupport: appSupport)
            // The write side: a request for this directory is redirected away from it under test exactly
            // when it is the live one, and left alone otherwise.
            let redirectedAwayFromWriting =
                StoreLocation.writableHandoffDirectory(c.url, isUnderTest: true) != c.url
                    && StoreLocation.isLiveHandoffDirectory(c.url, appSupport: appSupport)
            #expect(refusesToDelete == c.outOfBounds, "delete side disagreed about \(c.name)")
            #expect(redirectedAwayFromWriting == c.outOfBounds, "write side disagreed about \(c.name)")
        }
    }
}

// The pin's own result was written and never read anywhere (L46), so nothing had ever seen it fire. It
// is the more important of the two protections, because deletion is worse than writing.
@MainActor
@Suite("The handoff sweep refuses to delete from the live folder under test (#2342)")
struct HandoffSweepRefusesTheLiveFolderTests {

    @Test func sweepingTheLiveFolderUnderTestIsRefusedAndDeletesNothing() throws {
        // The REAL folder for this build, resolved the way the app resolves it rather than through
        // `StoreLocation.handoffDirectory`, which the #2097 redirect points at a temp folder here. That
        // is the whole point: this test would have passed for the wrong reason against the old pin.
        let liveDirectory = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport,
                                                           isDebugBuild: StoreLocation.isDebugBuild)

        let result = HandoffCleanup.sweep(handoffDirectory: liveDirectory, now: Date())

        #expect(result.refusedUnderTest)
        #expect(result.deleted.isEmpty)
        #expect(result.failed.isEmpty)
    }

    // And the Release folder specifically, which is where the live store lives and which a Debug test
    // bundle would otherwise have no reason to be refused from.
    @Test func theReleaseFolderIsRefusedEvenFromTheDebugTestBundle() {
        let releaseDirectory = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport,
                                                              isDebugBuild: false)

        #expect(HandoffCleanup.sweep(handoffDirectory: releaseDirectory, now: Date()).refusedUnderTest)
    }

    // A test's own directory still sweeps, so the refusal above is about WHERE and not about turning the
    // sweep off under test, which would leave every one of its rules unexercised.
    @Test func aTestsOwnDirectoryStillSweeps() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-2342-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("overture-scout-page-abc.html")
        try Data("<html></html>".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(HandoffCleanup.keepFor + 3_600))],
            ofItemAtPath: old.path)

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: Date())

        #expect(!result.refusedUnderTest)
        #expect(result.deleted.map(\.lastPathComponent) == ["overture-scout-page-abc.html"])
    }
}
