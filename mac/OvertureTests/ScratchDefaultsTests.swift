import Testing
import Foundation

// #3774: the helper every test's defaults come from leaves nothing in ~/Library/Preferences.
//
// The removal is checked against the REAL folder, because that is where the leak was and where a
// preferences daemon decides what a file does: a stand-in directory could only prove what this file
// assumes about the daemon (L52). The sweep is checked against a stand-in, because it deletes by owner
// and a test must never be able to delete somebody else's real file (L2).
@Suite("Test defaults leave nothing in Preferences (#3774)")
struct ScratchDefaultsTests {

    private func preferencesFile(_ name: String) -> URL {
        ScratchDefaults.preferencesDirectory.appendingPathComponent("\(name).plist")
    }

    // The measured failure first: a written suite IS a file, which is the whole reason this exists.
    // Without this the removal assertion below could pass on a daemon that never wrote one (L159).
    @MainActor
    @Test func awrittenSuiteRemovedByTheHelperLeavesNoFile() async throws {
        let (defaults, name) = ScratchDefaults.makeNamed("removal-check")
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        let file = preferencesFile(name)
        let written = await waitUntil("the written suite's file to appear in Preferences",
                                      timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: file.path)
        }
        #expect(written, "the premise: writing a suite makes a file in Preferences")

        ScratchDefaults.remove(suiteNamed: name)
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the helper removed the suite and its file is still there, which is the #3774 leak")
    }

    @Test func thenameCarriesThePrefixAndTheOwner() {
        let id = UUID()
        let name = ScratchDefaults.suiteName(label: "a label/with odd.chars", pid: 4242, id: id)
        #expect(name == "overture-test-scratch.4242.a-label-with-odd-chars-\(id.uuidString)")
        #expect(ScratchDefaults.owner(ofFileNamed: "\(name).plist") == 4242)
    }

    @Test func afileThatIsNotOursHasNoOwner() {
        #expect(ScratchDefaults.owner(ofFileNamed: "com.apple.finder.plist") == nil)
        #expect(ScratchDefaults.owner(ofFileNamed: "gmail-sig-test-\(UUID().uuidString).plist") == nil)
        #expect(ScratchDefaults.owner(ofFileNamed: "overture-test-scratch.notapid.x.plist") == nil)
    }

    // The sweep deletes ONLY our files whose owner is gone: never a live process's, never anyone else's.
    @Test func thesweepRemovesOnlyOurFilesWhoseOwnerIsGone() throws {
        let sandboxes = TemporarySandboxes()
        let dir = try sandboxes.make(named: "scratch-defaults-sweep")
        let dead = "overture-test-scratch.111.dead-\(UUID().uuidString).plist"
        let live = "overture-test-scratch.222.live-\(UUID().uuidString).plist"
        let foreign = "someone-else-\(UUID().uuidString).plist"
        for file in [dead, live, foreign] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(file).path, contents: Data())
        }

        let removed = ScratchDefaults.sweepDeadOwners(in: dir, isAlive: { $0 == 222 })

        #expect(removed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(dead).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(live).path),
                "the sweep deleted a file whose owner is still running")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(foreign).path),
                "the sweep deleted a file that is not ours")
    }
}
