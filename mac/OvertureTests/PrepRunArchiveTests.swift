import Testing
import Foundation

// #1878: a paid run's evidence has to survive the next run.
//
// The handoff folder holds exactly one run at a time: `overture-prep-queue.json` and
// `overture-prep-results.json` are both overwritten the moment another run starts, so a finished run's
// work-list and results live only until the next one begins. Measured across the whole of Application
// Support on 2026-08-09: exactly two `runCost` records existed on this machine and only one of them was
// usable, which is why every question of the form "did the run do what the runbook told it to" was
// unanswerable, and why #1616's learner had nothing to learn from. Each of these runs costs real money.
//
// So each finished run's PAIR is copied into a dated folder beside the live files, the same shape the
// store backup rotation has used since #601. The pair is about 14 KB; the event stream and the run log
// are 300 KB+ each and are a separate retention decision, deliberately not archived here.
//
// Every test here works in its own throwaway directory. Nothing may reach the live handoff folder, which
// holds Dan's booking history, his Gmail tokens and the live store itself (L2, #2097).
@Suite("Each paid run's work-list and results are archived (#1878)")
struct PrepRunArchiveTests {

    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-preprunarchive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The REAL contract files, not an invented shape (L48/L52). The folder is named from the run's own
    // `generatedAt`, so a hand-made stand-in would prove the naming works against a shape that never
    // reaches disk. `fixtures/prep-queue/v11.json` is the current queue version and
    // `fixtures/prep-results/run-metadata-complete-v8.json` is a results file carrying the runner's own
    // `runCost`, which is the very record this issue exists to stop losing.
    private func fixture(_ relativePath: String) throws -> Data {
        try Data(contentsOf: RepoRoot.url.appendingPathComponent(relativePath))
    }

    @discardableResult
    private func writeLiveQueue(in handoff: URL) throws -> Data {
        let data = try fixture("fixtures/prep-queue/v11.json")
        try data.write(to: handoff.appendingPathComponent(PrepRunArchive.queueFilename))
        return data
    }

    @discardableResult
    private func writeLiveResults(in handoff: URL) throws -> Data {
        let data = try fixture("fixtures/prep-results/run-metadata-complete-v8.json")
        try data.write(to: handoff.appendingPathComponent(PrepRunArchive.resultsFilename))
        return data
    }

    private func queueURL(_ handoff: URL) -> URL {
        handoff.appendingPathComponent(PrepRunArchive.queueFilename)
    }

    private func resultsURL(_ handoff: URL) -> URL {
        handoff.appendingPathComponent(PrepRunArchive.resultsFilename)
    }

    @discardableResult
    private func archive(in handoff: URL, now: Date = Date(timeIntervalSince1970: 1_800_000_000),
                         keep: Int = PrepRunArchive.keep,
                         problems: ((String) -> Void)? = nil) -> PrepRunArchive.Outcome {
        PrepRunArchive.archiveFinishedRun(queueURL: queueURL(handoff), resultsURL: resultsURL(handoff),
                                          now: now, keep: keep,
                                          reportProblem: problems ?? { _ in })
    }

