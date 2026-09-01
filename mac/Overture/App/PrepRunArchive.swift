import Foundation

// #1878: keep each paid run's work-list and results instead of overwriting them.
//
// The handoff folder holds exactly one run at a time. `overture-prep-queue.json` and
// `overture-prep-results.json` are rewritten by the next run, so a finished run's evidence survives only
// until another one starts. Measured across the whole of Application Support on 2026-08-09: exactly two
// `runCost` records existed on this machine and only one was usable, which is why "did the run actually do
// what the runbook told it to" could not be answered about any run, and why #1616's learner shipped with
// almost nothing to learn from. Each of these runs costs real money.
//
// So the PAIR is copied into a dated folder beside the live files, keeping the last `keep`, the same shape
// the store backup has used since #601 and through that rotation's own code (DatedFolderRotation), not a
// second implementation of it.
//
// LIVE-STORE-CLAIM verified=2026-09-01 measure="the size of every archived run folder in both slots, and the count and total size of the surviving chunk event streams"
// #3357 Phase 1.2 corrects the sizes this comment used to state, which had gone stale by 2 to 3 times in
// the very file that argues retention from them (L32, L210). Measured 2026-09-01: the archived PAIR runs
// 20 to 84 KB across 17 prep folders (median about 28 KB) and 24 to 224 KB across 7 check folders
// (median about 40 KB), NOT the "about 14 KB" this said. The chunk EVENT streams are 1.7 MB per run over
// 7 files, mean 252 KB.
//
// The streams are no longer excluded: they are archived by `archiveEventStreams` into their OWN dated
// directory with their OWN keep, because they are the only per item evidence a run leaves and the next
// run overwrites them at a fixed path. Measured 2026-08-30, that is not hypothetical: one run's ten
// streams were gone 45 minutes later while its archived `webCalls` still reported `streams: 10` (L202).
//
// Three properties are load-bearing:
//
//   The folder is named for the RUN, from the queue's own `generatedAt`, not for the moment the archive
//   happened. The app archives a finished run at launch AND when it settles one it watched, and a settle
//   can be retried, so naming it after the run is what makes archiving it twice a no-op instead of two
//   copies (one of them possibly landing over the other mid-write).
//
//   Files are copied into a working folder that is RENAMED into place once they are all in it. A rename
//   within a directory is atomic, so a crash or a kill part-way through can leave a discardable working
//   folder but never something that reads as a finished archive (L5).
//
//   A run that went wrong is archived too. A check that died leaves a work-list and no results at all, and
//   that is precisely the run somebody will want to read later (L47), so what is present is kept and the
//   log names what was missing rather than the whole thing being skipped as not worth having.
//
// #2760: PER SLOT. One `prep-run-archives` with one `keep` had two separate defects in it. A busy night of
// checks evicts the prep archives #1616's learner reads, because they share a rotation. And the folder is
// named for the RUN, so two runs whose `generatedAt` lands in the same second collide on the name, at which
// point the second reads as `alreadyArchived` (a true answer for a retry, a lie for a different run) and
// its evidence is silently dropped. Two folders make both impossible rather than unlikely.
enum PrepRunArchive {
    static func folderName(for slot: RunSlot) -> String { slot.archiveFolderName }

    // The names the files keep INSIDE the archive, which are the slot's own: a check's archive holding a
    // file called `overture-prep-queue.json` would be unreadable evidence, and nothing later could tell
    // which run it came from.
    static func queueFilename(for slot: RunSlot) -> String { slot.queueFileName }
    static func resultsFilename(for slot: RunSlot) -> String { slot.resultsFileName }

    static let logFilename = "archive.log"

    // Thirty runs at the measured median of 28 to 40 KB is roughly 1 MB, and at the one or two paid runs
    // a night Dan actually does it is about a month of history: enough for #1616's learner to hold real
    // samples, and enough that a question about last week's run is still answerable. Deliberately larger
    // than the store backup's ten, because each of those is a copy of the entire SwiftData store.
    //
    // #3357 Phase 1.2: this used to say "about 14 KB is under half a megabyte", which was wrong by 2 to
    // 3 times and was the number any future retention decision would have been argued from. Re-measure
    // rather than repeating this sentence.
    //
    // #2760: the number is the SLOT's, so one rotation can be retuned without silently changing how much of
    // the other's history survives.
    static func keep(for slot: RunSlot) -> Int { slot.archiveKeep }

