import Foundation
import Testing

// #3065: the suite creates scratch directories under the per-user temp folder and never removes them.
// macOS clears that folder only at boot, so they accumulate for as long as the machine stays up.
//
// Measured on this Mac 2026-08-22, on an uptime of 8 days, counting only the shapes this repo's tests
// create: 952 debug-seed-test, 560 census, 336 prep-results, 224 prep-reply-cancel, 224
// performer-failure, 112 each of scout-snapshot, scout-extract-cancel and overture-test, and 56 each of
// venue-identity, no-repo, debug-seed-missing and debug-seed-gmail-missing. Every count is a multiple of
// 56, which is how many times the suite had run, so the per-run leak is about 52 directories.
//
// COUNTING CALL SITES WILL NOT FIND THIS, which is why the fix is a type and not a review. Downbeat had
// the identical bug and the static read was actively misleading there: 96 createDirectory calls against
// 95 defer cleanups, which looks balanced, while the suite leaked 52 directories per run, because one
// private helper is called by many tests and a single missing teardown multiplies. One helper there had
// left 7,616 directories on its own. Overture has 166 createDirectory call sites across 136 files.
//
// A defer beside each call site is the tempting fix and is the wrong one: it is a rule every future test
// has to remember, which is a rule living in a prompt (L27). Swift Testing builds a fresh instance of a
// `final class` suite for each test and releases it whether the test passed or threw, so deinit is real
// per-test teardown that no call site can forget.
@Suite("Scratch directories do not outlive the test that made them (#3065)")
struct TemporarySandboxesTests {

