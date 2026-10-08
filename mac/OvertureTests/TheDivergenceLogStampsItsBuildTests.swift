import Testing
import Foundation

// #4583 (plan v7 D7 and D8, L179): every divergence log record says which build wrote it and which queue
// engine output it is about.
//
// WHAT WAS WRONG. `CardDivergenceRecord` carried no commit, no build and no generation, so a record the queue
// engine verifier wrote (#4358 slice E2) could not say which build wrote it. Plan v7 section 15's merge gate
// counts only the mismatch records stamped with the branch's commit; with nothing to filter on, a record an
// older build wrote reads as a finding against the new one, and the gate can never pass or can never fail
// depending on what the file happens to hold.
//
// THE RULES THIS PINS. The stamp is applied where every writer's line is written (`CardDivergenceLog`'s one
// private write), never by each caller (L593, L621). The commit comes from the record the installer already
// writes beside the log (`installed-build.json`), the same one the freshness panel reads, never a second source.
// A record written before this shipped still loads and reads as UNSTAMPED, never as the current build (L1013).
// A rewrite (the compaction) carries a record's stamp as it was, because rewriting is not writing it again.
@Suite("Every divergence log record carries the build and generation that wrote it (#4583)")
struct TheDivergenceLogStampsItsBuildTests {
    private let sandboxes = TemporarySandboxes()

    private static let sha = "0123456789abcdef0123456789abcdef01234567"
    private static let otherSha = "fedcba9876543210fedcba9876543210fedcba98"

    private func record(_ sequence: Int, kind: CardDivergenceRecord.Kind = .cardDivergence,
                        generation: Int? = nil) -> CardDivergenceRecord {
        CardDivergenceRecord(session: "s", sequence: sequence,
                             at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
                             fields: ["venue"], cardsBuilt: 0, stage: nil, kind: kind,
                             source: kind == .cardDivergence ? nil : .reconcile, generation: generation)
    }

    // What `mac/build-install.sh` writes, byte for byte in shape, so the read under test is the real one.
    private func installRecord(commit: String, in dir: URL) throws {
        try #"{"version":2,"commit":"\#(commit)","commitDate":"2026-10-07T12:00:00Z","repoPath":"/code/overture","provenance":"branch"}"#
            .write(to: dir.appendingPathComponent(BuildFreshness.installedRecordFilename), atomically: true,
                   encoding: .utf8)
    }

    // THE FINDING (L1013). A line written before this shipped, and one written before #4354, both still load,
    // and both read as unstamped rather than as whatever build is reading them.
    @Test func aRecordWrittenBeforeTheStampLoadsAndReadsAsUnstamped() throws {
        let beforeThis = #"{"at":"2026-10-07T10:00:00Z","cardsBuilt":0,"fields":["shows"],"kind":"foreignSave","sequence":4,"session":"old","source":"reconcile","suppressedRepeats":0}"#
        let beforeKinds = #"{"at":"2026-09-08T10:00:00Z","cardsBuilt":20,"fields":["venue"],"sequence":1,"session":"older","stage":"scout"}"#
        let read = CardDivergenceLog.read(beforeThis + "\n" + beforeKinds + "\n")
        #expect(read.unreadableLines == 0, "an older line no longer loads: \(read.unreadable)")
        #expect(read.records.count == 2)
        for record in read.records {
            #expect(record.stamp == .unstamped, "an older record read as \(record.stamp)")
            #expect(record.build == nil && record.commit == nil && record.generation == nil)
        }
        let split = try #require(read.byCommit(Self.sha))
        #expect(split.written.isEmpty, "an unstamped record was counted against the build asking")
        #expect(split.unstamped == 2)
    }