    // The working folder's marker. Outside the plain `yyyyMMdd-HHmmss` shape on purpose, so rotation
    // neither counts nor deletes one, exactly as #1410 keeps a refusal snapshot out of the rotation.
    static let incomingSuffix = ".incoming-"

    // How long a working folder can sit before it is treated as a crash leftover. Generously longer than
    // a copy of two small files could ever take, so a folder an in-flight archive is filling is never
    // swept out from under it.
    static let staleIncomingAfter: TimeInterval = 60 * 60

    static let maxLogBytes = 256 * 1_024

    static func archivesDirectory(slot: RunSlot, handoffDirectory: URL) -> URL {
        slot.archivesDirectory(in: handoffDirectory)
    }

    // A finished archive, as opposed to a working folder or anything else that lands in here.
    static func isArchivedRunFolder(_ name: String) -> Bool {
        DatedFolderRotation.isRotatableFolder(name)
    }

    enum Outcome: Equatable {
        // Neither file is on disk, so no run has written anything here yet. Not a failure, and it says
        // nothing to the log: a fresh install must not report a problem on every launch.
        case noRunOnDisk
        case archived(folder: URL, copied: [String], missing: [String])
        case alreadyArchived(folder: URL)
        case failed(reason: String)
    }

    // The log's own words, as constants so a test names the same sentence the code writes.
    // copy-inventory:ignore-start  archive.log is a diagnostic record, not the app's voice on screen
    static let successLogNote = "success: archived this run's work-list and results."
    static func incompleteLogNote(missing: [String]) -> String {
        "incomplete: this run left no \(missing.joined(separator: " and no ")), so the archive holds only "
        + "what it did write."
    }
    static func failedLogNote(_ reason: String) -> String {
        "failed: nothing was archived (\(reason)), so this run's work-list and results are lost as soon as "
        + "the next run starts."
    }
    static func failedProblemNote(_ reason: String) -> String {
        "could not archive the last paid run's work-list and results (\(reason)); the next run will "
        + "overwrite them"
    }
    // copy-inventory:ignore-end

    // Copies the live pair into a dated folder and prunes old ones. Never throws: this is insurance on the
    // run's own output, and the output matters more than the copy of it, so a failure here is reported and
    // then got out of the way of whatever the caller was really doing.
    @discardableResult
    static func archiveFinishedRun(slot: RunSlot, handoffDirectory: URL, now: Date,
                                   keep: Int? = nil,
                                   fileManager: FileManager = .default,
                                   reportProblem: (String) -> Void = { AgentLog.problem($0) }) -> Outcome {
        let keep = keep ?? Self.keep(for: slot)
        let queueURL = slot.queueURL(in: handoffDirectory)
        let resultsURL = slot.resultsURL(in: handoffDirectory)
        let sources = [(queueFilename(for: slot), queueURL), (resultsFilename(for: slot), resultsURL)]
        let present = sources.filter { fileManager.fileExists(atPath: $0.1.path) }
        guard !present.isEmpty else { return .noRunOnDisk }
        let missing = sources.map(\.0).filter { name in !present.contains { $0.0 == name } }

        let archives = archivesDirectory(slot: slot, handoffDirectory: handoffDirectory)
        let stamp = runStamp(queueURL: queueURL, resultsURL: resultsURL, now: now, fileManager: fileManager)
        let destination = archives.appendingPathComponent(stamp, isDirectory: true)

        // Already there: this run has been archived, by an earlier settle, an earlier launch, or a retry
        // of either. Returning the folder rather than re-copying is what stops a second pass writing over
        // a good archive, which is the one way this could destroy the thing it exists to preserve.
        if fileManager.fileExists(atPath: destination.path) {
            sweepStaleWorkingFolders(in: archives, now: now, fileManager: fileManager)
            DatedFolderRotation.prune(in: archives, keep: keep, fileManager: fileManager)
            // On the retry path too, so a run whose pair was archived by an earlier settle still gets its
            // streams. They are written by the run itself and can land AFTER the pair, so the first call
            // may legitimately have found none.
            archiveEventStreams(slot: slot, handoffDirectory: handoffDirectory, stamp: stamp,
                                now: now, fileManager: fileManager)
            return .alreadyArchived(folder: destination)
        }

        // Unique per attempt, so two archives running at once cannot fill each other's working folder.
        let incoming = archives.appendingPathComponent(
            stamp + incomingSuffix + UUID().uuidString, isDirectory: true)
        var copied: [String] = []
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            for (name, source) in present {
                try fileManager.copyItem(at: source, to: incoming.appendingPathComponent(name))
                copied.append(name)
            }
            // The whole archive appears at once, or not at all.
            try fileManager.moveItem(at: incoming, to: destination)
        } catch {
            try? fileManager.removeItem(at: incoming)
            // A racer that finished between the existence check above and this rename is not a failure:
            // the run IS archived, which is all this call was asking for.
            if fileManager.fileExists(atPath: destination.path) {
                return .alreadyArchived(folder: destination)
            }
            let reason = error.localizedDescription
            // Both, and in this order. The log lives inside the folder that may be the very thing that
            // could not be written, so the problem ledger is the only place this is guaranteed to be
            // said, and a broken archive that says nothing looks exactly like a working one (L11).
            appendLog(stamp: stamp, note: failedLogNote(reason), archives: archives, fileManager: fileManager)
            reportProblem(failedProblemNote(reason))
            return .failed(reason: reason)
        }