    @Test func aSandboxIsARealDirectoryOnDisk() throws {
        let sandboxes = TemporarySandboxes()
        let url = try sandboxes.make(named: "sandbox-shape-check")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "a sandbox has to be a directory a test can write into")
    }

    // The name is what makes a stray directory attributable to this repo at all, and it is the shape
    // scripts/check-temp-dir-leaks.sh judges by. A sandbox built as a bare UUID cannot be told apart
    // from any other application's scratch, so it would be exempt from the very check meant to catch it.
    @Test func theNameCarriesThePrefixAndAUUIDSoALeakCanBeTracedBack() throws {
        let sandboxes = TemporarySandboxes()
        let url = try sandboxes.make(named: "attributable-prefix")
        let name = url.lastPathComponent
        #expect(name.hasPrefix("attributable-prefix-"))
        let uuidPart = String(name.dropFirst("attributable-prefix-".count))
        #expect(UUID(uuidString: uuidPart) != nil,
                "the tail has to be a UUID, or the leak check cannot tell this from another app's scratch")
    }

    @Test func twoSandboxesFromOneInstanceAreDifferentDirectories() throws {
        let sandboxes = TemporarySandboxes()
        let first = try sandboxes.make(named: "distinct")
        let second = try sandboxes.make(named: "distinct")
        #expect(first != second)
    }

    // The failure being fixed. A cleanup that kept only the LAST url would pass a one-sandbox test and
    // leak every other one, and a one-sandbox test is what anybody writes first.
    @Test func releasingTheHolderRemovesEveryDirectoryItHandedOutNotOnlyTheLast() throws {
        var sandboxes: TemporarySandboxes? = TemporarySandboxes()
        let urls = try (0 ..< 4).map { _ in try #require(sandboxes).make(named: "released-together") }
        for url in urls {
            #expect(FileManager.default.fileExists(atPath: url.path), "the fixture has to start with them present")
        }

        sandboxes = nil

        for url in urls {
            #expect(!FileManager.default.fileExists(atPath: url.path),
                    "every sandbox goes when the holder does, not just the last one")
        }
    }

    // A sandbox a test filled with files still goes. removeItem on a non-empty directory is the whole
    // point: venue-identity sandboxes were about 4 MB each, so an empty-directory-only cleanup would
    // reclaim the count and none of the bytes.
    @Test func aSandboxWithContentInItIsRemovedWholeNotJustIfEmpty() throws {
        var sandboxes: TemporarySandboxes? = TemporarySandboxes()
        let url = try #require(sandboxes).make(named: "not-empty")
        let nested = url.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("some bytes".utf8).write(to: nested.appendingPathComponent("file.txt"))

        sandboxes = nil

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // One directory that cannot be removed must not take the others with it. The cleanup runs in a
    // deinit, where a throw has nowhere to go and would abandon the rest of the list.
    @Test func oneUnremovableSandboxDoesNotStopTheRest() throws {
        var sandboxes: TemporarySandboxes? = TemporarySandboxes()
        let doomed = try #require(sandboxes).make(named: "already-gone")
        let survivor = try #require(sandboxes).make(named: "still-there")
        // Removed out from under the holder, so its own removal fails when the deinit reaches it.
        try FileManager.default.removeItem(at: doomed)

        sandboxes = nil

        #expect(!FileManager.default.fileExists(atPath: survivor.path),
                "a failure on one entry cannot be allowed to abandon the ones after it")
    }

    // A reserved path is NOT created, which is the whole point: several suites test code whose job is
    // to create its own destination, and handing those an existing directory removes the condition
    // under test. It is still owned, so whatever the code under test puts there is still cleaned up.
    @Test func aReservedPathIsNotCreatedButIsStillCleanedUp() throws {
        var sandboxes: TemporarySandboxes? = TemporarySandboxes()
        let reserved = try #require(sandboxes).reserve(named: "reserved-not-created")
        #expect(!FileManager.default.fileExists(atPath: reserved.path),
                "reserving must not create it, or the absent-destination tests stop testing anything")

        // The code under test would create it. Stand in for that here.
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: reserved.appendingPathComponent("made-by-the-code-under-test"))

        sandboxes = nil

        #expect(!FileManager.default.fileExists(atPath: reserved.path),
                "what the code under test created at a reserved path still goes with the holder")
    }

    // A reserved path that was never created is not an error at teardown. That is the ordinary case for
    // a test asserting the code under test REFUSED to create something.
    @Test func aReservedPathNeverCreatedIsHarmlessAtTeardown() throws {
        var sandboxes: TemporarySandboxes? = TemporarySandboxes()
        let reserved = try #require(sandboxes).reserve(named: "reserved-never-made")
        let alsoReal = try #require(sandboxes).make(named: "reserved-neighbour")

        sandboxes = nil

        #expect(!FileManager.default.fileExists(atPath: reserved.path))
        #expect(!FileManager.default.fileExists(atPath: alsoReal.path),
                "and the entry that never existed does not abandon the one after it")
    }

    // The safety property, asserted rather than assumed, because this is deletion code (L5). It removes
    // ONLY what it minted itself: a path it handed out, under the temp folder, carrying a UUID it
    // generated. A neighbour in the same folder that it never handed out is not its to remove, and
    // nothing about the deinit loop makes that obvious from reading it.
    @Test func itRemovesOnlyWhatItHandedOutAndLeavesANeighbourAlone() throws {
        var sandboxes: TemporarySandboxes? = TemporarySandboxes()
        let mine = try #require(sandboxes).make(named: "mine-to-remove")

        // A directory beside it that this instance never handed out. Standing in for another test's
        // sandbox, another worktree's run, or anything else sharing the one temp folder.
        let notMine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-mine-to-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notMine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notMine) }

        sandboxes = nil

        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: notMine.path),
                "a directory it never handed out is not its to remove")
    }

    // Every sandbox lands under the per-user temp folder, which is the folder the leak check reads and
    // the only one macOS clears at boot. A sandbox somewhere else is invisible to both.
    @Test func sandboxesLiveInTheTempFolderTheLeakCheckReads() throws {
        let sandboxes = TemporarySandboxes()
        let url = try sandboxes.make(named: "under-tmp")
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        #expect(url.standardizedFileURL.deletingLastPathComponent().path == temp)
    }
}
