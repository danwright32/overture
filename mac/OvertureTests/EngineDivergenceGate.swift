import Testing
import Foundation

// #4358 slice E4c (plan v7 section 15, the E4 plan's section 4): the merge gate's reader and its refusals, as a
// pure function over what one gate run leaves behind.
//
// WHAT THE GATE IS. Per live store TEST run, the branch's own verifier over the live clone completes at least
// K = 5 match comparisons with zero mismatch, heal, floor or extraction records from that run and zero timed
// out. It reads only the records stamped with the branch's commit from its own run. So the gate is a test suite
// the merge path runs on Dan's Mac (`EngineDivergenceGateTests`, which drives the engine over the clone and
// needs the queue derivation of slice E4b, so it arrives with the cutover, E4d), and `merge_pr` runs it with the
// head's commit in `TEST_RUNNER_OVERTURE_GATE_COMMIT` (E4d's wiring). This file is the half that needs neither:
// the reader of the run's own log, and the rule that decides from it, every refusal produced by a test below
// (L151).
//
// WHY A RUN READS UNMEASURED RATHER THAN PASSING WHEN ITS COMMIT IS WRONG (L98). The log's one write stamps a
// test run's lines with the commit only when it was handed a whole one (`CardDivergenceLog.TestRunCommit`). A
// missing or abbreviated one leaves every line stamped as a build run from source, naming no commit, and a gate
// that then filtered by commit would find nothing and read as clean. So a gate that was not told a whole commit
// measures nothing and says so.
//
// WHY EVERY LINE MUST BE THIS RUN'S. The run writes its own temporary log, so every line in it, live file and
// archive alike, should carry this commit stamped as a test run. A line that does not is a sign the stamp or the
// file is not what the gate believes, so it refuses by name rather than filtering the line away (L215, L1013).
//
// WHY THE MATCHES ARE COUNTED TWICE. From the engine's own counts and, separately, from the defaults the run's
// verifier writes (`CardDivergenceLog.verifierMatchCountKey`): a guard that can refuse a reading must not draw on
// the same source as the reading (L345), and the two must agree.
enum EngineDivergenceGate {

    /// Plan v7 section 15's K.
    static let requiredMatches = 5

    /// Everything one gate run hands the rule.
    struct Run: Sendable {
        /// What the run was told it is building, read the way the log's write reads it.
        var commit: CardDivergenceLog.TestRunCommit
        var live: CardDivergenceLog.Read
        var archive: CardDivergenceLog.Read
        /// The engine's own counts for the run.
        var counts: QueueEngineVerifierCounts
        /// `queueVerifierMatchCount` in the run's scratch defaults, nil when the run left none.
        var defaultsMatches: Int?
    }

    /// THE READER: the run's own log and the archive its compaction writes beside it, every line, through the
    /// log's one reader. Never Dan's log, which the run is never pointed at.
    static func read(logAt url: URL) -> (live: CardDivergenceLog.Read, archive: CardDivergenceLog.Read) {
        (CardDivergenceLog.read(at: url), CardDivergenceLog.read(at: CardDivergenceLog.archiveURL(besideLogAt: url)))
    }

    enum Unmeasured: Equatable, Sendable, CustomStringConvertible {
        /// The run was told no commit, or is not a test process.
        case noCommit
        /// The run was told something that is not a whole forty digit commit.
        case malformedCommit

        var description: String {
            switch self {
            case .noCommit:
                return "UNMEASURED: the run was told no commit (\(CardDivergenceLog.TestRunCommit.variable)), so "
                    + "its lines name none and nothing can be read as this branch's"
            case .malformedCommit:
                return "UNMEASURED: the run was told a commit that is not a whole forty digit one, which the log's "
                    + "stamp ignores, so its lines name none and nothing can be read as this branch's"
            }
        }
    }

