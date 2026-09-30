import Darwin
import Foundation
import SwiftData
import Testing

// #4061: a test's file-backed store is closed before its directory is removed, and nothing in the test
// sources opens one any other way. See `FileStores` for the measurement behind the design.
@Suite("File stores are closed before their directory goes (#4061)")
struct FileStoresTests {

    private func scratch(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store with a saved row and an UNSAVED change in a context, which is the shape the Phase 0c rows
    /// probe left behind.
    private func openStoreWithAPendingChange(in dir: URL) throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        let container = try FileStores.container(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: dir.appendingPathComponent("probe.store"),
                               cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let show = Prospect(naturalKey: "file-stores-1", groupName: "Ensemble", discipline: "music",
                            venue: "Hall", performanceDate: "2027-01-01", sourceListingURL: nil,
                            priorRelationship: "none", production: "presenter", profile: "strong",
                            coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "original",
                            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                            status: .drafted)
        context.insert(show)
        try context.save()
        show.groupName = "Ensemble, renamed and never saved"
        return context
    }

    @Test func aStoreOpenedHereIsClosedBeforeItsDirectoryIsRemoved() throws {
        let dir = try scratch("file-stores-close")
        let context = try openStoreWithAPendingChange(in: dir)

        // The detector must be able to SEE an open store, or the empty answer below says nothing (L159).
        #expect(!FileStores.openFiles(under: dir).isEmpty,
                "the store's files are not seen as open while its container is live, so every check here is blind")

        #expect(FileStores.remove(dir), "the directory was left in place although its only store was recorded")
        #expect(FileStores.openFiles(under: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path), "the directory is still there")
        _ = context
    }

    @Test func aDirectoryHoldingAFileStillOpenIsLeftInPlace() throws {
        let dir = try scratch("file-stores-open-fd")
        let file = dir.appendingPathComponent("held.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
        let fd = open(file.path, O_RDONLY)
        #expect(fd >= 0)

        #expect(!FileStores.remove(dir), "a directory holding an open file was reported removed")
        #expect(FileManager.default.fileExists(atPath: dir.path), "a directory holding an open file was removed")

        close(fd)
        #expect(FileStores.remove(dir))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aSandboxGoingOutOfScopeClosesItsStoreAndRemovesTheDirectory() throws {
        var dir: URL?
        do {
            let sandboxes = TemporarySandboxes()
            let made = try sandboxes.make(named: "file-stores-sandbox")
            _ = try openStoreWithAPendingChange(in: made)
            #expect(!FileStores.openFiles(under: made).isEmpty)
            dir = made
        }
        let gone = try #require(dir)
        #expect(FileStores.openFiles(under: gone).isEmpty, "the sandbox removed its directory with the store still open")
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func aSandboxLeavesADirectoryWithAFileStillOpen() throws {
        var held: (URL, Int32)?
        do {
            let sandboxes = TemporarySandboxes()
            let made = try sandboxes.make(named: "file-stores-sandbox-open-fd")
            let file = made.appendingPathComponent("held.bin")
            #expect(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
            held = (made, open(file.path, O_RDONLY))
        }
        let (dir, fd) = try #require(held)
        #expect(FileManager.default.fileExists(atPath: dir.path), "the sandbox unlinked a file this process holds open")
        close(fd)
        FileStores.remove(dir)
    }

    // `deleteAllData()` destroys whatever store it is pointed at, so `close(under:)` must never act on a
    // path outside the temp folder, whatever it is handed (L42). Checked with a store that IS in the temp
    // folder and a request naming a directory that is not, so nothing real is touched.
    @Test func nothingOutsideTheTempFolderIsReleased() throws {
        let dir = try scratch("file-stores-refusal")
        // Held for the whole test: the registry holds containers weakly, so a dropped one could close
        // itself and make the refusal below pass for the wrong reason.
        let held = try openStoreWithAPendingChange(in: dir)
        defer { withExtendedLifetime(held) {} }
        let outside = URL(fileURLWithPath: "/usr/share")
        _ = FileStores.close(under: outside)
        #expect(!FileStores.openFiles(under: dir).isEmpty,
                "a close aimed outside the temp folder released a store")
        #expect(FileStores.remove(dir))
    }

    // The registry holds containers WEAKLY: recording one must never be what keeps it alive.
    @Test func recordingAContainerDoesNotKeepItAlive() throws {
        let schema = Schema([Prospect.self, Recipient.self])
        weak var recorded: ModelContainer?
        do {
            let made = try FileStores.container(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            #expect(FileStores.isRecorded(made), "the premise: the container was recorded")
            recorded = made
        }
        #expect(recorded == nil, "the registry kept a container alive that nothing else references")
    }

    // Off the main thread the main context's changes are still dropped, by a hop to the main queue.
    @MainActor
    @Test func aCloseOffTheMainThreadStillDropsTheMainContextsChanges() async throws {
        let dir = try scratch("file-stores-off-main")
        let schema = Schema([Prospect.self, Recipient.self])
        let container = try FileStores.container(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: dir.appendingPathComponent("probe.store"), cloudKitDatabase: .none)])
        container.mainContext.autosaveEnabled = false
        container.mainContext.insert(Prospect(naturalKey: "file-stores-off-main", groupName: "Ensemble", discipline: "music",
                                              venue: "Hall", performanceDate: "2027-01-01", sourceListingURL: nil,
                                              priorRelationship: "none", production: "presenter", profile: "strong",
                                              coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "original",
                                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                              status: .drafted))
        #expect(container.mainContext.hasChanges, "the premise: the main context holds an unsaved change")
        let path = dir
        let left = await Task.detached { FileStores.close(under: path) }.value
        #expect(left.isEmpty)
        #expect(await waitUntil("the main context's changes dropped by the hop to the main queue") {
            !container.mainContext.hasChanges
        })
        FileStores.remove(dir)
    }

    // A directory already gone leaves nothing to close, and its containers are forgotten, not held for ever.
    @Test func aDirectoryAlreadyGoneForgetsItsContainers() throws {
        let dir = try scratch("file-stores-gone")
        let moved = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-moved")
        let schema = Schema([Prospect.self, Recipient.self])
        let container = try FileStores.container(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: dir.appendingPathComponent("probe.store"), cloudKitDatabase: .none)])
        // Moved, not deleted, so the open files are never unlinked while in use.
        try FileManager.default.moveItem(at: dir, to: moved)
        #expect(FileStores.close(under: dir).isEmpty)
        #expect(!FileStores.isRecorded(container), "a container whose directory is gone is still recorded")
        if #available(macOS 15, *) { container.deleteAllData() }
        try? FileManager.default.removeItem(at: moved)
    }

    // The temp folder itself is not a sandbox: a close aimed at it must not reach every suite's stores.
    @Test func theTempFolderItselfIsNeverReleased() throws {
        let dir = try scratch("file-stores-temp-root")
        // Held for the whole test: the registry holds containers weakly, so a dropped one could close
        // itself and make the refusal below pass for the wrong reason.
        let held = try openStoreWithAPendingChange(in: dir)
        defer { withExtendedLifetime(held) {} }
        _ = FileStores.close(under: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(!FileStores.openFiles(under: dir).isEmpty, "a close aimed at the temp folder released a store in it")
        #expect(FileStores.remove(dir))
    }
}

