import Testing
import Foundation
@testable import Overture

// #821: Overture writes two kinds of file it never reads again, and nothing ever deleted either.
//
// The pinned page (`overture-scout-page-<id>.html`) is the exact bytes the extract run read, kept so the
// run works from what the app fetched and hashed rather than from whatever the site served a second
// later. The `.corrupt` file is the bytes of a results file that did not parse, kept because they are the
// only evidence of what that run actually did.
//
// Both are deliberate. Neither has an owner. This is the one rule for how long they stay.
@Suite("Handoff cleanup (#821)")
struct HandoffCleanupTests {
    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-handoffcleanup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let now = Date(timeIntervalSince1970: 1_780_000_000)   // a fixed clock, so no test is dated

    @discardableResult
    private func seed(_ name: String, in dir: URL, ageInDays: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("bytes".utf8).write(to: url)
        let modified = now.addingTimeInterval(-ageInDays * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - The window

    // Dan's call: two weeks. Long enough that a source behaving oddly can still be checked against the
    // page Overture actually read, short enough that the folder stays small.
    @Test func theRetentionWindowIsFourteenDays() {
        #expect(HandoffCleanup.keepFor == 14 * 24 * 60 * 60)
    }

    @Test func aPinOlderThanTheWindowIsDeleted() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = try seed("overture-scout-page-bargemusic.html", in: dir, ageInDays: 15)

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(stale) == false)
        #expect(result.deleted == [stale])
        #expect(result.failed.isEmpty)
    }

