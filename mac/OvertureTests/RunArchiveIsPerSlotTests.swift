import Testing
import Foundation

// #2760: the archive was one `prep-run-archives` folder with one `keep`, so a busy night of checks evicts
// the prep archives #1616's learner reads, and two runs stamped in the same second collide on the folder
// name, at which point the second archives nothing at all and says nothing (it reads as `alreadyArchived`,
// which is a real outcome for a retry and a lie for a different run).
@Suite("Each slot keeps its own run archive (#2760)")
struct RunArchiveIsPerSlotTests {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeRun(_ slot: RunSlot, in dir: URL, generatedAt: String) throws {
        let queue = #"{"version":8,"generatedAt":"\#(generatedAt)","items":[]}"#
        try queue.data(using: .utf8)!.write(to: slot.queueURL(in: dir))
        let results = #"{"version":2,"generatedAt":"\#(generatedAt)","results":[]}"#
        try results.data(using: .utf8)!.write(to: slot.resultsURL(in: dir))
    }

    // The collision, stated as the thing it destroys: two runs whose `generatedAt` lands in the same second
    // produce the same folder name, and the second one's evidence is silently dropped. Separate folders is
    // what makes that impossible rather than unlikely.
    @Test func twoRunsStampedInTheSameSecondBothGetArchived() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = "2026-08-16T21:03:07Z"
        try writeRun(.prep, in: dir, generatedAt: stamp)
        try writeRun(.check, in: dir, generatedAt: stamp)

        let prep = PrepRunArchive.archiveFinishedRun(slot: .prep, handoffDirectory: dir, now: Date())
        let check = PrepRunArchive.archiveFinishedRun(slot: .check, handoffDirectory: dir, now: Date())

        guard case .archived(let prepFolder, _, let prepMissing) = prep else {
            Issue.record("the prep run was not archived: \(prep)"); return
        }
        guard case .archived(let checkFolder, _, let checkMissing) = check else {
            Issue.record("the check was not archived: \(check)"); return
        }
        #expect(prepMissing.isEmpty)
        #expect(checkMissing.isEmpty)
        #expect(prepFolder != checkFolder)
        #expect(FileManager.default.fileExists(atPath: prepFolder.path))
        #expect(FileManager.default.fileExists(atPath: checkFolder.path))
    }

    // The eviction. Rotation prunes the folder it is pruning and no other, so a night of checks cannot age
    // out the prep history the learner reads.
    @Test func aRunOfChecksDoesNotEvictThePrepArchives() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRun(.prep, in: dir, generatedAt: "2026-08-16T09:00:00Z")
        _ = PrepRunArchive.archiveFinishedRun(slot: .prep, handoffDirectory: dir, now: Date())

        // Far more checks than any keep count would hold.
        for minute in 0..<8 {
            try writeRun(.check, in: dir, generatedAt: String(format: "2026-08-16T10:%02d:00Z", minute))
            _ = PrepRunArchive.archiveFinishedRun(slot: .check, handoffDirectory: dir, now: Date(), keep: 2)
        }

        let prepArchives = (try? FileManager.default.contentsOfDirectory(
            atPath: RunSlot.prep.archivesDirectory(in: dir).path))?
            .filter(PrepRunArchive.isArchivedRunFolder) ?? []
        #expect(prepArchives.count == 1, "the prep run's evidence must survive a night of checks")
    }

    // The files INSIDE the folder are the slot's own too, or a check's archive would claim to hold a prep
    // run's work-list and nothing reading it later could tell.
    @Test func theArchivedFilesCarryTheSlotsOwnNames() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRun(.check, in: dir, generatedAt: "2026-08-16T11:00:00Z")

        let outcome = PrepRunArchive.archiveFinishedRun(slot: .check, handoffDirectory: dir, now: Date())

        guard case .archived(let folder, let copied, _) = outcome else {
            Issue.record("not archived: \(outcome)"); return
        }
        #expect(copied.sorted() == ["overture-check-queue.json", "overture-check-results.json"])
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("overture-check-queue.json").path))
    }
}