    enum Refusal: Equatable, Sendable, CustomStringConvertible {
        /// Lines in the run's log or its archive that would not decode.
        case unreadableLines(Int)
        /// Records whose kind, source or build this build cannot name.
        case fromALaterBuild(Int)
        /// Records the run's own file holds that this run did not stamp.
        case notThisRun(otherCommits: Int, commitUnknown: Int, unstamped: Int, notAsATestRun: Int)
        /// Records of a kind the gate refuses, by kind, as "kind x count".
        case recorded([String])
        /// The engine's own counts of the same things, by name.
        case counted([String])
        /// Fewer matches than K.
        case tooFewMatches(Int)
        /// The engine's count and the defaults' disagree, or the defaults hold none.
        case matchCountsDisagree(engine: Int, defaults: Int?)

        var description: String {
            switch self {
            case .unreadableLines(let n):
                return "\(n) line(s) of the run's own log would not decode"
            case .fromALaterBuild(let n):
                return "\(n) record(s) carry a kind, source or build this build cannot name"
            case let .notThisRun(other, unknown, unstamped, notTestRun):
                return "the run's own log holds records it did not stamp: \(other) of another commit, \(unknown) "
                    + "naming no commit, \(unstamped) unstamped, \(notTestRun) of this commit not stamped as a test run"
            case .recorded(let kinds):
                return "the run recorded " + kinds.joined(separator: ", ")
            case .counted(let names):
                return "the engine counted " + names.joined(separator: ", ")
            case .tooFewMatches(let n):
                return "\(n) match(es), fewer than the \(EngineDivergenceGate.requiredMatches) the gate needs"
            case let .matchCountsDisagree(engine, defaults):
                return "the engine counted \(engine) match(es) and the run's defaults \(defaults.map(String.init) ?? "none")"
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case passed(matches: Int, records: Int)
        case refused([Refusal])
        case unmeasured(Unmeasured)
    }

    /// Whether a record of `kind` from this run refuses the gate. EXHAUSTIVE, so a kind added later (plan v7's
    /// `extractionMismatch`, `tablesMismatch` and `floorChanged` are not written yet) has to choose here before it
    /// compiles, rather than passing the gate by being absent from a list.
    static func refuses(_ kind: CardDivergenceRecord.Kind) -> Bool {
        switch kind {
        // The engine and the store disagreed, a card disagreed with a fresh build, or another context saved.
        case .cardDivergence, .factMismatch, .outputMismatch, .foreignSave:
            return true
        // A row was faulted: whether it came back or not, a fault happened in this run.
        case .healed, .healDidNotConverge:
            return true
        // The verifier did not do its job: no verdict for ten minutes, its thread missed its deadline or was
        // still busy with an abandoned run, or re-verification gave up. Plan v7 names the first three; giving up
        // after runs in a row with no verdict is the same failure counted another way, so it refuses too (L42).
        case .unverifiedTooLong, .verifierTimedOut, .verifierWedged, .verifierRetriesCapped:
            return true
        // A change judged dirty that changed nothing: a cost the engine reports, not a disagreement between the
        // engine and the store, which is the one thing this gate decides.
        case .noOpDirty:
            return false
        // A spelling this build cannot name refuses through `fromALaterBuild` before any kind is asked.
        case .unrecognised:
            return true
        }
    }

    /// The engine's counts of the same failures, by name, each one a refusal when it is not zero.
    static func countedFailures(_ counts: QueueEngineVerifierCounts) -> [String] {
        let named: [(String, Int)] = [
            ("factMismatches", counts.factMismatches),
            ("outputMismatches", counts.outputMismatches),
            ("healed", counts.healed),
            ("healDidNotConverge", counts.healDidNotConverge),
            ("unverifiedTooLong", counts.unverifiedTooLong),
            ("retriesCapped", counts.retriesCapped),
            ("timedOut", counts.unmeasured[.timedOut] ?? 0),
            ("wedged", counts.unmeasured[.wedged] ?? 0),
        ]
        return named.filter { $0.1 > 0 }.map { "\($0.0) x\($0.1)" }
    }

    static func verdict(_ run: Run) -> Verdict {
        let commit: String
        switch run.commit {
        case .notGiven: return .unmeasured(.noCommit)
        case .malformed: return .unmeasured(.malformedCommit)
        case .commit(let given): commit = given
        }
        var refusals: [Refusal] = []
        let unreadable = run.live.unreadableLines + run.archive.unreadableLines
        if unreadable > 0 { refusals.append(.unreadableLines(unreadable)) }

        let all = run.live.records + run.archive.records
        let later = all.filter(\.isFromALaterBuild)
        if !later.isEmpty { refusals.append(.fromALaterBuild(later.count)) }
        let known = CardDivergenceLog.Read(records: all.filter { !$0.isFromALaterBuild })
        // `commit` is already a whole one, so the filter cannot refuse it; a nil here would be the reader
        // disagreeing with the stamp about what a commit is, which is itself a reason not to pass.
        guard let split = known.byCommit(commit) else { return .unmeasured(.malformedCommit) }
        let notAsATestRun = split.written.filter { $0.build != .testRun }.count
        if split.otherCommits + split.commitUnknown + split.unstamped + notAsATestRun > 0 {
            refusals.append(.notThisRun(otherCommits: split.otherCommits, commitUnknown: split.commitUnknown,
                                        unstamped: split.unstamped, notAsATestRun: notAsATestRun))
        }

        var byKind: [CardDivergenceRecord.Kind: Int] = [:]
        for record in split.written where refuses(record.kind) { byKind[record.kind, default: 0] += 1 }
        if !byKind.isEmpty {
            refusals.append(.recorded(byKind.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) x\($0.value)" }))
        }
        let counted = countedFailures(run.counts)
        if !counted.isEmpty { refusals.append(.counted(counted)) }

        if run.counts.matches < requiredMatches { refusals.append(.tooFewMatches(run.counts.matches)) }
        if run.defaultsMatches != run.counts.matches {
            refusals.append(.matchCountsDisagree(engine: run.counts.matches, defaults: run.defaultsMatches))
        }
        return refusals.isEmpty ? .passed(matches: run.counts.matches, records: all.count) : .refused(refusals)
    }
}

// Every outcome the gate's rule names, each produced by a test that makes it happen (L151), and the reader driven
// over files the log's real write produced.
@Suite("The merge gate refuses every outcome it names, and passes only a clean run of this commit (#4358 E4c)")
struct EngineDivergenceGateRuleTests {
    private let sandboxes = TemporarySandboxes()

    private static let sha = "0123456789abcdef0123456789abcdef01234567"
    private static let otherSha = "fedcba9876543210fedcba9876543210fedcba98"

    private static func record(_ sequence: Int, kind: CardDivergenceRecord.Kind = .noOpDirty,
                               build: CardDivergenceRecord.Build = .testRun,
                               commit: String? = sha) -> CardDivergenceRecord {
        CardDivergenceRecord(session: "gate", sequence: sequence, at: Date(timeIntervalSince1970: 1_800_000_000),
                             fields: [], cardsBuilt: 0, stage: nil, kind: kind,
                             source: kind == .cardDivergence ? nil : .reconcile)
            .stamped(CardDivergenceLog.BuildStamp(build: build, commit: commit))
    }

    private static func counts(matches: Int = 5) -> QueueEngineVerifierCounts {
        var counts = QueueEngineVerifierCounts()
        counts.matches = matches
        return counts
    }

    private static func run(_ live: [CardDivergenceRecord] = [], archive: [CardDivergenceRecord] = [],
                            unreadable: [String] = [], commit: CardDivergenceLog.TestRunCommit = .commit(sha),
                            counts: QueueEngineVerifierCounts = counts(), defaults: Int? = 5) -> EngineDivergenceGate.Run {
        EngineDivergenceGate.Run(commit: commit,
                                 live: CardDivergenceLog.Read(records: live, unreadable: unreadable),
                                 archive: CardDivergenceLog.Read(records: archive),
                                 counts: counts, defaultsMatches: defaults)
    }

    private static func refusals(_ run: EngineDivergenceGate.Run) -> [EngineDivergenceGate.Refusal] {
        if case .refused(let refusals) = EngineDivergenceGate.verdict(run) { return refusals }
        return []
    }

    @Test func aRunOfThisCommitWithKMatchesAndNothingRecordedPasses() {
        #expect(EngineDivergenceGate.verdict(Self.run()) == .passed(matches: 5, records: 0))
        // A record of a kind the gate does not refuse, stamped by this run, is read and does not refuse.
        #expect(EngineDivergenceGate.verdict(Self.run([Self.record(1)], archive: [Self.record(2)]))
                == .passed(matches: 5, records: 2))
    }

    @Test func aRunToldNoCommitOrAMalformedOneIsUnmeasuredNeverAPass() {
        #expect(EngineDivergenceGate.verdict(Self.run(commit: .notGiven)) == .unmeasured(.noCommit))
        #expect(EngineDivergenceGate.verdict(Self.run(commit: .malformed)) == .unmeasured(.malformedCommit))
    }

    @Test func aLineThatWillNotDecodeInEitherFileRefusesByName() {
        #expect(Self.refusals(Self.run(unreadable: ["{\"at\":"])) == [.unreadableLines(1)])
        let archive = CardDivergenceLog.Read(records: [], unreadable: ["torn", "torn again"])
        var both = Self.run(unreadable: ["{"])
        both.archive = archive
        #expect(Self.refusals(both) == [.unreadableLines(3)])
    }

    @Test func aRecordALaterBuildWroteRefusesByName() throws {
        let later = try #require(CardDivergenceLog.read(
            #"{"at":"2026-10-07T10:00:00Z","build":"notarised","cardsBuilt":0,"commit":"\#(Self.sha)","fields":[],"kind":"factMismatch","sequence":1,"session":"gate"}"#
        ).records.first)
        #expect(later.isFromALaterBuild)
        #expect(Self.refusals(Self.run([later])) == [.fromALaterBuild(1)])
    }

