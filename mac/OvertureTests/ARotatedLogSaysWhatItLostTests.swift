import Testing
import Foundation

// #3789: what a rotation of one of this app's logs COSTS, and where that is said.
//
// `LogRotation.cap` is shared by five call sites covering eight log files. Before this it copied a file
// to `.1`, deleting any prior `.1` first, then truncated the live file, and said nothing anywhere: the
// return value was `@discardableResult` and every caller dropped it, nothing in the app or the toolchain
// ever opened a `.1`, and the generation before last was destroyed on every second rotation with no
// record that it had existed (L98, L11, L46).
//
// Worse than silent. The copy was a `try?` whose failure was swallowed and the truncation ran anyway, so
// a rotation that could not write its backup emptied the live file and the content was gone.
@Suite("A rotated log says what it lost (#3789)")
final class ARotatedLogSaysWhatItLostTests {
    let sandboxes = TemporarySandboxes()

    @discardableResult
    private func file(_ directory: URL, named name: String, bytes: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(String(repeating: "x", count: bytes).utf8).write(to: url)
        return url
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - The helper no longer destroys what it cannot copy

    // THE FAILURE PATH, and the reason this was the first test written. Measured against the code as it
    // stood on 2026-09-11: `(survived -> 0) == (4_096 -> 4096)`, meaning the live file came back empty
    // with no `.1` anywhere (L5, L105).
    @Test func aRotationThatCannotWriteItsBackupLeavesTheLiveFileAlone() throws {
        let directory = try sandboxes.make(named: "overture-logrotation-test")
        let log = try file(directory, named: "some.log", bytes: 4_096)
        // The DIRECTORY, not the file: a read-only directory refuses the `.1` entry being created while
        // leaving the live file itself perfectly writable and truncatable, which is exactly the split
        // that made the old behaviour destructive.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let report = LogRotation.cap(files: [log], maxBytes: 1_024)

        #expect((try? Data(contentsOf: log))?.count == 4_096)
        #expect(!FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
        // And it SAYS so. A file left over its cap and a file under its cap are different states, and a
        // refusal that reported nothing would leave them indistinguishable (L11).
        #expect(report.rotated.isEmpty)
        #expect(report.refused == [LogRotation.Refusal(file: log, reason: .backupCouldNotBeWritten)])
        #expect(report.lostSomething)
        #expect(report.notes.first?.contains("left alone rather than emptied") == true)
    }

    // The other half of the same failure: the copy that cannot be written must not cost the generation
    // already sitting beside it, which is the only copy of everything the log held before the last
    // rotation. The old order removed the prior `.1` FIRST and then attempted the copy.
    @Test func aRotationThatCannotWriteItsBackupKeepsTheGenerationAlreadyThere() throws {
        let directory = try sandboxes.make(named: "overture-logrotation-test")
        let log = try file(directory, named: "some.log", bytes: 4_096)
        let previous = try file(directory, named: "some.log.1", bytes: 2_048)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let report = LogRotation.cap(files: [log], maxBytes: 1_024)

        #expect((try? Data(contentsOf: previous))?.count == 2_048)
        #expect(report.refused.count == 1)
    }

    // MARK: - What a rotation that worked reports

    @Test func aFirstRotationSaysNothingWasLost() throws {
        let directory = try sandboxes.make(named: "overture-logrotation-test")
        let log = try file(directory, named: "some.log", bytes: 4_096)

        let report = LogRotation.cap(files: [log], maxBytes: 1_024)

        #expect(report.rotated.count == 1)
        #expect(report.rotated.first?.movedBytes == 4_096)
        // nil, not zero: no previous generation is a different fact from a previous generation that was
        // empty, and folding them together is what makes a loss unreadable afterwards.
        #expect(report.rotated.first?.discardedBytes == nil)
        #expect(!report.lostSomething)
        #expect(report.notes.first?.contains("Nothing older was being kept") == true)
        // It loses nothing, so the surfaces that interrupt Dan say nothing about it.
        #expect(report.lossNotes.isEmpty)
        #expect((try? Data(contentsOf: log))?.count == 0)
        #expect((try? Data(contentsOf: log.appendingPathExtension("1")))?.count == 4_096)
    }

    // The rotation this issue is about: the second one, which deletes the `.1` the first one wrote.
    @Test func aSecondRotationNamesTheBytesItDeleted() throws {
        let directory = try sandboxes.make(named: "overture-logrotation-test")
        let log = try file(directory, named: "some.log", bytes: 2_048)
        _ = LogRotation.cap(files: [log], maxBytes: 1_024)
        try file(directory, named: "some.log", bytes: 4_096)

        let report = LogRotation.cap(files: [log], maxBytes: 1_024)

        #expect(report.rotated.first?.discardedBytes == 2_048)
        #expect(report.lostSomething)
        #expect(report.notes.first?.contains("deleted the 2048 bytes") == true)
        #expect(report.notes.first?.contains("That older content is gone") == true)
        #expect(report.lossNotes.count == 1)
    }

    // A rotation that leaves no leftover working file behind. The copy goes to an `incoming` name and is
    // renamed into place, which is what keeps a failed copy from costing the generation already there,
    // and a leftover would be a file nothing ever cleans up in the directory that also holds the store.
    @Test func aRotationLeavesNoWorkingFileBehind() throws {
        let directory = try sandboxes.make(named: "overture-logrotation-test")
        let log = try file(directory, named: "some.log", bytes: 4_096)

        _ = LogRotation.cap(files: [log], maxBytes: 1_024)

        let left = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        #expect(left == ["some.log", "some.log.1"])
    }

    @Test func aFileUnderItsCapIsNotAnEvent() throws {
        let directory = try sandboxes.make(named: "overture-logrotation-test")
        let log = try file(directory, named: "some.log", bytes: 512)

        let report = LogRotation.cap(files: [log], maxBytes: 1_024)

        #expect(report.isEmpty)
        #expect(report.notes.isEmpty)
        #expect(!report.lostSomething)
    }

    // MARK: - Each log says it, in the way that log says anything

    // backup.log is the one #3789 names first. It is the record of whether Dan's live store was copied,
    // read after the fact, and a rotation that silently discarded the older half of it was discarding
    // the evidence for the one question it exists to answer (AGENTS.md, "Restoring Overture from a
    // backup"). ONE generation stays enough now that the loss is written down.
    @Test func theStoreBackupLogRecordsItsOwnRotation() throws {
        let dataDirectory = try sandboxes.make(named: "overture-storebackup-rotation-test")
        try Data("store".utf8).write(to: dataDirectory.appendingPathComponent(StoreLocation.storeFilename))
        let backups = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let log = backups.appendingPathComponent("backup.log")
        try Data(String(repeating: "x", count: StoreBackup.maxLogBytes + 1).utf8).write(to: log)

        _ = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: Date())

        let live = contents(of: log)
        #expect(live.contains("log rotation:"))
        #expect(live.contains("backup.log.1"))
        // The note is STAMPED like every other line here, and comes before this launch's own line, so
        // the file reads in the order the events happened.
        let lines = live.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("log rotation:") == true)
        #expect(lines.last?.contains("success") == true)
        #expect(lines.first?.prefix(8) == lines.last?.prefix(8))
    }

    // The prep run log, beside the archived runs, one line per archived run.
    @Test func thePrepRunLogRecordsItsOwnRotation() throws {
        let handoff = try sandboxes.make(named: "overture-preprun-rotation-test")
        try Data(contentsOf: RepoRoot.url.appendingPathComponent("fixtures/prep-queue/v11.json"))
            .write(to: handoff.appendingPathComponent(PrepRunArchive.queueFilename(for: .prep)))
        try Data(contentsOf: RepoRoot.url
            .appendingPathComponent("fixtures/prep-results/run-metadata-complete-v8.json"))
            .write(to: handoff.appendingPathComponent(PrepRunArchive.resultsFilename(for: .prep)))
        let archives = PrepRunArchive.archivesDirectory(slot: .prep, handoffDirectory: handoff)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let log = archives.appendingPathComponent(PrepRunArchive.logFilename)
        try Data(String(repeating: "x", count: PrepRunArchive.maxLogBytes + 1).utf8).write(to: log)

        _ = PrepRunArchive.archiveFinishedRun(slot: .prep, handoffDirectory: handoff,
                                              now: Date(timeIntervalSince1970: 1_800_000_000),
                                              reportProblem: { _ in })

        let live = contents(of: log)
        #expect(live.contains("log rotation:"))
        #expect(live.contains("\(PrepRunArchive.logFilename).1"))
        #expect(live.split(separator: "\n").first?.contains("log rotation:") == true)
    }

    // The feed movement log, which #913 reads as a WINDOW of recent movement. A rotation cuts that
    // window, and a cut sample that says nothing about being cut reads as an ordinary one (L350).
    @Test func theFeedMovementLogRecordsItsOwnRotation() throws {
        let directory = try sandboxes.make(named: "overture-feedmovement-rotation-test")
        let log = directory.appendingPathComponent("feed-movement.log")
        try Data(String(repeating: "x", count: AgentLogLocation.defaultMaxLogBytes + 1).utf8).write(to: log)

        FeedMovementLog.record(sourceId: "src-1", org: "A Venue", current: 10, previous: 9,
                              baseline: 8, now: Date(timeIntervalSince1970: 1_800_000_000), to: log)

        let live = contents(of: log)
        #expect(live.contains("log rotation:"))
        #expect(live.contains("feed-movement.log.1"))
        #expect(live.contains("source=src-1"))
        #expect(live.split(separator: "\n").first?.contains("log rotation:") == true)
    }

    // MARK: - The agent's four logs, which report only what was LOST

    // These four roll by design: 5 MB of the agent's stdout, stderr, problem ledger and Gmail connect
    // trace, read when something has just gone wrong rather than as a history. A first roll costs
    // nothing, and raising a problem on it would put a routine line into the one ledger where ANY new
    // byte raises the menu bar nudge, which is the false positive #1689 exists to end (L36).
    @Test func aFirstRollOfTheAgentLogsRaisesNothing() throws {
        let directory = try sandboxes.make(named: "overture-agentlog-rotation-test")
        let log = try file(directory, named: "overture-agent.out.log", bytes: 4_096)
        var raised: [String] = []

        AgentLogLocation.capLogsReportingWhatWasLost(maxBytes: 1_024, files: [log],
                                                     report: { raised.append($0) })

        #expect(raised.isEmpty)
        #expect((try? Data(contentsOf: log.appendingPathExtension("1")))?.count == 4_096)
    }

    @Test func aRollThatDestroysAGenerationOfTheAgentLogsIsRaised() throws {
        let directory = try sandboxes.make(named: "overture-agentlog-rotation-test")
        let log = try file(directory, named: "overture-agent.out.log", bytes: 2_048)
        AgentLogLocation.capLogsReportingWhatWasLost(maxBytes: 1_024, files: [log], report: { _ in })
        try file(directory, named: "overture-agent.out.log", bytes: 4_096)
        var raised: [String] = []

        AgentLogLocation.capLogsReportingWhatWasLost(maxBytes: 1_024, files: [log],
                                                     report: { raised.append($0) })

        #expect(raised.count == 1)
        #expect(raised.first?.contains("That older content is gone") == true)
        #expect(raised.first?.contains("overture-agent.out.log.1") == true)
    }

    // A refusal is raised too, and it is not a deletion: the log is over its cap and growing, which is
    // the state somebody has to do something about.
    @Test func aRefusedRollOfTheAgentLogsIsRaised() throws {
        let directory = try sandboxes.make(named: "overture-agentlog-rotation-test")
        let log = try file(directory, named: "overture-agent.out.log", bytes: 4_096)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        var raised: [String] = []

        AgentLogLocation.capLogsReportingWhatWasLost(maxBytes: 1_024, files: [log],
                                                     report: { raised.append($0) })

        #expect(raised.count == 1)
        #expect(raised.first?.contains("could not be") == true)
    }

    // MARK: - Nothing may drop the report again

    // The `@discardableResult` is gone, so the compiler already refuses a bare `LogRotation.cap(...)`.
    // What it cannot refuse is `_ = LogRotation.cap(...)`, which is the same defect one character longer
    // and is exactly what somebody adding the ninth log will reach for. A rule that lives only in the
    // helper's comment reaches nobody (L27, L621).
    @Test func noCallSiteThrowsTheRotationReportAway() {
        var dropped: [String] = []
        for source in AppSourceWalk.appFiles() {
            for (line, code) in SwiftSource.scannableLines(in: source.text, skipping: []) {
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("LogRotation.cap(") else { continue }
                if trimmed.hasPrefix("LogRotation.cap(") || trimmed.hasPrefix("_ = LogRotation.cap(") {
                    dropped.append("\(source.name):\(line)")
                }
            }
        }
        #expect(dropped.isEmpty, """
            \(dropped.joined(separator: ", ")) calls LogRotation.cap and throws the answer away. Every \
            log this app keeps has to be able to say that a rotation cost it something, which is what \
            #3789 was filed about: read the report and write its notes into the log, the way the five \
            call sites already there do. A single-expression body handing the report straight on reads \
            as a bare statement here and cannot be told apart from one, so spell the `return` out.
            """)
    }

    // The `.1` file's reader is a shell script, so the words the app writes and the words that script
    // looks for are a cross-language contract with nothing but this holding them together. A reworded
    // note would otherwise leave the reader matching nothing and reporting a clean log, which is the
    // exact silence #3789 is about (L58, L26).
    @Test func theReaderLooksForTheWordsTheAppActuallyWrites() throws {
        let reader = try String(contentsOf: RepoRoot.url.appendingPathComponent("scripts/what-the-log-lost.sh"),
                               encoding: .utf8)
        let rotation = LogRotation.Rotation(file: URL(fileURLWithPath: "/tmp/some.log"),
                                            backup: URL(fileURLWithPath: "/tmp/some.log.1"),
                                            movedBytes: 4_096, discardedBytes: 2_048)
        let kept = LogRotation.Rotation(file: URL(fileURLWithPath: "/tmp/some.log"),
                                        backup: URL(fileURLWithPath: "/tmp/some.log.1"),
                                        movedBytes: 4_096, discardedBytes: nil)
        let refusal = LogRotation.Refusal(file: URL(fileURLWithPath: "/tmp/some.log"),
                                          reason: .backupCouldNotBeWritten)

        // Every phrase the script greps for has to be a phrase the app produces.
        for needle in ["log rotation:", "That older content is gone", "could not be"] {
            #expect(reader.contains("'\(needle)"), "the reader no longer looks for \(needle)")
        }
        #expect(LogRotation.note(for: rotation).contains("log rotation:"))
        #expect(LogRotation.note(for: rotation).contains("That older content is gone"))
        #expect(LogRotation.note(for: kept).contains("log rotation:"))
        #expect(!LogRotation.note(for: kept).contains("That older content is gone"))
        #expect(LogRotation.note(for: refusal).contains("could not be"))
    }
}

// The card divergence log's own suite, because it writes to a static the whole process shares and that
// trait serialises every suite that touches it.
@Suite("The card divergence log says what it lost (#3789)", .sharesTheRenderCounter)
final class TheCardDivergenceLogSaysWhatItLostTests {
    let sandboxes = TemporarySandboxes()

    // TWO surfaces, deliberately. The note goes into the file, so whoever opens it later can see the
    // record begins mid-session. The masthead marker appears only when something was LOST, because this
    // log rolls by design over a long session and a marker on every roll is the noise that teaches
    // somebody to stop reading the masthead.
    @Test func aRotationThatLostNothingIsInTheFileAndNotOnTheMasthead() throws {
        let log = try sandboxes.make(named: "overture-carddivergence-rotation-test")
            .appendingPathComponent("card-divergence.log")
        try Data(String(repeating: "x", count: 2_048).utf8).write(to: log)
        QueueRenderCounter.reset()

        QueueRenderCounter.append(line: "queue #1 nothing this view reads", to: log, maxBytes: 1_024)

        let live = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(live.contains("log rotation:"))
        #expect(live.contains("Nothing older was being kept"))
        #expect(!QueueRenderCounter.lastReason.contains("log rotated"))
        QueueRenderCounter.reset()
    }

    @Test func aRotationThatLostSomethingAlsoReachesTheMasthead() throws {
        let log = try sandboxes.make(named: "overture-carddivergence-rotation-test")
            .appendingPathComponent("card-divergence.log")
        try Data(String(repeating: "x", count: 2_048).utf8).write(to: log)
        QueueRenderCounter.append(line: "queue #1", to: log, maxBytes: 1_024)
        try Data(String(repeating: "x", count: 2_048).utf8).write(to: log)
        QueueRenderCounter.reset()

        QueueRenderCounter.append(line: "queue #2", to: log, maxBytes: 1_024)

        #expect(QueueRenderCounter.lastReason.contains("log rotated, older content gone"))
        QueueRenderCounter.reset()
    }
}