    // THE LOWEST LAYER. Every one of the three ways a line enters the live file stamps it with the commit the
    // installer recorded beside the log: the plain append (the card check), the cooled append (the engine's
    // findings) and the drained count.
    @Test func everyWriterStampsTheCommitTheInstallerRecordedBesideTheLog() throws {
        let dir = try sandboxes.make(named: "4583-every-writer")
        try installRecord(commit: Self.sha, in: dir)
        let url = CardDivergenceLog.url(in: dir)
        var cooldown = CardDivergenceLog.Cooldown()
        #expect(CardDivergenceLog.append(record(1), to: url, isRunFromSource: false, testRun: .notGiven))
        #expect(CardDivergenceLog.append(record(2, kind: .factMismatch, generation: 7), to: url,
                                         through: &cooldown, isRunFromSource: false, testRun: .notGiven))
        let held = CardDivergenceLog.Cooldown.Held(kind: .factMismatch, source: .reconcile, suppressedRepeats: 3)
        #expect(CardDivergenceLog.appendDrained(held, session: "s", sequence: 3,
                                                at: Date(timeIntervalSince1970: 1_800_001_000), to: url,
                                                isRunFromSource: false, testRun: .notGiven))
        let records = CardDivergenceLog.read(at: url).records
        #expect(records.map(\.sequence) == [1, 2, 3])
        for record in records {
            #expect(record.stamp == .commit(Self.sha), "record \(record.sequence) was stamped \(record.stamp)")
            #expect(record.build == .installed)
        }
        // The generation is the writer's to give, and the cooled append carries it (and its count) on a COPY.
        #expect(records.map(\.generation) == [nil, 7, nil])
        #expect(records.last?.suppressedRepeats == 3)
    }

    // A build run from source is not the installed copy, so an installed record beside the log is not about it
    // (`BuildFreshness`'s rule, #2077): stamped as run from source, with no commit.
    @Test func aBuildRunFromSourceIsStampedAsSuchEvenBesideAnInstalledRecord() throws {
        let dir = try sandboxes.make(named: "4583-from-source")
        try installRecord(commit: Self.sha, in: dir)
        let url = CardDivergenceLog.url(in: dir)
        #expect(CardDivergenceLog.append(record(1), to: url, isRunFromSource: true, testRun: .notGiven))
        let written = try #require(CardDivergenceLog.read(at: url).records.first)
        #expect(written.stamp == .commitUnknown(.runFromSource))
        #expect(written.commit == nil)
    }

    // An installed copy with no record beside its log says so: stamped, and distinct from an old record.
    @Test func anInstalledCopyWithNoRecordIsStampedAsNotRecorded() throws {
        let dir = try sandboxes.make(named: "4583-no-record")
        let url = CardDivergenceLog.url(in: dir)
        #expect(CardDivergenceLog.append(record(1), to: url, isRunFromSource: false, testRun: .notGiven))
        let written = try #require(CardDivergenceLog.read(at: url).records.first)
        #expect(written.stamp == .commitUnknown(.notRecorded))
        #expect(written.stamp != .unstamped)
    }

    // The write is authoritative: whatever stamp a record carried in, the line says the writing build.
    @Test func theWriteReplacesAnyStampTheRecordCarriedIn() throws {
        let dir = try sandboxes.make(named: "4583-replace")
        try installRecord(commit: Self.sha, in: dir)
        let url = CardDivergenceLog.url(in: dir)
        let carried = try #require(CardDivergenceLog.read(
            #"{"at":"2026-10-07T10:00:00Z","build":"installed","cardsBuilt":0,"commit":"\#(Self.otherSha)","fields":["venue"],"sequence":1,"session":"s"}"#
        ).records.first)
        #expect(carried.stamp == .commit(Self.otherSha))
        #expect(CardDivergenceLog.append(carried, to: url, isRunFromSource: false, testRun: .notGiven))
        #expect(CardDivergenceLog.read(at: url).records.first?.stamp == .commit(Self.sha))
    }

    // A compaction REWRITES records rather than writing them again, so each keeps the stamp it was written
    // with, and an unstamped one stays unstamped rather than becoming the build that compacted it.
    @Test func aCompactionKeepsEachRecordsStampAsItWasWritten() throws {
        let dir = try sandboxes.make(named: "4583-compaction")
        try installRecord(commit: Self.sha, in: dir)
        let url = CardDivergenceLog.url(in: dir)
        let old = #"{"at":"2026-09-08T10:00:00Z","cardsBuilt":20,"fields":["stage"],"sequence":0,"session":"old"}"#
        let other = #"{"at":"2026-09-09T10:00:00Z","build":"installed","cardsBuilt":20,"commit":"\#(Self.otherSha)","fields":["venue"],"generation":4,"sequence":0,"session":"other"}"#
        try (old + "\n" + other + "\n").write(to: url, atomically: true, encoding: .utf8)
        for n in 1...4 { #expect(CardDivergenceLog.append(record(n), to: url, isRunFromSource: false, testRun: .notGiven)) }

        let outcome = CardDivergenceLog.compact(at: url, cap: 4)
        #expect(outcome == .archived(count: 2), "the fixture did not compact: \(outcome)")

        let live = CardDivergenceLog.read(at: url).records
        let archived = CardDivergenceLog.read(at: CardDivergenceLog.archiveURL(besideLogAt: url)).records
        let all = live + archived
        #expect(all.count == 6)
        #expect(all.first { $0.session == "old" }?.stamp == .unstamped)
        let kept = all.first { $0.session == "other" }
        #expect(kept?.stamp == .commit(Self.otherSha))
        #expect(kept?.generation == 4)
        #expect(all.filter { $0.session == "s" }.allSatisfy { $0.stamp == .commit(Self.sha) })
    }

    // THE GATE'S FILTER (plan v7 section 15). Split by what wrote each record, and every record counted once.
    @Test func theGatesFilterCountsOnlyTheBuildItIsAskedAbout() throws {
        let lines = [
            #"{"at":"2026-10-07T10:00:00Z","build":"installed","cardsBuilt":0,"commit":"\#(Self.sha)","fields":[],"kind":"factMismatch","sequence":1,"session":"a"}"#,
            #"{"at":"2026-10-07T10:00:01Z","build":"installed","cardsBuilt":0,"commit":"\#(Self.otherSha)","fields":[],"kind":"factMismatch","sequence":2,"session":"a"}"#,
            #"{"at":"2026-10-07T10:00:02Z","build":"runFromSource","cardsBuilt":0,"fields":[],"kind":"factMismatch","sequence":3,"session":"a"}"#,
            #"{"at":"2026-10-07T10:00:03Z","cardsBuilt":0,"fields":[],"kind":"factMismatch","sequence":4,"session":"a"}"#,
        ]
        let read = CardDivergenceLog.read(lines.joined(separator: "\n"))
        #expect(read.records.count == 4)
        let split = try #require(read.byCommit(Self.sha.uppercased()))
        #expect(split.written.map(\.sequence) == [1])
        #expect(split.otherCommits == 1)
        #expect(split.commitUnknown == 1)
        #expect(split.unstamped == 1)
        #expect(split.written.count + split.otherCommits + split.commitUnknown + split.unstamped == read.records.count)
        // A query that is not a whole commit is refused rather than matching nothing, which would read as clean
        // (L320): an abbreviated commit is the likeliest mistake a gate makes.
        #expect(read.byCommit(String(Self.sha.prefix(7))) == nil)
        #expect(read.byCommit("") == nil)
    }

    // MARK: - #4358 slice E4c: a test run's commit, and the archive keyed by build

    // The existing tests above pass `testRun: .notGiven`, so a run with the gate's variable set cannot change what
    // they assert: the variable is inherited by every test in that process (L439).

    // A test run told a whole commit stamps its lines as a test run of it, whatever the installer's record says and
    // however it was built, and the gate's filter finds them.
    @Test func aTestRunToldAWholeCommitStampsItsLinesAsATestRunOfIt() throws {
        let dir = try sandboxes.make(named: "4358-e4c-test-run")
        try installRecord(commit: Self.otherSha, in: dir)
        let url = CardDivergenceLog.url(in: dir)
        var cooldown = CardDivergenceLog.Cooldown()
        #expect(CardDivergenceLog.append(record(1), to: url, isRunFromSource: true, testRun: .commit(Self.sha)))
        #expect(CardDivergenceLog.append(record(2, kind: .factMismatch), to: url, through: &cooldown,
                                         isRunFromSource: false, testRun: .commit(Self.sha)))
        let records = CardDivergenceLog.read(at: url).records
        #expect(records.map(\.build) == [.testRun, .testRun])
        #expect(records.allSatisfy { $0.stamp == .commit(Self.sha) })
        #expect(CardDivergenceLog.read(at: url).byCommit(Self.sha)?.written.count == 2)
    }

    // The variable is honoured only in a test process and only as a whole commit, and the production answer to
    // "is this a test process" is true here, inside the test host.
    @Test func theGateCommitIsReadOnlyInATestProcessAndOnlyAsAWholeCommit() {
        typealias TestRun = CardDivergenceLog.TestRunCommit
        let given = [TestRun.variable: Self.sha.uppercased()]
        #expect(TestRun.read(environment: given, isTestProcess: true) == .commit(Self.sha))
        #expect(TestRun.read(environment: given, isTestProcess: false) == .notGiven)
        #expect(TestRun.read(environment: [:], isTestProcess: true) == .notGiven)
        for malformed in [String(Self.sha.prefix(7)), Self.sha + "0", "", String(repeating: "g", count: 40),
                          "Marguerite Eddowes"] {
            #expect(TestRun.read(environment: [TestRun.variable: malformed], isTestProcess: true) == .malformed,
                    Comment(rawValue: "`\(malformed)` was not read as malformed"))
        }
        // A process that is not a test run, and a malformed commit, stamp exactly what #4583 stamps.
        let installed = InstalledBuild(commit: Self.otherSha, commitDate: Date(timeIntervalSince1970: 1_800_000_000),
                                       repoPath: "/code/overture", provenance: .main)
        for isRunFromSource in [true, false] {
            let before = CardDivergenceLog.BuildStamp.of(installed: installed, isRunFromSource: isRunFromSource)
            for ignored in [TestRun.read(environment: given, isTestProcess: false), .malformed] {
                #expect(CardDivergenceLog.BuildStamp.of(installed: installed, isRunFromSource: isRunFromSource,
                                                        testRun: ignored) == before)
            }
        }
        // The production predicate, and the production reading through it.
        #expect(AppEnvironment.isRunningUnderTests)
        #expect(TestRun.current == TestRun.read(environment: ProcessInfo.processInfo.environment, isTestProcess: true))
    }

    // THE ARCHIVE KEY (the E4 plan's section 4). 250 records of an older commit and one mismatch of the branch's
    // commit share (kind, source, fields); the branch's is compacted into the archive behind an older one of the same
    // key, and the prune must keep it, so the gate's read by commit still finds it.
    @Test func aBranchsRecordSurvivesTheArchiveBehindAnOlderCommitsRecordOfTheSameKey() throws {
        let dir = try sandboxes.make(named: "4358-e4c-archive-key")
        let url = CardDivergenceLog.url(in: dir)
        func stamped(_ sequence: Int, commit: String, build: CardDivergenceRecord.Build) -> String? {
            CardDivergenceLog.line(for: record(sequence, kind: .factMismatch)
                .stamped(CardDivergenceLog.BuildStamp(build: build, commit: commit)))
        }
        // One older record first, then the branch's, then the rest of the older commit's: 251 lines, 200 kept live.
        var lines = [stamped(0, commit: Self.otherSha, build: .installed)]
        lines.append(stamped(1, commit: Self.sha, build: .testRun))
        for n in 2...250 { lines.append(stamped(n, commit: Self.otherSha, build: .installed)) }
        let text = lines.compactMap { $0 }
        #expect(text.count == 251)
        try (text.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        #expect(CardDivergenceLog.compact(at: url) == .archived(count: 51))
        #expect(CardDivergenceLog.pruneArchive(besideLogAt: url) == .removed(count: 49))

        let live = CardDivergenceLog.read(at: url)
        let archive = CardDivergenceLog.read(at: CardDivergenceLog.archiveURL(besideLogAt: url))
        let both = CardDivergenceLog.Read(records: live.records + archive.records)
        let found = try #require(both.byCommit(Self.sha))
        #expect(found.written.map(\.sequence) == [1], Comment(rawValue:
            "the branch's record is gone after the prune: \(archive.records.map(\.sequence))"))
        #expect(archive.records.map(\.sequence) == [0, 1])
    }

    // Each stamp is its own value in the key, `unstamped` and a build that could not name its commit included.
    @Test func theArchiveKeepsOneOfEachKeyPerStampUnstampedIncluded() throws {
        let unstamped = try #require(CardDivergenceLog.read(
            #"{"at":"2026-10-07T10:00:00Z","cardsBuilt":0,"fields":["venue"],"kind":"factMismatch","sequence":0,"session":"old","source":"reconcile"}"#
        ).records.first)
        func by(_ build: CardDivergenceRecord.Build, _ commit: String?, _ n: Int) -> CardDivergenceRecord {
            record(n, kind: .factMismatch).stamped(CardDivergenceLog.BuildStamp(build: build, commit: commit))
        }
        let records = [unstamped, unstamped, by(.runFromSource, nil, 1), by(.runFromSource, nil, 2),
                       by(.notRecorded, nil, 3), by(.installed, Self.sha, 4), by(.installed, Self.sha, 5),
                       by(.installed, Self.otherSha, 6), by(.testRun, Self.sha, 7)]
        let pruned = CardDivergenceLog.prunedArchive(records)
        // A test run and an installed build of the same commit are one value: the key is what wrote it, and that
        // is a commit when there is one.
        #expect(pruned.records.map(\.sequence) == [0, 1, 3, 4, 6])
        #expect(pruned.dropped == 4)
    }

    // A later build's spelling of `build` reads as unrecognised rather than failing the line, and a file
    // holding one is never rewritten, on the kind and source rule (#4354).
    @Test func aLaterBuildsSpellingIsKeptAndNeverRewritten() throws {
        let dir = try sandboxes.make(named: "4583-later")
        let url = CardDivergenceLog.url(in: dir)
        let later = #"{"at":"2026-10-07T10:00:00Z","build":"notarised","cardsBuilt":0,"fields":["venue"],"sequence":0,"session":"later"}"#
        let lines = [later] + (1...4).compactMap { CardDivergenceLog.line(for: record($0)) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let first = try #require(CardDivergenceLog.read(at: url).records.first)
        #expect(first.build == .unrecognised)
        #expect(first.isFromALaterBuild)
        let before = try String(contentsOf: url, encoding: .utf8)
        #expect(CardDivergenceLog.compact(at: url, cap: 2) == .refusedUnrecognised(records: 1))
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }
}