    private func folders(in archives: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: archives.path)) ?? [])
            .filter { !$0.hasSuffix(".log") }
            .sorted()
    }

    private func log(in archives: URL) -> String {
        (try? String(contentsOf: archives.appendingPathComponent(PrepRunArchive.logFilename),
                     encoding: .utf8)) ?? ""
    }

    // MARK: - Where the archive lives

    @Test func theArchiveSitsBesideTheLiveFilesInItsOwnFolder() {
        let handoff = URL(fileURLWithPath: "/tmp/some-handoff-dir")

        #expect(PrepRunArchive.archivesDirectory(handoffDirectory: handoff)
                == handoff.appendingPathComponent("prep-run-archives", isDirectory: true))
    }

    // MARK: - A finished run is kept

    @Test func aFinishedRunsWorkListAndResultsAreCopiedIntoADatedFolder() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        let queue = try writeLiveQueue(in: handoff)
        let results = try writeLiveResults(in: handoff)

        let outcome = archive(in: handoff)

        guard case .archived(let folder, let copied, let missing) = outcome else {
            Issue.record("expected the run to be archived, got \(outcome)")
            return
        }
        #expect(missing.isEmpty)
        #expect(copied.sorted() == [PrepRunArchive.queueFilename, PrepRunArchive.resultsFilename].sorted())
        // Byte-identical copies under their live names, so anything that reads a live handoff file can be
        // pointed straight at an archived run with nothing to translate.
        #expect(try Data(contentsOf: folder.appendingPathComponent(PrepRunArchive.queueFilename)) == queue)
        #expect(try Data(contentsOf: folder.appendingPathComponent(PrepRunArchive.resultsFilename)) == results)
        // A COPY. The live pair is what the app is still reading, and archiving must never move it.
        #expect(FileManager.default.fileExists(atPath: queueURL(handoff).path))
        #expect(FileManager.default.fileExists(atPath: resultsURL(handoff).path))
        #expect(log(in: PrepRunArchive.archivesDirectory(handoffDirectory: handoff)).contains("success"))
    }

    // The folder is named for the RUN, read from the queue's own `generatedAt`, not for the moment the
    // archive happened. That is what makes archiving idempotent below, and it means the folder listing
    // reads as a history of runs rather than a history of settles.
    @Test func theFolderIsNamedForTheRunItHoldsNotForTheMomentItWasArchived() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        try writeLiveQueue(in: handoff)
        try writeLiveResults(in: handoff)

        // fixtures/prep-queue/v11.json carries "generatedAt": "2026-06-25T00:00:00.000Z".
        let outcome = archive(in: handoff, now: Date(timeIntervalSince1970: 1_800_000_000))

        guard case .archived(let folder, _, _) = outcome else {
            Issue.record("expected the run to be archived, got \(outcome)")
            return
        }
        // Exactly that instant, in UTC, which is the zone the run wrote it in. Rendered in the Mac's own
        // zone this is 20260624-200000 on Dan's machine and something else again on any other, so the
        // folder would stop naming the same moment as the `generatedAt` inside it, and the same run
        // archived from two machines would read as two runs.
        #expect(folder.lastPathComponent == "20260625-000000")
    }

    // Assume it runs twice. The app archives at launch (for a run that finished while it was closed) and
    // again when it settles a run it watched, and a settle can itself be retried. Two archives of one run
    // would rotate a real one off the end for no reason, and a second copy landing mid-write over the
    // first is how a good archive gets destroyed.
    @Test func archivingTheSameRunTwiceKeepsExactlyOneCopyOfIt() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        try writeLiveQueue(in: handoff)
        let results = try writeLiveResults(in: handoff)

        let first = archive(in: handoff, now: Date(timeIntervalSince1970: 1_800_000_000))
        let second = archive(in: handoff, now: Date(timeIntervalSince1970: 1_800_009_999))

        guard case .archived(let folder, _, _) = first else {
            Issue.record("expected the first call to archive, got \(first)")
            return
        }
        #expect(second == .alreadyArchived(folder: folder))
        let archives = PrepRunArchive.archivesDirectory(handoffDirectory: handoff)
        #expect(folders(in: archives) == [folder.lastPathComponent])
        // And the copy that was already there is untouched, rather than half-rewritten by the second pass.
        #expect(try Data(contentsOf: folder.appendingPathComponent(PrepRunArchive.resultsFilename)) == results)
    }

    @Test func nothingIsArchivedWhenNoRunHasEverWrittenAnything() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }

        #expect(archive(in: handoff) == .noRunOnDisk)
        // No run means no failure either: an empty folder must not start reporting a problem every launch.
        #expect(!FileManager.default.fileExists(
            atPath: PrepRunArchive.archivesDirectory(handoffDirectory: handoff).path))
    }

    // MARK: - Rotation

    @Test func onlyTheMostRecentRunsAreKept() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        let archives = PrepRunArchive.archivesDirectory(handoffDirectory: handoff)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        for stamp in ["20260101-010101", "20260102-010101", "20260103-010101"] {
            try FileManager.default.createDirectory(at: archives.appendingPathComponent(stamp),
                                                    withIntermediateDirectories: true)
        }
        try writeLiveQueue(in: handoff)
        try writeLiveResults(in: handoff)

        archive(in: handoff, keep: 2)

        // The run just archived (20260625-...) plus the newest of the three already there.
        #expect(folders(in: archives) == ["20260103-010101", "20260625-000000"])
    }

    // The hard-won detail from the store backup rotation (#1410): a folder outside the plain
    // yyyyMMdd-HHmmss shape is neither counted toward the keep nor deleted, so a burst of odd cases can
    // never age out the real archive.
    @Test func aFolderOutsideTheDatedShapeIsNeitherCountedNorDeleted() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        let archives = PrepRunArchive.archivesDirectory(handoffDirectory: handoff)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let odd = archives.appendingPathComponent("20260101-010101.kept-by-hand")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        for stamp in ["20260102-010101", "20260103-010101"] {
            try FileManager.default.createDirectory(at: archives.appendingPathComponent(stamp),
                                                    withIntermediateDirectories: true)
        }
        try writeLiveQueue(in: handoff)
        try writeLiveResults(in: handoff)

        archive(in: handoff, keep: 2)

        #expect(folders(in: archives).contains("20260101-010101.kept-by-hand"))
        #expect(folders(in: archives).contains("20260625-000000"))
        // It did not count toward the keep either: two dated folders survive beside it, not one.
        #expect(folders(in: archives).contains("20260103-010101"))
    }

    // MARK: - Failure paths

    // A run that went wrong is exactly the one somebody will want to read later (L47). A check that died
    // partway leaves a work-list and no results at all, and the archive has to record that rather than
    // deciding there is nothing worth keeping.
    @Test func aRunThatWroteNoResultsIsStillArchivedAndTheLogNamesWhatIsMissing() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        let queue = try writeLiveQueue(in: handoff)

        let outcome = archive(in: handoff)

        guard case .archived(let folder, let copied, let missing) = outcome else {
            Issue.record("expected the incomplete run to be archived anyway, got \(outcome)")
            return
        }
        #expect(copied == [PrepRunArchive.queueFilename])
        #expect(missing == [PrepRunArchive.resultsFilename])
        #expect(try Data(contentsOf: folder.appendingPathComponent(PrepRunArchive.queueFilename)) == queue)
        // Said out loud, and it says WHICH half is missing: an archive holding one file is otherwise
        // indistinguishable from one whose copy half failed.
        let logged = log(in: PrepRunArchive.archivesDirectory(handoffDirectory: handoff))
        #expect(logged.contains("incomplete"))
        #expect(logged.contains(PrepRunArchive.resultsFilename))
    }

    // Fail loud, not silent, and never at the cost of the run itself: the results ARE the product, the
    // copy of them is insurance. So a destination that cannot be written is reported and the live files
    // are left exactly as they were.
    @Test func anArchiveThatCannotBeWrittenIsReportedAndCostsTheRunNothing() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        let queue = try writeLiveQueue(in: handoff)
        let results = try writeLiveResults(in: handoff)
        // A plain file sitting where the archives directory belongs: every write below it fails.
        try Data("not a directory".utf8)
            .write(to: PrepRunArchive.archivesDirectory(handoffDirectory: handoff))

        var problems: [String] = []
        let outcome = archive(in: handoff, problems: { problems.append($0) })

        guard case .failed(let reason) = outcome else {
            Issue.record("expected the archive to report failure, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
        // The log itself is inside the folder that could not be made, so the problem ledger is the only
        // place this can be said. It must be said there, or a broken archive looks exactly like a working
        // one for as long as it lasts.
        #expect(problems.count == 1)
        #expect(problems[0].contains("archive"))
        // The run's own files are untouched: archiving is insurance and must never be able to cost the
        // thing it insures.
        #expect(try Data(contentsOf: queueURL(handoff)) == queue)
        #expect(try Data(contentsOf: resultsURL(handoff)) == results)
    }

    // Crash-safety. Copies land in a working folder that is renamed into place only once both files are
    // in it, so a crash or a kill mid-copy can never leave something that reads as a finished archive.
    @Test func aHalfWrittenArchiveIsNeverReadableAsAFinishedOne() throws {
        let handoff = try sandbox()
        defer { try? FileManager.default.removeItem(at: handoff) }
        let archives = PrepRunArchive.archivesDirectory(handoffDirectory: handoff)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        // What a crash between the first copy and the rename leaves behind.
        let halfWritten = archives.appendingPathComponent("20260624-000000\(PrepRunArchive.incomingSuffix)abc")
        try FileManager.default.createDirectory(at: halfWritten, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: halfWritten.appendingPathComponent(PrepRunArchive.queueFilename))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                              ofItemAtPath: halfWritten.path)
        try writeLiveQueue(in: handoff)
        try writeLiveResults(in: handoff)

        archive(in: handoff)

        // It is not one of the archived runs, and it does not sit there forever either.
        #expect(!PrepRunArchive.isArchivedRunFolder(halfWritten.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: halfWritten.path))
        #expect(folders(in: archives) == ["20260625-000000"])
    }

    // MARK: - The folder's shape is a contract

    // Named here because a later reader (a report, a backfill of #1616's learner, Dan in Finder) has to
    // be able to find these without reading this file. docs/contracts.md states the same names.
    @Test func theArchiveKeepsTheContractsOwnFilenames() {
        #expect(PrepRunArchive.folderName == "prep-run-archives")
        #expect(PrepRunArchive.queueFilename == "overture-prep-queue.json")
        #expect(PrepRunArchive.resultsFilename == "overture-prep-results.json")
    }

    // Thirty runs of about 14 KB is under half a megabyte, and at one or two paid runs a night it is
    // roughly a month of history: long enough for #1616's learner to have real samples and for a
    // question about last week's run to still be answerable. Deliberately larger than the store backup's
    // ten, because each of those is the whole SwiftData store.
    @Test func thirtyRunsAreKept() {
        #expect(PrepRunArchive.keep == 30)
    }

    // MARK: - Wiring
    //
    // A guard and its wiring are two claims (#887). Everything above proves the archive works; these
    // prove the app calls it, on both paths a finished run can reach the app through.

    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func settlingAFinishedRunArchivesItFirst() throws {
        guard let body = SourceGuardHelper.propertyBody("private func settleFinishedPrepRun() async {",
                                                        in: rootView) else {
            Issue.record("settleFinishedPrepRun not found in RootView")
            return
        }
        #expect(body.contains("archiveFinishedPrepRun()"))
        // Before the dead-run sweep, which RETURNS: a run that died is a run whose evidence matters most,
        // and archiving after that early return would skip exactly those.
        let archiveAt = body.range(of: "archiveFinishedPrepRun()")
        let sweepAt = body.range(of: "if sweptADeadPrepRun() { return }")
        #expect(archiveAt != nil && sweepAt != nil)
        if let archiveAt, let sweepAt { #expect(archiveAt.lowerBound < sweepAt.lowerBound) }
    }

    // The launch path, for a run that finished while Overture was closed. Without it that run's pair is
    // still on disk with nobody to archive it, and the next run overwrites both.
    @Test func launchArchivesARunThatEndedWhileOvertureWasClosed() {
        #expect(rootView.contains("if !PrepQueueService.isRunning(now: Date()) { archiveFinishedPrepRun() }"))
    }

    // And never over a LIVE run: its results file is mid-write, and archiving it under that run's own
    // name would claim the run's slot with a half-finished copy that the real settle then declines to
    // replace.
    @Test func theArchiveIsWiredToTheLiveHandoffPairAndNothingElse() throws {
        guard let body = SourceGuardHelper.propertyBody("private func archiveFinishedPrepRun() {",
                                                        in: rootView) else {
            Issue.record("archiveFinishedPrepRun not found in RootView")
            return
        }
        #expect(body.contains("PrepRunArchive.archiveFinishedRun"))
        #expect(body.contains("PrepQueueBuilder.defaultURL"))
        #expect(body.contains("PrepImporter.defaultURL"))
    }
}