    @Test func aLineThisRunDidNotStampRefusesWhateverItsKind() throws {
        let unstamped = try #require(CardDivergenceLog.read(
            #"{"at":"2026-10-07T10:00:00Z","cardsBuilt":0,"fields":[],"kind":"noOpDirty","sequence":1,"session":"old"}"#
        ).records.first)
        let refusals = Self.refusals(Self.run([
            Self.record(1, commit: Self.otherSha),
            Self.record(2, build: .runFromSource, commit: nil),
            Self.record(3, build: .installed, commit: Self.sha),
        ], archive: [unstamped]))
        #expect(refusals == [.notThisRun(otherCommits: 1, commitUnknown: 1, unstamped: 1, notAsATestRun: 1)])
    }

    @Test func everyKindTheGateRefusesRefusesAndNoOtherDoes() {
        let named: Set<CardDivergenceRecord.Kind> = [
            .cardDivergence, .factMismatch, .outputMismatch, .foreignSave, .healed, .healDidNotConverge,
            .unverifiedTooLong, .verifierTimedOut, .verifierWedged, .verifierRetriesCapped,
        ]
        for kind in CardDivergenceRecord.Kind.allCases where kind != .unrecognised {
            let refusals = Self.refusals(Self.run([Self.record(1, kind: kind)]))
            if named.contains(kind) {
                #expect(refusals == [.recorded(["\(kind.rawValue) x1"])], Comment(rawValue: "\(kind): \(refusals)"))
            } else {
                #expect(refusals.isEmpty, Comment(rawValue: "\(kind) refused the gate: \(refusals)"))
            }
        }
        // Found in the archive as well as the live file, and counted.
        let twice = Self.refusals(Self.run([Self.record(1, kind: .factMismatch)],
                                           archive: [Self.record(2, kind: .factMismatch)]))
        #expect(twice == [.recorded(["factMismatch x2"])])
    }

    @Test func everyFailureTheEngineCountsRefusesEvenWithNoLineWritten() {
        let cases: [(String, (inout QueueEngineVerifierCounts) -> Void)] = [
            ("factMismatches x1", { $0.factMismatches = 1 }),
            ("outputMismatches x1", { $0.outputMismatches = 1 }),
            ("healed x1", { $0.healed = 1 }),
            ("healDidNotConverge x1", { $0.healDidNotConverge = 1 }),
            ("unverifiedTooLong x1", { $0.unverifiedTooLong = 1 }),
            ("retriesCapped x1", { $0.retriesCapped = 1 }),
            ("timedOut x1", { $0.unmeasured[.timedOut] = 1 }),
            ("wedged x1", { $0.unmeasured[.wedged] = 1 }),
        ]
        for (name, set) in cases {
            var counts = Self.counts()
            set(&counts)
            #expect(Self.refusals(Self.run(counts: counts)) == [.counted([name])], Comment(rawValue: name))
        }
        // Outcomes that are not matches are not failures either: they only never count toward K.
        var notMatches = Self.counts()
        notMatches.superseded = 3
        notMatches.cancelled = 2
        notMatches.unmeasured[.busy] = 4
        #expect(EngineDivergenceGate.verdict(Self.run(counts: notMatches)) == .passed(matches: 5, records: 0))
    }

    @Test func fewerMatchesThanKRefuses() {
        #expect(Self.refusals(Self.run(counts: Self.counts(matches: 4), defaults: 4)) == [.tooFewMatches(4)])
        #expect(Self.refusals(Self.run(counts: Self.counts(matches: 0), defaults: 0)) == [.tooFewMatches(0)])
    }

    @Test func theTwoCountsOfMatchesMustAgree() {
        #expect(Self.refusals(Self.run(defaults: 6)) == [.matchCountsDisagree(engine: 5, defaults: 6)])
        #expect(Self.refusals(Self.run(defaults: nil)) == [.matchCountsDisagree(engine: 5, defaults: nil)])
    }

    // THE READER over files the log's own write produced, as a gate run's would be: stamped as a test run of the
    // commit, some compacted into the archive, all read back.
    @Test func theReaderReadsTheRunsOwnLogAndItsArchiveAsTheWriteStampedThem() throws {
        let dir = try sandboxes.make(named: "4358-gate-reader")
        let url = CardDivergenceLog.url(in: dir)
        var cooldown = CardDivergenceLog.Cooldown()
        for n in 1...4 {
            let at = Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 700)
            let record = CardDivergenceRecord(session: "gate", sequence: n, at: at, fields: ["shows"], cardsBuilt: 0,
                                              stage: nil, kind: .noOpDirty, source: .reconcile)
            #expect(CardDivergenceLog.append(record, to: url, through: &cooldown, isRunFromSource: true,
                                             testRun: .commit(Self.sha)))
        }
        #expect(CardDivergenceLog.compact(at: url, cap: 2) == .archived(count: 2))
        let read = EngineDivergenceGate.read(logAt: url)
        #expect(read.live.records.count == 2 && read.archive.records.count == 2)
        var run = Self.run()
        run.live = read.live
        run.archive = read.archive
        #expect(EngineDivergenceGate.verdict(run) == .passed(matches: 5, records: 4))

        // One mismatch written the same way refuses.
        let mismatch = CardDivergenceRecord(session: "gate", sequence: 5, at: Date(timeIntervalSince1970: 1_800_010_000),
                                            fields: ["shows.title"], cardsBuilt: 0, stage: nil, kind: .factMismatch,
                                            source: .reconcile)
        #expect(CardDivergenceLog.append(mismatch, to: url, through: &cooldown, isRunFromSource: true,
                                         testRun: .commit(Self.sha)))
        run.live = EngineDivergenceGate.read(logAt: url).live
        #expect(Self.refusals(run) == [.recorded(["factMismatch x1"])])
    }
}
