import Testing
import Foundation

// #1808: the app tells Dan when the copy he is looking at is behind what has shipped.
//
// The gap is routinely days wide, because he installs Release by hand and nothing anywhere says the
// installed app is missing merged work. It has cost real time more than once: he reports a bug in
// behaviour that was already fixed, and the fix simply is not in front of him. `check-release-freshness.sh`
// was written for exactly this (#1345) and has never had a caller, and it is a shell script, so it was
// never going to reach somebody who does not work in a terminal.
//
// The app cannot run git, so it compares two small records written by the two things that DO know: the
// installer records what it installed, and the merge path records what has shipped. Every rule about
// reading them is pure and lives here.
@Suite("The app knows when it is behind what shipped (#1808)")
struct BuildFreshnessTests {
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    private func installed(_ commit: String, _ iso: String, repo: String = "/repo") -> InstalledBuild {
        InstalledBuild(commit: commit, commitDate: date(iso), repoPath: repo)
    }

    private func shipped(_ commit: String, _ iso: String) -> ShippedCommit {
        ShippedCommit(commit: commit, commitDate: date(iso))
    }

    // MARK: - The verdict

    // The same commit is the exact answer, and it does not go through the clock at all: two records of
    // one commit cannot disagree about how old it is.
    @Test func theSameCommitIsUpToDate() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z"),
                                       shipped: shipped("abc123", "2026-08-03T22:09:00Z"))
        #expect(v == .upToDate)
    }

    @Test func anOlderInstalledCommitIsBehind() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z"),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .behind(installedAt: date("2026-08-03T22:09:00Z"),
                             shippedAt: date("2026-08-03T23:06:00Z")))
    }

    // Installed from something NEWER than the last recorded merge (a branch build, or a shipped record
    // that has not caught up). Not behind: nothing is missing from it.
    @Test func anInstalledCommitNewerThanTheRecordIsNotBehind() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T23:30:00Z"),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .upToDate)
    }

    // The failure path, and the whole reason this rule is written down rather than inferred: a missing
    // record must say so. A silent "up to date" is indistinguishable from no check at all, which is
    // precisely the state #1808 exists to end.
    @Test func aMissingRecordSaysItCannotTellRatherThanFresh() {
        #expect(BuildFreshness.verdict(installed: nil, shipped: shipped("d", "2026-08-03T23:06:00Z"))
                == .cannotTell(.noInstalledRecord))
        #expect(BuildFreshness.verdict(installed: installed("a", "2026-08-03T22:09:00Z"), shipped: nil)
                == .cannotTell(.noShippedRecord))
        #expect(BuildFreshness.verdict(installed: nil, shipped: nil) == .cannotTell(.noInstalledRecord))
    }

    // MARK: - Reading the two records off disk

    // Injected directory, never the live one: a test must be structurally unable to read or write Dan's
    // real Application Support folder (L2).
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readsTheTwoRecordsTheInstallerAndTheMergePathWrite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-03T22:09:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)
        try #"{"version":1,"commit":"def456","commitDate":"2026-08-03T23:06:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)

        let v = BuildFreshness.verdict(in: dir)

        #expect(v == .behind(installedAt: date("2026-08-03T22:09:00Z"),
                             shippedAt: date("2026-08-03T23:06:00Z")))
        #expect(BuildFreshness.installedRecord(in: dir)?.repoPath == "/code/overture")
    }

    // A record that is present but unreadable is the same answer as one that is absent, and for the same
    // reason: a file that cannot be decoded tells us nothing about what is installed, so claiming it is
    // up to date would be inventing an answer.
    @Test func anUnreadableRecordAlsoSaysItCannotTell() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not json at all".write(to: dir.appendingPathComponent("installed-build.json"),
                                    atomically: true, encoding: .utf8)
        try #"{"version":1,"commit":"def456","commitDate":"2026-08-03T23:06:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)

        #expect(BuildFreshness.verdict(in: dir) == .cannotTell(.noInstalledRecord))
    }

    @Test func anEmptyDirectoryCannotTell() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BuildFreshness.verdict(in: dir) == .cannotTell(.noInstalledRecord))
    }

    // MARK: - When the panel appears, and what it says

    // Dismissing lasts for this launch only. A permanent dismissal would recreate exactly the invisible
    // gap this exists to close, and it would do it silently, which is worse than never having built it.
    @Test func thePanelShowsWhenBehindAndStaysDismissedOnlyForThisLaunch() {
        let behind = BuildFreshness.Verdict.behind(installedAt: date("2026-08-01T10:00:00Z"),
                                                   shippedAt: date("2026-08-03T23:06:00Z"))
        #expect(BuildFreshnessPanel.shouldShow(behind, dismissedThisLaunch: false))
        #expect(BuildFreshnessPanel.shouldShow(behind, dismissedThisLaunch: true) == false)
    }

    @Test func thePanelStaysAwayWhenTheCopyIsCurrent() {
        #expect(BuildFreshnessPanel.shouldShow(.upToDate, dismissedThisLaunch: false) == false)
    }

    // Not knowing is shown, not swallowed. It means the mechanism itself is broken, which is the one
    // state where saying nothing is indistinguishable from saying "you are up to date".
    @Test func thePanelAlsoShowsWhenItCannotTell() {
        #expect(BuildFreshnessPanel.shouldShow(.cannotTell(.noInstalledRecord), dismissedThisLaunch: false))
        #expect(BuildFreshnessPanel.shouldShow(.cannotTell(.noShippedRecord), dismissedThisLaunch: false))
    }

    // The gap is stated as ONE number, because "how far behind am I" is the only question the panel is
    // answering. Two timestamps side by side would make him do the subtraction.
    @Test func itSaysHowFarBehindTheCopyIs() {
        let line = BuildFreshnessCopy.body(.behind(installedAt: date("2026-08-01T23:06:00Z"),
                                                   shippedAt: date("2026-08-03T23:06:00Z")))
        #expect(line == "This copy is 2d behind what has shipped, so anything fixed since then is not in front of you.")
    }

    // Each reason says its own thing, because the two are different problems for whoever fixes them.
    @Test func eachReasonItCannotTellSaysWhichOne() {
        #expect(BuildFreshnessCopy.body(.cannotTell(.noInstalledRecord))
                == "This copy did not come from the installer, so there is no record of what went into it.")
        #expect(BuildFreshnessCopy.body(.cannotTell(.noShippedRecord))
                == "Nothing has recorded a merge on this Mac, so there is nothing to compare this copy against.")
    }

    // MARK: - The two records survive where they live

    // In Release these sit in the SAME folder as the handoff files, which is swept at launch (#821). The
    // sweep is name-first and does not own them, and this is what holds that: a record aged out silently
    // would turn the whole check off, and the app would then report "cannot tell" forever with nothing
    // pointing at why.
    @Test func theLaunchSweepDoesNotOwnEitherRecord() {
        #expect(HandoffCleanup.owns(BuildFreshness.installedRecordFilename) == false)
        #expect(HandoffCleanup.owns(BuildFreshness.shippedRecordFilename) == false)
    }

    // MARK: - Wiring

    // The guard and its wiring are two claims (#887). Every rule above passes with nothing in the app
    // ever reading it, which is precisely the state #1808 was filed about: check-release-freshness.sh
    // has been correct and unit-tested and uncalled since #1345.
    @Test func theAppReadsTheVerdictAtLaunchAndShowsIt() {
        let source = SourceGuardHelper.source("Overture/App/OvertureApp.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("BuildFreshness.verdict(in:"),
                "The app must actually read the verdict at launch (#1808).")
        #expect(source.contains(".buildFreshnessNotice("),
                "Reading it without presenting it is the dormant-guard defect this issue is about.")
        #expect(source.contains("UpdateCommandFile.sweep()"),
                "A leftover update script from a run that died must be cleared at launch (Dan, 2026-08-03).")
    }

    // The installer is the only thing that can record what it installed, so a build-install.sh that
    // forgets leaves the app permanently unable to tell how old it is.
    @Test func theInstallerRecordsWhatItInstalled() {
        let source = SourceGuardHelper.source("build-install.sh")
        #expect(!source.isEmpty)
        #expect(source.contains("installed-build.json"))
        #expect(source.contains("record-shipped-commit.sh"),
                "A fresh install must also record what has shipped, or the app shows a panel Dan cannot clear.")
    }

    // The Update button is only real when the app knows where the code is, which it learns from the
    // installer's own record. Offering a button that cannot act is the defect #1778 sweeps for.
    @Test func theUpdateButtonIsOfferedOnlyWhenTheRepoIsKnown() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BuildFreshnessPanel.repoPath(in: dir) == nil)

        try #"{"version":1,"commit":"abc","commitDate":"2026-08-03T22:09:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)

        #expect(BuildFreshnessPanel.repoPath(in: dir) == "/code/overture")
    }
}
