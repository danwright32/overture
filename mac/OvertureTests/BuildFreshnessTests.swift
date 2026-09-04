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

    // #2553: provenance is REQUIRED of this helper rather than defaulted, so every case below has to say
    // which kind of build it is about. A default would have let the branch cases be written by accident
    // as whatever the ordinary case is, which is how the rule under test would be proved against itself.
    private func installed(_ commit: String, _ iso: String, repo: String = "/repo",
                           from provenance: BuildFreshness.Provenance?) -> InstalledBuild {
        InstalledBuild(commit: commit, commitDate: date(iso), repoPath: repo, provenance: provenance)
    }

    private func shipped(_ commit: String, _ iso: String) -> ShippedCommit {
        ShippedCommit(commit: commit, commitDate: date(iso))
    }

    // MARK: - The verdict

    // The same commit is the exact answer, and it does not go through the clock at all: two records of
    // one commit cannot disagree about how old it is.
    @Test func theSameCommitIsUpToDate() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z", from: .main),
                                       shipped: shipped("abc123", "2026-08-03T22:09:00Z"))
        #expect(v == .upToDate)
    }

    @Test func anOlderInstalledCommitIsBehind() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z", from: .main),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .behind(installedAt: date("2026-08-03T22:09:00Z"),
                             shippedAt: date("2026-08-03T23:06:00Z")))
    }

    // Installed from something NEWER than the last recorded merge, from a checkout the installer
    // confirmed was on main. Not behind: nothing is missing from it, the shipped record has simply not
    // caught up.
    @Test func anInstalledCommitNewerThanTheRecordIsNotBehind() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T23:30:00Z", from: .main),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .upToDate)
    }

    // MARK: - Where the build came from (#2553)

    // THE CASE THIS ISSUE IS ABOUT, and until now this file asserted the opposite of it. The test above
    // used to carry no provenance, describe itself as "a branch build, or a shipped record that has not
    // caught up", and assert `.upToDate` for both.
    //
    // A build from an unmerged branch is NEWER than everything on main, which is exactly why comparing
    // dates called it current. Hit 2026-08-11: the app in /Applications had been replaced at 21:22 while
    // several agents were running, and there was no way from the repo to tell whether it came from main
    // or from somebody's branch. It turned out to be Dan pressing Update, confirmed by ASKING him, which
    // is not a check.
    //
    // It matters because the live app holds the real store, so this is the one state nobody would
    // notice: the panel actively says everything is current.
    @Test func aBuildFromAnUnmergedBranchIsNotReportedAsCurrent() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T23:30:00Z", from: .branch),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .builtFromABranch)
    }

    // And it is still not current when it happens to be OLDER than the shipped commit. Both facts are
    // true then, and the branch is the one that explains the copy in front of him: updating is the
    // remedy for either, but "behind" invites him to read this as ordinary lag.
    @Test func aBranchBuildOlderThanTheShippedCommitStillSaysItIsABranchBuild() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z", from: .branch),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .builtFromABranch)
    }

    // The one thing that outranks provenance: the SAME commit. If what is installed is the commit that
    // shipped, it is current whatever ref it was built from, and saying otherwise would put a warning in
    // front of Dan for a copy that is byte for byte what has shipped.
    @Test func aBranchStampOnTheShippedCommitItselfIsStillCurrent() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z", from: .branch),
                                       shipped: shipped("abc123", "2026-08-03T22:09:00Z"))
        #expect(v == .upToDate)
    }

    // The two ways provenance can be absent are DIFFERENT facts and are kept apart, because they need
    // different things done about them (L11): a record written before Overture stamped provenance is
    // fixed by the next install, and an installer that could not reach the remote is not.
    @Test func aRecordWithNoProvenanceSaysWhyRatherThanClaimingToBeCurrent() {
        let notRecorded = BuildFreshness.verdict(
            installed: installed("abc123", "2026-08-03T23:30:00Z", from: nil),
            shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(notRecorded == .cannotTell(.provenanceNotRecorded))

        let couldNotTell = BuildFreshness.verdict(
            installed: installed("abc123", "2026-08-03T23:30:00Z", from: .unknown),
            shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(couldNotTell == .cannotTell(.provenanceUnknown))
    }

    // An unstamped record that is genuinely OLDER is still reported as behind, not as unknown. That is a
    // fact the two dates settle on their own, so withholding it would be refusing to say something this
    // check did measure.
    @Test func anUnstampedRecordThatIsOlderIsStillReportedAsBehind() {
        let v = BuildFreshness.verdict(installed: installed("abc123", "2026-08-03T22:09:00Z", from: nil),
                                       shipped: shipped("def456", "2026-08-03T23:06:00Z"))
        #expect(v == .behind(installedAt: date("2026-08-03T22:09:00Z"),
                             shippedAt: date("2026-08-03T23:06:00Z")))
    }

    // The panel must SHOW a branch build. A verdict nothing renders is the same as no check at all.
    @Test func thePanelShowsABranchBuild() {
        #expect(BuildFreshnessPanel.shouldShow(.builtFromABranch, dismissedThisLaunch: false))
        #expect(BuildFreshnessPanel.shouldShow(.builtFromABranch, dismissedThisLaunch: true) == false)
    }

    // And it says which state it is, in its own words rather than borrowing the out-of-date ones: the
    // remedy is the same but the reason is not, and a copy built from a branch is not merely old.
    @Test func aBranchBuildIsDescribedAsOneRatherThanAsOutOfDate() {
        let body = BuildFreshnessCopy.body(.builtFromABranch)
        #expect(body.isEmpty == false)
        #expect(body != BuildFreshnessCopy.body(.cannotTell(.noInstalledRecord)))
        #expect(BuildFreshnessCopy.title(.builtFromABranch) != BuildFreshnessCopy.title)
        #expect(BuildFreshnessCopy.title(.builtFromABranch) != BuildFreshnessCopy.cannotTellTitle)
    }

    // Each new reason it cannot tell gets its own sentence, for the same reason the two record-absence
    // reasons already do: one message for two causes sends whoever reads it to fix the wrong thing.
    @Test func eachNewReasonItCannotTellAlsoSaysWhichOne() {
        let notRecorded = BuildFreshnessCopy.body(.cannotTell(.provenanceNotRecorded))
        let unknown = BuildFreshnessCopy.body(.cannotTell(.provenanceUnknown))
        #expect(notRecorded.isEmpty == false)
        #expect(unknown.isEmpty == false)
        #expect(notRecorded != unknown)
        #expect(notRecorded != BuildFreshnessCopy.body(.cannotTell(.noInstalledRecord)))
        #expect(unknown != BuildFreshnessCopy.body(.cannotTell(.noShippedRecord)))
    }

    // The two new reasons are about WHERE this copy came from, not how old it is, so they get the title
    // that asks that question. Reusing the age title would have the two halves of the panel answering
    // different questions, which is the defect a cold read exists to catch and no other test can.
    @Test func theProvenanceReasonsAreTitledAsProvenanceRatherThanAge() {
        #expect(BuildFreshnessCopy.title(.cannotTell(.provenanceNotRecorded))
                == BuildFreshnessCopy.cannotTellProvenanceTitle)
        #expect(BuildFreshnessCopy.title(.cannotTell(.provenanceUnknown))
                == BuildFreshnessCopy.cannotTellProvenanceTitle)
        #expect(BuildFreshnessCopy.title(.cannotTell(.noInstalledRecord))
                == BuildFreshnessCopy.cannotTellTitle)
        #expect(BuildFreshnessCopy.cannotTellProvenanceTitle != BuildFreshnessCopy.cannotTellTitle)
    }

    // There is deliberately NO automated check that a body avoids restating its title (#843). One was
    // written and removed: scoring shared words fires on `.cannotTell(.noInstalledRecord)`, whose title
    // and body share "this copy" as a REFERENT rather than as a restatement, so it condemned correct
    // copy on the ordinary case and would be switched off within a day (L93). AGENTS.md is right that the
    // cold read is the only thing that catches this class, and it was done for all four sentences here:
    // two of them originally repeated their own heading and were rewritten before this shipped.

    // The failure path, and the whole reason this rule is written down rather than inferred: a missing
    // record must say so. A silent "up to date" is indistinguishable from no check at all, which is
    // precisely the state #1808 exists to end.
    @Test func aMissingRecordSaysItCannotTellRatherThanFresh() {
        #expect(BuildFreshness.verdict(installed: nil, shipped: shipped("d", "2026-08-03T23:06:00Z"))
                == .cannotTell(.noInstalledRecord))
        #expect(BuildFreshness.verdict(installed: installed("a", "2026-08-03T22:09:00Z", from: .main), shipped: nil)
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
    //
    // #2187: and the number is measured from the shipped commit to NOW, which is what "behind" means to
    // the person reading it. It used to be the span between the two COMMITS, which is a different
    // question and answered it wrongly: on 2026-08-06 at 9:56am Dan's copy was built at 9:52pm and main's
    // tip had landed at 12:46am, so the panel said "2h" about code that had shipped nine hours earlier,
    // and he read it as something having shipped that morning.
    @Test func itSaysHowFarBehindTheCopyIs() {
        let line = BuildFreshnessCopy.body(.behind(installedAt: date("2026-08-01T23:06:00Z"),
                                                   shippedAt: date("2026-08-03T23:06:00Z")),
                                           now: date("2026-08-05T23:06:00Z"))
        #expect(line == "This copy is 2d behind what has shipped, so anything fixed since then is not in front of you.")
    }

    // Dan's own case, to the minute.
    @Test func theNumberIsHowLongAgoTheShippedCodeLanded() {
        let line = BuildFreshnessCopy.body(.behind(installedAt: date("2026-08-06T01:52:41Z"),
                                                   shippedAt: date("2026-08-06T04:46:15Z")),
                                           now: date("2026-08-06T13:56:00Z"))
        #expect(line == "This copy is 9h behind what has shipped, so anything fixed since then is not in front of you.")
    }

    // The property the old measurement did not have, and the reason it could be wrong for hours without
    // anything looking broken: a number with both ends in the past is frozen. Sitting still all day has
    // to make it grow, or the panel goes on stating the distance it had at the moment of the merge.
    @Test func theNumberGrowsWhileTheCopyStaysBehind() {
        let verdict = BuildFreshness.Verdict.behind(installedAt: date("2026-08-06T01:52:41Z"),
                                                    shippedAt: date("2026-08-06T04:46:15Z"))
        #expect(BuildFreshnessCopy.body(verdict, now: date("2026-08-06T05:46:15Z")).contains("1h behind"))
        #expect(BuildFreshnessCopy.body(verdict, now: date("2026-08-06T13:46:15Z")).contains("9h behind"))
        #expect(BuildFreshnessCopy.body(verdict, now: date("2026-08-09T05:46:15Z")).contains("3d behind"))
    }

    // A clock that disagrees with the commit it is reading. Falling back to the span between the two
    // commits is the answer that needs no clock at all, and it is the one fact still known to be true:
    // this copy predates that commit by exactly that much. Never a negative, and never "0m behind",
    // which would read as up to date on the one screen that exists to say otherwise.
    @Test func aShippedCommitDatedAheadOfTheClockFallsBackToTheSpanBetweenTheCommits() {
        let line = BuildFreshnessCopy.body(.behind(installedAt: date("2026-08-06T01:00:00Z"),
                                                   shippedAt: date("2026-08-06T04:00:00Z")),
                                           now: date("2026-08-06T02:00:00Z"))
        #expect(line == "This copy is 3h behind what has shipped, so anything fixed since then is not in front of you.")
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
    // has been correct and unit-tested and uncalled since #1345. WHERE the read happens moved in #2065
    // and is guarded in BuildFreshnessStateTests; this holds the other half of the launch wiring.
    @Test func theAppClearsALeftoverUpdateScriptAtLaunch() {
        let source = SourceGuardHelper.source("Overture/App/OvertureApp.swift")
        #expect(!source.isEmpty)
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

// #2065: the answer is read when the panel is about to show, not once at launch.
//
// Dan met the dead-end fallback at 12:09 on a copy that had come straight from the installer two hours
// earlier: "This copy did not come from the installer... Ask Claude to reinstall Overture", with the
// Update button withheld. Both records were on disk the whole time. The app's ONE read, in
// `OvertureApp.init`, had raced the installer's write and lost, and nothing ever looked again.
//
// Two things were wrong and both are fixed here. The installer started the app before writing its
// records, so the FIRST launch after EVERY install raced them, which made the panel's most common
// appearance its wrong one. And a launch-pinned verdict is stale by construction: it cannot see a record
// that lands a second later, and it cannot see a merge that lands while Dan works (shipped-commit.json
// changed at 12:06 that day and the running app had no way to know).
//
// What it must NOT become is a read on every render pass. The installed commit really is fixed for the
// life of the process, so the answer is re-read on the moments something can have changed (the window
// appearing, Overture coming to the front, a slow tick while it sits open) and at most once per
// interval, never per frame (#1916, an idle surface pays nothing).
@MainActor
@Suite("The freshness panel reads the records when it shows, not once at launch (#2065)")
struct BuildFreshnessStateTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("freshness-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeInstallerRecords(in dir: URL) throws {
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-04T10:00:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-04T10:00:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // Counts the waits the watch loop makes, and lets the test move the world between them, so a whole
    // day of an app sitting open is driven without a real second passing (the DetachedRunActivity idiom).
    @MainActor private final class Sleeper {
        private(set) var waits = 0
        private let onWait: @MainActor (Int) -> Void
        init(onWait: @escaping @MainActor (Int) -> Void = { _ in }) { self.onWait = onWait }
        func sleep(_ seconds: TimeInterval) async {
            waits += 1
            onWait(waits)
        }
    }

    // THE BUG. The records are absent when the state is built (the installer has not written them yet)
    // and present by the time the panel would show. Dan must meet the Update button, not the dead end.
    @Test func aRecordThatLandsAfterLaunchIsSeenWhenThePanelShows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false)

        // The install race: the app is up, the installer has not finished writing.
        state.refreshIfStale(now: date("2026-08-04T10:00:09Z"))
        #expect(state.verdict == .cannotTell(.noInstalledRecord))
        #expect(state.repoPath == nil)

        try writeInstallerRecords(in: dir)
        state.refreshIfStale(now: date("2026-08-04T10:20:00Z"))

        #expect(state.verdict == .upToDate)
        #expect(state.repoPath == "/code/overture",
                "The panel must offer Update once the installer's record is there, never the ask-Claude fallback.")
    }

    // Nothing is claimed before anything has been read. Without this the sheet's first frame would carry
    // the failure message, which is the very sentence that was wrong (L11: a message may claim only what
    // its check measured, and nothing has been measured yet).
    @Test func nothingIsShownBeforeTheFirstRead() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false)

        #expect(state.verdict == nil)
        #expect(state.shouldShow == false)
    }

    // The failure path stays a failure. A copy with genuinely no records still says so rather than
    // quietly assuming it is fresh, which is the state #1808 exists to end.
    @Test func aGenuinelyRecordLessCopyStillSaysItCannotTell() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false)

        state.refreshIfStale(now: date("2026-08-04T10:00:09Z"))
        state.refreshIfStale(now: date("2026-08-04T18:00:00Z"))

        #expect(state.verdict == .cannotTell(.noInstalledRecord))
        #expect(state.repoPath == nil)
        #expect(state.shouldShow, "Not knowing is shown, never swallowed.")
    }

    // Dan asked for the periodic re-check (2026-08-04) so a merge landing while he works is noticed
    // without him having to click back into Overture.
    @Test func aMergeThatLandsWhileTheAppSitsOpenIsNoticed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-04T10:00:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-04T10:00:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)

        var clock = date("2026-08-04T10:00:09Z")
        let box = TaskBox()
        let sleeper = Sleeper { wait in
            clock += BuildFreshnessState.refreshInterval
            // A merge lands on the second tick, hours after the panel last had anything to say.
            if wait == 2 {
                try? #"{"version":1,"commit":"def456","commitDate":"2026-08-04T12:06:00Z"}"#
                    .write(to: dir.appendingPathComponent("shipped-commit.json"),
                           atomically: true, encoding: .utf8)
            }
            if wait == 3 { box.task?.cancel() }
        }
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false, sleep: sleeper.sleep, now: { clock })
        state.refreshIfStale(now: clock)
        #expect(state.verdict == .upToDate)

        box.task = Task { await state.watch() }
        _ = await box.task?.value

        #expect(sleeper.waits == 3)
        #expect(state.verdict == .behind(installedAt: date("2026-08-04T10:00:00Z"),
                                         shippedAt: date("2026-08-04T12:06:00Z")),
                "A merge landing while the app sits open must be noticed without Dan touching anything.")
    }

    // And the other half of the same rule: the watch is a slow tick, not a poll. Ticks that arrive with
    // nothing to have changed cost no read at all, so an app left open all day is not opening these two
    // files over and over (#1916).
    @Test func tickingCostsNoReadWhenSomethingElseJustRead() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counting = CountingDirectory(dir)
        let state = BuildFreshnessState(reader: counting.read)

        state.refreshIfStale(now: date("2026-08-04T10:00:09Z"))
        #expect(counting.reads == 1)

        // Overture coming to the front a minute later, and again a minute after that: nothing can have
        // changed in the meantime that the next tick will not catch.
        state.refreshIfStale(now: date("2026-08-04T10:01:09Z"))
        state.refreshIfStale(now: date("2026-08-04T10:02:09Z"))
        #expect(counting.reads == 1)

        state.refreshIfStale(now: date("2026-08-04T10:00:09Z").addingTimeInterval(BuildFreshnessState.refreshInterval))
        #expect(counting.reads == 2)
    }

    // "Not now" answers the news it was shown. A re-read that finds the SAME news must stay quiet: a
    // panel taking most of the window, reappearing while Dan works because a timer fired, would be the
    // same dismissal ignored.
    @Test func aDismissalHoldsWhileTheNewsIsUnchanged() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false)

        state.refreshIfStale(now: date("2026-08-04T10:00:09Z"))
        #expect(state.shouldShow)

        state.dismiss()
        state.refreshIfStale(now: date("2026-08-04T18:00:00Z"))

        #expect(state.shouldShow == false)
    }

    // Dan's call, 2026-08-04: a dismissal covers the merge it was telling him about, and something that
    // lands afterwards is different news, so it is worth raising again.
    @Test func aMergeAfterTheDismissalIsRaisedAgain() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-04T10:00:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)
        try #"{"version":1,"commit":"def456","commitDate":"2026-08-04T12:06:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false)

        state.refreshIfStale(now: date("2026-08-04T12:10:00Z"))
        #expect(state.shouldShow)
        state.dismiss()
        #expect(state.shouldShow == false)

        // Something else merges while he works.
        try #"{"version":1,"commit":"ghi789","commitDate":"2026-08-04T15:40:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)
        state.refreshIfStale(now: date("2026-08-04T15:45:00Z"))

        #expect(state.shouldShow, "A merge that landed after the dismissal is news the dismissal never covered.")
    }

    // And the one that keeps that from becoming a nag: an update makes the panel go away for good,
    // rather than reappearing because the answer changed.
    @Test func catchingUpEndsThePanelRatherThanChangingIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":1,"commit":"abc123","commitDate":"2026-08-04T10:00:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)
        try #"{"version":1,"commit":"def456","commitDate":"2026-08-04T12:06:00Z"}"#
            .write(to: dir.appendingPathComponent("shipped-commit.json"), atomically: true, encoding: .utf8)
        let state = BuildFreshnessState(directory: dir, isRunFromSource: false)
        state.refreshIfStale(now: date("2026-08-04T12:10:00Z"))
        #expect(state.shouldShow)

        try #"{"version":1,"commit":"def456","commitDate":"2026-08-04T12:06:00Z","repoPath":"/code/overture"}"#
            .write(to: dir.appendingPathComponent("installed-build.json"), atomically: true, encoding: .utf8)
        state.refreshIfStale(now: date("2026-08-04T12:40:00Z"))

        #expect(state.shouldShow == false)
    }

    // MARK: - Wiring

    // The installer's ordering, which is where the bug actually came from: it bootstrapped the login
    // agent (which launches Overture) and only then wrote the records, so the first launch after every
    // install read a directory the installer had not finished writing. Invisible to any test of the
    // verdict itself, which is exactly how it shipped green.
    @Test func theInstallerWritesBothRecordsBeforeItStartsTheApp() {
        let source = SourceGuardHelper.source("build-install.sh")
        #expect(!source.isEmpty)
        guard let bootstrap = source.range(of: "launchctl bootstrap"),
              let installedWrite = source.range(of: "installed-build.json", options: .backwards),
              let shippedWrite = source.range(of: "record-shipped-commit.sh", options: .backwards) else {
            Issue.record("build-install.sh must write both records and bootstrap the login agent.")
            return
        }
        #expect(installedWrite.upperBound < bootstrap.lowerBound,
                "installed-build.json must be written BEFORE the agent starts the app, or the first launch races it (#2065).")
        #expect(shippedWrite.upperBound < bootstrap.lowerBound,
                "shipped-commit.json must be recorded before the agent starts the app, for the same reason.")
    }

    // The guard and its wiring are two claims (#887). Every rule above passes with the app still reading
    // once at launch and never looking again, which is the defect.
    @Test func theAppLetsThePanelOwnTheReadInsteadOfPinningItAtLaunch() {
        let app = SourceGuardHelper.source("Overture/App/OvertureApp.swift")
        #expect(!app.isEmpty)
        #expect(app.contains(".buildFreshnessNotice("),
                "The app must still present the panel (#1808).")
        #expect(app.contains("BuildFreshness.verdict(in:") == false,
                "A verdict pinned in init is stale by construction: the panel owns the read now (#2065).")

        let sheet = SourceGuardHelper.source("Overture/UI/BuildFreshnessSheet.swift")
        // #2726: the `.task` site, which is the one "when it shows" means. A bare `refreshIfStale` was
        // answered by the app-became-active handler AND by a comment mentioning the name, so the panel
        // could have stopped reading on appear entirely and this stayed green (L135, L103).
        #expect(SourceGuardHelper.containsCode(
            ".task { state.refreshIfStale() await state.watch() }", in: sheet),
                "The panel must read the records when it shows.")
        #expect(sheet.contains("state.watch()"),
                "And keep watching, so a merge landing while Dan works is noticed (his call, 2026-08-04).")
    }
}

// Holds the watch task so the sleeper can stop the loop it is driving.
@MainActor private final class TaskBox {
    var task: Task<Void, Never>?
}

// Counts what reading the records actually costs, so a test can assert what an app sitting still pays
// rather than only what it answers.
@MainActor private final class CountingDirectory {
    private let directory: URL
    private(set) var reads = 0
    init(_ directory: URL) { self.directory = directory }
    func read() -> (BuildFreshness.Verdict, String?) {
        reads += 1
        return (BuildFreshness.verdict(in: directory), BuildFreshnessPanel.repoPath(in: directory))
    }
}