        appendLog(stamp: stamp,
                  note: missing.isEmpty ? successLogNote : incompleteLogNote(missing: missing),
                  archives: archives, fileManager: fileManager)
        sweepStaleWorkingFolders(in: archives, now: now, fileManager: fileManager)
        DatedFolderRotation.prune(in: archives, keep: keep, fileManager: fileManager)
        archiveEventStreams(slot: slot, handoffDirectory: handoffDirectory, stamp: stamp,
                            now: now, fileManager: fileManager)
        return .archived(folder: destination, copied: copied, missing: missing)
    }

    // #3357 Phase 1.2 / #3346: the RAW event streams, into their OWN dated directory under the SAME
    // stamp, so one run's queue, results and streams are found under one folder name in two places.
    //
    // Its own directory and its own keep, because `DatedFolderRotation.prune` rotates whole FOLDERS by
    // one keep: sharing one would give the pair or the streams a lifetime nobody chose (L285). See
    // `RunSlot.eventArchiveKeep`.
    //
    // Best effort by design. The streams are evidence ABOUT a run, not the run's own output, so a
    // failure to copy them must never turn a successfully archived run into a failed one. It is silent
    // on finding none, because a run legitimately has none once its chunks have been cleaned up, and a
    // problem reported on the ordinary case is one nobody reads (L36).
    static func archiveEventStreams(slot: RunSlot, handoffDirectory: URL, stamp: String, now: Date,
                                    fileManager: FileManager = .default) {
        let streams = presentEventStreams(slot: slot, handoffDirectory: handoffDirectory,
                                          fileManager: fileManager)
        // No empty folder for a run that produced nothing: an empty archive and a run whose streams were
        // lost read identically to anybody looking later (L98, L11).
        guard !streams.isEmpty else { return }

        let archives = slot.eventArchivesDirectory(in: handoffDirectory)
        let destination = archives.appendingPathComponent(stamp, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let incoming = archives.appendingPathComponent(
            stamp + incomingSuffix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            for source in streams {
                try fileManager.copyItem(
                    at: source, to: incoming.appendingPathComponent(source.lastPathComponent))
            }
            // The same atomic rename the pair uses: a kill part way through leaves a discardable working
            // folder, never something that reads as a finished archive (L5).
            try fileManager.moveItem(at: incoming, to: destination)
        } catch {
            try? fileManager.removeItem(at: incoming)
            return
        }
        sweepStaleWorkingFolders(in: archives, now: now, fileManager: fileManager)
        DatedFolderRotation.prune(in: archives, keep: slot.eventArchiveKeep, fileManager: fileManager)
    }

    // The chunk streams this run actually left on disk. Found by READING the directory rather than by
    // counting up from chunk 1, because a run that died leaves whichever chunks it got to and a loop that
    // stops at the first gap would silently archive a prefix of the evidence.
    static func presentEventStreams(slot: RunSlot, handoffDirectory: URL,
                                    fileManager: FileManager = .default) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: handoffDirectory.path)) ?? []
        let prefix = "\(slot.rawValue)-run-events.chunk-"
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { handoffDirectory.appendingPathComponent($0) }
    }

    // Which run this is, in the rotation's own folder shape. Read from the run's own `generatedAt` (the
    // app stamps the queue with it at launch and the run copies it onto the results), so archiving the
    // same run twice lands on the same folder name.
    //
    // The fallbacks walk from most to least specific and end at the clock. A file whose date cannot be
    // read still gets archived under SOME name: an archive that refused a run because it could not name
    // it would throw away exactly the damaged run this exists to keep.
    static func runStamp(queueURL: URL, resultsURL: URL, now: Date,
                         fileManager: FileManager = .default) -> String {
        // UTC, so the folder name and the `generatedAt` sitting inside it are the same moment written the
        // same way. Rendered in the local zone they differ by the reader's offset, which reads as two
        // different runs, and the name would change with the Mac's zone rather than with the run.
        if let generated = generatedAt(of: queueURL) ?? generatedAt(of: resultsURL) {
            return DatedFolderRotation.stamp(generated, in: .gmt)
        }
        if let modified = modificationDate(of: resultsURL, fileManager: fileManager)
                            ?? modificationDate(of: queueURL, fileManager: fileManager) {
            return DatedFolderRotation.stamp(modified, in: .gmt)
        }
        return DatedFolderRotation.stamp(now, in: .gmt)
    }

    // Only `generatedAt`, decoded on its own rather than through PrepQueue/PrepResults. Both files are
    // versioned contracts that gain fields, and a full decode that failed on an unknown shape would stop
    // the archive naming a run it can perfectly well copy.
    private struct RunHeader: Decodable { let generatedAt: String? }

    private static func generatedAt(of url: URL) -> Date? {
        // #2879: exempt from the register on purpose. This decodes a deliberately PARTIAL view of two
        // versioned contracts to name an archive folder, and a shape it cannot read is a naming
        // inconvenience, not lost work: the archive is copied either way. Recording it would put a
        // warning on the masthead about a file the app has already safely kept.
        guard let header = HandoffFile.read(at: url, recorder: .reportedByItsOwnSurface,
                                            decode: { try JSONDecoder().decode(RunHeader.self, from: $0) }).value,
              let text = header.generatedAt else { return nil }
        // The app writes it with a plain ISO8601 formatter; the committed fixtures (and anything written
        // by a JavaScript `toISOString`) carry milliseconds, which the plain parser refuses outright.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // A working folder left by a crash or a kill part-way through a copy. Rotation ignores these by
    // design (they are outside the dated shape), so without this they would accumulate for ever, which is
    // the same "written deliberately, cleaned up by nobody" gap HandoffCleanup exists to close.
    private static func sweepStaleWorkingFolders(in archives: URL, now: Date, fileManager: FileManager) {
        let entries = (try? fileManager.contentsOfDirectory(atPath: archives.path)) ?? []
        for name in entries where name.contains(incomingSuffix) {
            let url = archives.appendingPathComponent(name)
            guard let modified = modificationDate(of: url, fileManager: fileManager),
                  now.timeIntervalSince(modified) > staleIncomingAfter else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // One line per archived run, beside the archives themselves, exactly as backup.log sits beside the
    // store backups. Capped through the same copytruncate helper (#608) so it can never grow unbounded.
    private static func appendLog(stamp: String, note: String, archives: URL, fileManager: FileManager) {
        let logURL = archives.appendingPathComponent(logFilename)
        LogRotation.cap(files: [logURL], maxBytes: maxLogBytes, fileManager: fileManager)
        guard let data = (stamp + " " + note + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
