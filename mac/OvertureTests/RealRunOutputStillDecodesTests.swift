import Testing
import Foundation

// #2880: nothing in this repo ever read a file a REAL run wrote.
//
// Every contract test reads `fixtures/`, and a fixture is written by hand to satisfy the reader. #2873 is
// what that costs: the six reply-classify fixtures all carry `generatedAt`, the live runner does not write
// it, and the guard passed for the whole time the app could not decode a single real results file. A
// fixture shaped to satisfy the reader tests a shape the writer does not produce (L48, L52), and there was
// no check in the other direction.
//
// This is that other direction. It finds the newest REAL instance of each handoff file on this Mac and
// runs it through the app's own decoder. It cannot be a CI job, because those files exist only where
// Overture has actually run.
@Suite("A real run's output still decodes (#2880)")
struct RealRunOutputStillDecodesTests {
    // The files the APP reads, and the decoder it reads each one with. A file the app only WRITES has no
    // entry, because "does our decoder accept it" is not a question about it.
    private static let decoders: [String: @Sendable (Data) throws -> Void] = [
        "overture-prep-results.json": { _ = try PrepResultsDecoder.decode($0) },
        "overture-prep-progress.json": { _ = try PrepProgressDecoder.decode($0) },
        // #2760/#2805: the reachability check writes the same three shapes under the check slot's names.
        "overture-check-results.json": { _ = try PrepResultsDecoder.decode($0) },
        "overture-check-progress.json": { _ = try PrepProgressDecoder.decode($0) },
        "overture-reply-classify-results.json": { _ = try ReplyClassifyResultsDecoder.decode($0) },
        "overture-reply-classify-progress.json": { _ = try ReplyClassifyProgressDecoder.decode($0) },
        "overture-scout-extract-results.json": { _ = try ScoutExtractResultsDecoder.decode($0) },
        "overture-scout-extract-progress.json": { _ = try ScoutExtractProgressDecoder.decode($0) },
    ]

    // Files the app WRITES for a run to read, and never decodes back. Listed rather than left to fall
    // through the coverage check below, so a new handoff file is an accusation and one of these is not.
    private static let writtenByTheAppOnly: Set<String> = [
        "overture-prep-queue.json",
        "overture-check-queue.json",
        "overture-reply-classify-queue.json",
        "overture-scout-extract-queue.json",
        "overture-voice-feedback.json",
        "overture-recent-openers.json",
        "overture-reachability-probe-run.json",
        "overture-run-duration-history.json",
        "overture-probe-duration-history.json",
        "overture-history.json",
        "overture-shoot-history.json",
        "overture-voice-guidance.json",
    ]

    // RETIRED handoff files whose leftovers still sit in the live folder. Nothing reads or writes them
    // any more, and `docs/contracts.md` records each as retired with the issue that did it. Named here
    // rather than left to the accusation below, because their presence on disk is explained: a run from
    // before #493 wrote them and nothing has ever swept them up.
    private static let retired: Set<String> = [
        "overture-results.json",      // #493 retired the parallel TypeScript scout pipeline
        "overture-uncertain.json",    // the scout's old round trip with a Claude Code run
        "overture-refined.json",      // the other half of that round trip
    ]

    private var handoffDirectory: URL {
        StoreLocation.dataDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    // The newest real instance of each `overture-*.json`, from the live handoff folder and from every
    // archived run under it. Newest by file modification date, which is what "the most recent real
    // instance" means for files a run rewrites in place.
    // A scan that could not LIST the handoff folder is kept apart from one that listed it and found
    // nothing (L11). The two are the same empty map otherwise, and the second guard below would then
    // report "holds no file the app reads" about a folder it never managed to read.
    private struct Scan {
        var newest: [String: URL] = [:]
        var couldNotList: [String] = []
    }

    private func newestRealFiles() -> [String: URL] { scan().newest }

    private func scan() -> Scan {
        let fm = FileManager.default
        var result = Scan()
        var directories = [handoffDirectory]
        for archives in ["prep-run-archives", "check-run-archives"] {
            let root = handoffDirectory.appendingPathComponent(archives)
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                let runs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                directories.append(contentsOf: runs.filter { $0.hasDirectoryPath })
            } catch {
                result.couldNotList.append("\(root.path): \(error)")
            }
        }

        var newest: [String: URL] = [:]
        for directory in directories {
            guard fm.fileExists(atPath: directory.path) else { continue }
            let files: [URL]
            do {
                files = try fm.contentsOfDirectory(at: directory,
                                                   includingPropertiesForKeys: [.contentModificationDateKey])
            } catch {
                result.couldNotList.append("\(directory.path): \(error)")
                continue
            }
            for file in files where file.lastPathComponent.hasPrefix("overture-")
                && file.pathExtension == "json" {
                let name = file.lastPathComponent
                guard let current = newest[name] else { newest[name] = file; continue }
                if modified(file) > modified(current) { newest[name] = file }
            }
        }
        result.newest = newest
        return result
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    // THE check. Every real instance the app claims to read, read.
    @Test func theNewestRealInstanceOfEachContractDecodes() throws {
        let files = newestRealFiles()
        for (name, url) in files.sorted(by: { $0.key < $1.key }) {
            guard let decode = Self.decoders[name] else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                Issue.record(Comment(rawValue: "\(name) could not be read at \(url.path): \(error)"))
                continue
            }
            do {
                try decode(data)
            } catch {
                Issue.record(Comment(rawValue: "the app cannot decode a REAL \(name), written "
                                     + "\(modified(url)), at \(url.path). This is #2873's shape: the "
                                     + "fixtures pass and the live file does not. \(error)"))
            }
        }
    }

    // Finding nothing is its own outcome, never a pass (L98). The empty result arrives exactly when this
    // check would be most believed, and on a machine where Overture has run there IS material.
    //
    // A machine that has never run Overture has no handoff folder at all, and that is a real skip rather
    // than a finding: it is said out loud and asserted as the reason, so the two cannot be confused.
    @Test func findingNothingIsSaidOutLoudRatherThanPassingQuietly() {
        let hasFolder = FileManager.default.fileExists(atPath: handoffDirectory.path)
        let scanned = scan()
        let found = scanned.newest.filter { Self.decoders[$0.key] != nil }

        // A folder that could not be LISTED is its own reason, reported before the count is read: an
        // empty result from a failed listing is not evidence about what is in it (L11).
        for failure in scanned.couldNotList {
            Issue.record(Comment(rawValue: "a handoff directory could not be listed, so this check may "
                                 + "have examined less than it appears to have: \(failure)"))
        }

        guard hasFolder else {
            #expect(found.isEmpty, "no handoff folder, so there is nothing on this machine to check")
            return
        }
        let nothing = "the handoff folder exists but holds no file the app reads, in the live folder or "
            + "in any archived run, so the check above examined nothing"
        #expect(!found.isEmpty, Comment(rawValue: nothing))
    }

    // A handoff file this suite has never heard of is an accusation, not a silent pass: it is either a
    // contract the app reads and this does not check, or one it writes and nobody said so. Derived from
    // what is actually on disk rather than from a list somebody maintains (L96).
    @Test func everyRealHandoffFileIsAccountedFor() {
        for name in newestRealFiles().keys.sorted() {
            let known = Self.decoders[name] != nil || Self.writtenByTheAppOnly.contains(name)
                || Self.retired.contains(name)
            #expect(known, Comment(rawValue: "\(name) is on disk and this suite has no opinion about it: "
                                   + "either the app reads it and it needs a decoder here, or it does not "
                                   + "and it belongs in writtenByTheAppOnly, or it is retired"))
        }
    }
}