    @Test func aPinInsideTheWindowIsKept() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try seed("overture-scout-page-kaufman.html", in: dir, ageInDays: 13)

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(fresh))
        #expect(result.deleted.isEmpty)
    }

    // The pin a live run is about to read is minutes old, never days, so no horizon measured in days can
    // reach it. This is the assertion that says so out loud rather than leaving it to be re-derived.
    @Test func aPinAnInFlightRunIsAboutToReadIsNeverTouched() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let justWritten = try seed("overture-scout-page-merkin.html", in: dir, ageInDays: 0)

        HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(justWritten))
    }

    // A lead pin, from a link Dan pasted once and never again. These are the ones that genuinely grow
    // without bound: one file per distinct URL, forever, each with an id no watchlist row refers to.
    @Test func aStaleLeadPinIsDeletedEvenThoughNoSourceOwnsIt() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lead = try seed("overture-scout-page-lead-bargemusic-org-events.html", in: dir, ageInDays: 30)

        HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(lead) == false)
    }

    @Test func aStaleCorruptResultsFileIsDeleted() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corrupt = try seed("overture-scout-extract-results.json.corrupt", in: dir, ageInDays: 20)

        HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(corrupt) == false)
    }

    // The whole reason those bytes were kept in the first place (#868): they are the only record of what
    // a run that came back unreadable actually produced. A sweep that took them the next morning would
    // undo the fix it is being added alongside.
    @Test func aRecentCorruptResultsFileIsKeptAsEvidence() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corrupt = try seed("overture-prep-results.json.corrupt", in: dir, ageInDays: 2)

        HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(corrupt))
    }

    // #911: the quarantined bytes are STAMPED now (`<results>.<timestamp>.corrupt`), because a fixed name
    // meant a second bad run overwrote the first one's evidence, and an intermittent failure is exactly the
    // one whose evidence that destroyed. The stamped name has to stay inside this sweep's ownership, or the
    // fix trades a lost file for a folder that grows forever. Asserted from THIS side, because results-guard
    // is a shell script and nothing else would notice the two rules parting company.
    @Test func aStampedCorruptFileIsStillOwnedAndStillPruned() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stamped = try seed("overture-scout-extract-results.json.20260714T104500Z.corrupt",
                               in: dir, ageInDays: 30)
        let collision = try seed("overture-prep-results.json.20260714T104500Z-2.corrupt",
                                 in: dir, ageInDays: 30)
        let fresh = try seed("overture-prep-results.json.20260714T104500Z-3.corrupt",
                             in: dir, ageInDays: 1)

        #expect(HandoffCleanup.owns(stamped.lastPathComponent))
        #expect(HandoffCleanup.owns(collision.lastPathComponent))

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(!exists(stamped))                     // past the horizon: pruned on the same rule as before
        #expect(!exists(collision))
        #expect(exists(fresh), "evidence inside the 14-day window must never be swept")
        #expect(result.deleted.count == 2)
    }

    // MARK: - It owns two names and nothing else
    //
    // The handoff directory is not a scratch folder. It holds Dan's booking history, his Gmail tokens,
    // his voice guidance, and the queue and results files the detached runs hand back. A sweep that
    // deleted by age alone would eventually take every one of them, and the loss would be silent. So the
    // rule is by NAME first and age second: a file this enum does not own is not a candidate at any age.
    @Test func nothingElseInTheHandoffFolderIsEverTouchedHoweverOldItIs() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let untouchable = [
            "overture-history.json",              // the booking history import
            "gmail-tokens.json",                  // Dan's credentials
            "gmail-oauth.json",
            "overture-voice-guidance.md",         // his own words about how the emails should sound
            "overture-voice-guidance.backup.md",
            "overture-voice-feedback.json",
            "overture-recent-openers.json",       // the openers a recent run used, for anti-repetition
            "downbeat-export.json",
            "overture-scout-extract-queue.json",  // what a run was asked to read
            "overture-scout-extract-results.json",// and what it came back with
            "overture-prep-results.json",
            "overture-reply-classify-results.json",
            "scout-extract-run.log",
            "scout-extract-running",              // a run marker
        ].map { try? seed($0, in: dir, ageInDays: 400) }

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        for file in untouchable.compactMap({ $0 }) {
            #expect(exists(file), "the sweep deleted \(file.lastPathComponent), which it does not own")
        }
        #expect(result.deleted.isEmpty)
    }

    // A near miss, deliberately: an ancient results file is NOT a `.corrupt` one, and a page pinned by
    // some other tool is not one of ours. Suffix and prefix both have to match.
    @Test func aFileThatMerelyLooksLikeOneOfOursIsNotSwept() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notOurs = try seed("scout-page-bargemusic.html", in: dir, ageInDays: 400)
        let alsoNotOurs = try seed("overture-scout-page-bargemusic.html.bak", in: dir, ageInDays: 400)

        HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(notOurs))
        #expect(exists(alsoNotOurs))
    }

    // MARK: - Failure paths

    // Housekeeping must never be able to stop the app opening. A file this process cannot delete (a
    // permissions problem, a file locked by something else) is REPORTED and skipped, and every other
    // stale file in the folder still goes. The alternative, a sweep that abandons the rest of its work on
    // the first stubborn file, would quietly stop cleaning up at all and nobody would know.
    @Test func aFileThatCannotBeDeletedIsReportedAndTheRestOfTheSweepStillRuns() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stubborn = try seed("overture-scout-page-stubborn.html", in: dir, ageInDays: 40)
        let deletable = try seed("overture-scout-page-fine.html", in: dir, ageInDays: 40)

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now,
                                          fileManager: RefusingFileManager(refusing: stubborn))

        #expect(result.failed == [stubborn])
        #expect(exists(stubborn))                       // still there, and it will be retried next launch
        #expect(result.deleted == [deletable])
        #expect(exists(deletable) == false)             // the one it could take, it took
    }

    // A file whose modification date cannot be read has no age, and a file with no age is never old
    // enough to delete. Unknown must fail towards keeping the bytes, never towards destroying them.
    @Test func aFileWhoseAgeCannotBeReadIsKept() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let undatable = try seed("overture-scout-page-undatable.html", in: dir, ageInDays: 40)

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now,
                                          fileManager: UndatableFileManager(hiding: undatable))

        #expect(exists(undatable))
        #expect(result.deleted.isEmpty)
    }

    // A fresh install, before anything has written a handoff file at all.
    @Test func aMissingHandoffDirectoryIsNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-handoffcleanup-never-created-\(UUID().uuidString)")

        let result = HandoffCleanup.sweep(handoffDirectory: missing, now: now)

        #expect(result.deleted.isEmpty)
        #expect(result.failed.isEmpty)
    }

    // MARK: - The wire
    //
    // The sweep and its wiring are two separate claims, and this repo has already shipped a guard whose
    // wire was never connected while every test stayed green (#887). A perfect sweep that launch never
    // calls cleans up nothing at all, and looks exactly like one that works.
    @Test func launchActuallyRunsTheSweep() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/App/OvertureApp.swift")
        let src = try String(contentsOf: app, encoding: .utf8)

        #expect(src.contains("HandoffCleanup.sweep(handoffDirectory: StoreLocation.handoffDirectory"),
                "OvertureApp no longer sweeps the handoff directory at launch, so the pinned pages and the .corrupt files accumulate forever again (#821).")
    }

    // A subdirectory (the store backups live one level up, but nothing says a folder can never appear
    // here) is not a file to delete, whatever it is called.
    @Test func aDirectoryIsNeverDeletedEvenIfItsNameMatches() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("overture-scout-page-folder.html", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-400 * 24 * 60 * 60)], ofItemAtPath: folder.path)

        let result = HandoffCleanup.sweep(handoffDirectory: dir, now: now)

        #expect(exists(folder))
        #expect(result.deleted.isEmpty)
    }
}

// Refuses to delete one specific file, and behaves normally for every other. Deterministic, unlike
// chmod-ing a directory read-only, which does nothing at all when the suite happens to run as root.
private final class RefusingFileManager: FileManager {
    private let refused: URL
    init(refusing: URL) {
        self.refused = refusing
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL == refused.standardizedFileURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

// Hides one file's modification date, the way a file whose attributes cannot be read would.
private final class UndatableFileManager: FileManager {
    private let hidden: URL
    init(hiding: URL) {
        self.hidden = hiding
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        var attributes = try super.attributesOfItem(atPath: path)
        if URL(fileURLWithPath: path).standardizedFileURL == hidden.standardizedFileURL {
            attributes.removeValue(forKey: .modificationDate)
        }
        return attributes
    }
}