// The other half: a helper that has to be remembered at every call site is a rule living in prose, and
// the next probe is written by copying one of these (L27, L501, L613).
@Suite("Test sources open file stores only through FileStores (#4061)")
struct FileStoresGuardTests {

    private static let roots = ["OvertureTests", "OvertureHostedTests", "TestSupport"]
    private static let floor = 400

    /// Every `ModelContainer(` construction in `code` whose arguments do not make it in-memory, by line.
    static func fileBackedConstructions(in code: String) -> [Int] {
        let chars = Array(code)
        let needle = Array("ModelContainer(")
        var found: [Int] = []
        var i = 0
        while i + needle.count <= chars.count {
            guard Array(chars[i..<(i + needle.count)]) == needle,
                  i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "." || chars[i - 1] == "_")
            else { i += 1; continue }
            var depth = 1
            var j = i + needle.count
            while j < chars.count && depth > 0 {
                if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                j += 1
            }
            let args = String(chars[(i + needle.count)..<max(i + needle.count, j - 1)])
            if !args.contains("isStoredInMemoryOnly: true") {
                found.append(chars[0..<i].filter { $0 == "\n" }.count + 1)
            }
            i = j
        }
        return found
    }

    @Test func theScanSeesAFileBackedConstructionAndPassesAnInMemoryOne() {
        let bare = "let c = try ModelContainer(for: s,\n configurations: [ModelConfiguration(url: u)])"
        let memory = "let c = try ModelContainer(for: s, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])"
        let routed = "let c = try FileStores.container(for: s, configurations: [ModelConfiguration(url: u)])"
        #expect(Self.fileBackedConstructions(in: bare) == [1])
        #expect(Self.fileBackedConstructions(in: memory).isEmpty)
        #expect(Self.fileBackedConstructions(in: routed).isEmpty)
    }

    @Test func noTestOpensAFileStoreAnyOtherWay() {
        let files = AppSourceWalk.files(underAll: Self.roots.map(RepoRoot.mac.appendingPathComponent),
                                        floor: Self.floor)
        var offenders: [String] = []
        var routed = 0
        // The helper itself, and this file, which has to name the construction to find it.
        for file in files where file.name != "FileStores.swift" && file.name != "FileStoresTests.swift" {
            let lines = SwiftSource.scannableLines(in: file.text)
            let code = lines.map(\.code).joined(separator: "\n")
            if code.contains("FileStores.container(") { routed += 1 }
            // The scan counts lines of the scanned code; named here by the file's own line number.
            for line in Self.fileBackedConstructions(in: code) {
                offenders.append("\(file.name):\(lines.indices.contains(line - 1) ? lines[line - 1].line : line)")
            }
        }
        #expect(files.count >= Self.floor, "the test sources were not walked, so this guard checked nothing")
        // Measured 2026-09-29 when the class was fixed: 67 files open a file store. A count near zero means
        // the scan stopped matching, not that the stores went away (L90).
        #expect(routed >= 50, "only \(routed) files route a store through FileStores, so the scan is not seeing them")
        #expect(offenders.isEmpty, Comment(rawValue:
                "these open a file-backed ModelContainer directly, so nothing closes it before its directory "
                + "is removed and SQLite reports the store unlinked while in use, or a later autosave faults and "
                + "aborts xctest (#4061). Use `FileStores.container(for:configurations:)`: "
                + offenders.joined(separator: ", ")))
    }
}
